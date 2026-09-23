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
    }

    /// Starts the program and waits for it to finish.
    ///
    /// Both output channels are read **at the same time**. Reading them one
    /// after the other deadlocks as soon as the other buffer fills up — with
    /// ffmpeg exactly that happens, because it writes its progress to stderr
    /// while we are still waiting on stdout.
    ///
    /// If the calling task is cancelled, the process gets SIGTERM.
    static func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil
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

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}
