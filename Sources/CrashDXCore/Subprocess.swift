import Foundation

/// Runs a helper tool and returns its stdout, draining stdout and stderr CONCURRENTLY.
///
/// Every subprocess in this package goes through here, because the obvious sequential
/// form deadlocks:
///
/// ```swift
/// let out = outPipe.fileHandleForReading.readDataToEndOfFile()  // blocks until EOF
/// _ = errPipe.fileHandleForReading.readDataToEndOfFile()        // never reached
/// ```
///
/// `readDataToEndOfFile()` on stdout blocks until the child closes stdout. A child that
/// has filled the ~64 KiB stderr pipe is blocked inside `write(2)` and will never reach
/// that point, so the parent waits forever. Adding a second sequential read does not
/// help — it is the *first* read that never returns. Both pipes must be drained at once.
///
/// This is reachable from untrusted input, which is the threat model crashdx is built
/// for: `usedImages[].arch` is copied verbatim out of the crash report into `atos`'s
/// argv, and `atos` echoes an invalid arch back in a usage message whose length scales
/// with the input while writing nothing to stdout. A ~70 KB `arch` string in a
/// stranger-supplied `.ips` was enough to hang the CLI indefinitely.
enum Subprocess {
    /// Result of a completed run. `nil` is returned instead when the tool could not be
    /// launched or did not finish within `timeout`.
    struct Result {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    /// Upper bound on how long any helper tool may run. These are all fast, local
    /// queries (`atos`, `dwarfdump`, `mdfind`, `xcode-select`, `CrashSymbolicator.py`);
    /// a minute is far beyond their normal cost, and bounding it means a pathological
    /// report degrades to "unsymbolicated" rather than to a process that never returns.
    static let defaultTimeout: TimeInterval = 60

    static func run(
        executable: URL,
        arguments: [String],
        stdin: Data? = nil,
        timeout: TimeInterval = defaultTimeout
    ) -> Result? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = stdin.map { _ in Pipe() }
        if let inPipe { process.standardInput = inPipe }

        // Collect on dedicated queues so neither pipe can back-pressure the other.
        let lock = NSLock()
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()

        func drain(_ handle: FileHandle, into sink: @escaping (Data) -> Void) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.readDataToEndOfFile()
                sink(data)
                group.leave()
            }
        }
        drain(outPipe.fileHandleForReading) { data in
            lock.lock(); outData = data; lock.unlock()
        }
        drain(errPipe.fileHandleForReading) { data in
            lock.lock(); errData = data; lock.unlock()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        if let inPipe, let stdin {
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inPipe.fileHandleForWriting.close()
        }

        // Wait for the child with a bound. `waitUntilExit` has no timeout of its own, so
        // poll and terminate if the tool wedges for any reason beyond a full pipe.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            process.terminate()
            _ = group.wait(timeout: .now() + 5)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }

        // Both readers must finish before the buffers are read.
        guard group.wait(timeout: .now() + 5) == .success else { return nil }
        process.waitUntilExit()

        lock.lock()
        let result = Result(stdout: outData, stderr: errData, exitCode: process.terminationStatus)
        lock.unlock()
        return result
    }
}
