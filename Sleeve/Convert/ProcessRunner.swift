//
//  ProcessRunner.swift
//  Sleeve
//
//  Dünne Hülle um `Process`. Einzige Stelle, an der Sleeve fremde Programme
//  startet.
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

    /// Startet das Programm und wartet auf das Ende.
    ///
    /// Beide Ausgabekanäle werden **gleichzeitig** gelesen. Nacheinander zu
    /// lesen verklemmt, sobald der jeweils andere Puffer volläuft — bei
    /// ffmpeg passiert genau das, weil es seinen Fortschritt nach stderr
    /// schreibt, während wir noch auf stdout warten.
    ///
    /// Wird die aufrufende Task abgebrochen, bekommt der Prozess SIGTERM.
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
                    // Ohne das kann ffmpeg auf eine Eingabe warten, die nie kommt.
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

/// Nimmt die Ausgaben der beiden Lese-Threads entgegen. Ohne Sperre wäre das
/// ein Datenrennen — die DispatchGroup ordnet nur das Ende, nicht die Zugriffe.
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

/// Hält den laufenden Prozess, damit das Abbrechen ihn erreicht. `Process`
/// ist nicht `Sendable`, deshalb hinter einer Sperre.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func adopt(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        // Abbruch kam, bevor der Prozess lief — sofort beenden.
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
