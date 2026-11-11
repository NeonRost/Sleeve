//
//  ProcessRunner.swift
//  Sleeve
//
//  Copyright (C) 2026 NeonRost
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
//  A thin wrapper around `Process`. The only place where Sleeve starts other
//  programs.
//

import Foundation

enum ProcessRunner {

    struct Result: Sendable {
        var status: Int32
        var standardOutput: String
        var standardError: String
        var succeeded: Bool { status == 0 }
    }

    enum RunError: Error, Sendable {
        case launchFailed(String)
        case cancelled
        /// The program used no processor time for `stallTimeout` and was
        /// ended. A working ffmpeg always computes; one that sits still is
        /// waiting for something that does not come — a network volume that
        /// went away, a broken file it cannot get past.
        case stalled
    }

    /// How long a program may sit idle before it counts as hung.
    static let defaultStallTimeout: TimeInterval = 60

    /// Starts the program and waits for it to finish.
    ///
    /// Both output channels are read **at the same time**. Reading them one
    /// after the other deadlocks as soon as the other buffer fills up — with
    /// ffmpeg exactly that happens, because it writes its progress to stderr
    /// while we are still waiting on stdout.
    ///
    /// If the calling task is cancelled, the process gets SIGTERM, and
    /// SIGKILL five seconds later if it is still there. The same happens
    /// when it hangs (see `RunError.stalled`).
    static func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        stallTimeout: TimeInterval? = defaultStallTimeout
    ) async throws -> Result {
        let box = ProcessBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    if let currentDirectory { process.currentDirectoryURL = currentDirectory }

                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = errPipe
                    // Without this, ffmpeg may wait for input that never comes.
                    process.standardInput = FileHandle.nullDevice

                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: RunError.launchFailed(error.localizedDescription))
                        return
                    }
                    box.adopt(process)
                    if let stallTimeout { watch(process, box: box, timeout: stallTimeout) }

                    let collected = OutputBox()
                    let group = DispatchGroup()
                    for (pipe, isStandardOutput) in [(outPipe, true), (errPipe, false)] {
                        group.enter()
                        DispatchQueue.global(qos: .userInitiated).async {
                            let data = pipe.fileHandleForReading.readDataToEndOfFile()
                            collected.store(data, isStandardOutput: isStandardOutput)
                            group.leave()
                        }
                    }
                    group.wait()
                    process.waitUntilExit()

                    if box.hasStalled {
                        continuation.resume(throwing: RunError.stalled)
                        return
                    }
                    continuation.resume(returning: Result(
                        status: process.terminationStatus,
                        standardOutput: collected.text(isStandardOutput: true),
                        standardError: collected.text(isStandardOutput: false)
                    ))
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    /// Watches the processor time of the child. Output cannot be the measure:
    /// ffmpeg with `-loglevel error` writes nothing while it works.
    private static func watch(_ process: Process, box: ProcessBox, timeout: TimeInterval) {
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).async {
            var lastTime = cpuTime(of: pid)
            var lastChange = Date()
            while process.isRunning {
                Thread.sleep(forTimeInterval: 1)
                let now = cpuTime(of: pid)
                if now != lastTime {
                    lastTime = now
                    lastChange = Date()
                } else if Date().timeIntervalSince(lastChange) > timeout {
                    box.stall()
                    return
                }
            }
        }
    }

    /// User plus system time in nanoseconds; 0 when it cannot be read.
    private static func cpuTime(of pid: pid_t) -> UInt64 {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard status == 0 else { return 0 }
        return info.ri_user_time &+ info.ri_system_time
    }
}

/// Receives the output of the two reader threads. Without a lock this would
/// be a data race — the DispatchGroup only orders the end, not the accesses.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutput = Data()
    private var standardError = Data()

    func store(_ data: Data, isStandardOutput: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStandardOutput { standardOutput = data } else { standardError = data }
    }

    func text(isStandardOutput: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: isStandardOutput ? standardOutput : standardError, as: UTF8.self)
    }
}

/// Holds the running process so that cancellation can reach it. `Process`
/// is not `Sendable`, hence behind a lock.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func adopt(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        // Cancellation came before the process was running — end it right away.
        if cancelled {
            process.terminate()
        } else {
            self.process = process
        }
    }

    private var stalled = false

    var hasStalled: Bool { lock.withLock { stalled } }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        end()
    }

    func stall() {
        lock.lock()
        defer { lock.unlock() }
        stalled = true
        end()
    }

    /// SIGTERM, and SIGKILL if that is not heeded within five seconds —
    /// a hung process does not always react to the polite request.
    private func end() {
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
