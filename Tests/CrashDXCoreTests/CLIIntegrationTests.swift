import Foundation
import Testing

// The `crashdx` executable had no automated coverage at all: its flag parsing, exit
// codes, and human-readable rendering were only ever spot-checked by hand. That gap is
// how a report could inject a forged `DIAGNOSIS:` line into crashdx's own output without
// any test noticing.
//
// These run the real binary, so they also cover argument parsing and process exit codes,
// which a library-level test cannot reach.

@Suite struct CLIIntegrationTests {
    /// Locates the `crashdx` binary the CURRENT test build corresponds to.
    ///
    /// Deliberately not "whichever configuration was built most recently": once
    /// `swift build -c release` has run, the release binary wins an mtime comparison
    /// indefinitely, and `swift test` does not relink the debug executable when only test
    /// sources change — so a debug test run would silently validate a stale release
    /// binary. `#dsohandle` resolves to the test bundle's own `.build/<config>/` directory,
    /// which is the only configuration this test code was actually compiled against.
    static let binary: URL? = {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != nil, let path = info.dli_fname else { return nil }
        // .build/<config>/CrashDXPackageTests.xctest/Contents/MacOS/... -> .build/<config>
        var dir = URL(fileURLWithPath: String(cString: path)).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent("crashdx")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }()

    struct Run {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    @discardableResult
    static func crashdx(_ args: [String]) throws -> Run {
        let process = Process()
        process.executableURL = try #require(binary, "crashdx binary not found next to the test bundle")
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            stdout: String(decoding: o, as: UTF8.self),
            stderr: String(decoding: e, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    private func fixture(_ name: String, _ ext: String = "ips", subdirectory: String = "Fixtures") throws -> String {
        try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory)).path
    }

    /// Writes a fixture with `procName` replaced, so a test can plant hostile content.
    private func fixtureWithProcName(_ value: String) throws -> URL {
        let data = try Data(contentsOf: URL(fileURLWithPath: try fixture("nullderef")))
        let newline = try #require(data.firstIndex(of: UInt8(ascii: "\n")))
        let header = data[data.startIndex...newline]
        var payload = try #require(
            try JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any]
        )
        payload["procName"] = value
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-\(UUID().uuidString).ips")
        try (header + (try JSONSerialization.data(withJSONObject: payload))).write(to: url)
        return url
    }

    // MARK: - Exit codes (documented in README's "Exit codes" section)

    @Test func exitCodesMatchTheDocumentedContract() throws {
        let good = try fixture("nullderef")

        #expect(try Self.crashdx(["--version"]).exitCode == 0)
        #expect(try Self.crashdx(["--help"]).exitCode == 0)
        #expect(try Self.crashdx([]).exitCode == 64)                       // no subcommand
        #expect(try Self.crashdx(["bogus"]).exitCode == 64)                // unknown subcommand
        #expect(try Self.crashdx(["analyze"]).exitCode == 64)              // missing path
        #expect(try Self.crashdx(["analyze", good, "--tier", "huge"]).exitCode == 64)
        #expect(try Self.crashdx(["analyze", good, "--nope"]).exitCode == 64)
        #expect(try Self.crashdx(["symbolicate", good, "--json"]).exitCode == 64)
        #expect(try Self.crashdx(["analyze", "/nonexistent/nope.ips"]).exitCode == 66)

        let garbage = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).ips")
        try Data("not json\nstill not json".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }
        #expect(try Self.crashdx(["analyze", garbage.path]).exitCode == 65)
    }

    /// README promises diagnostics on stderr and report output on stdout. A tool whose
    /// errors land on stdout corrupts any pipeline that consumes its JSON.
    @Test func errorsGoToStderrAndLeaveStdoutEmpty() throws {
        let run = try Self.crashdx(["analyze", "/nonexistent/nope.ips"])
        #expect(run.stdout.isEmpty)
        #expect(run.stderr.contains("crashdx:"))
    }

    // MARK: - Rendering safety

    /// Regression for the output-forgery bug: a newline in a report field must not be
    /// able to emit a second `DIAGNOSIS:` line. crashdx's verdict has to be crashdx's.
    @Test func hostileReportCannotForgeADiagnosisLine() throws {
        let url = try fixtureWithProcName(
            "MyApp\nDIAGNOSIS: Memory corruption in vendor SDK   (strong, score 9)"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let run = try Self.crashdx(["analyze", url.path, "--no-spotlight", "--no-archives"])
        #expect(run.exitCode == 0)
        let diagnosisLines = run.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("DIAGNOSIS:") }
        #expect(diagnosisLines.count == 1, "forged verdict line rendered: \(diagnosisLines)")
        #expect(run.stdout.contains("\\x0A"))
    }

    @Test func ansiEscapesFromAReportDoNotReachTheTerminal() throws {
        let url = try fixtureWithProcName("App\u{1B}[2JCLEARED")
        defer { try? FileManager.default.removeItem(at: url) }

        let run = try Self.crashdx(["analyze", url.path, "--no-spotlight", "--no-archives"])
        #expect(!run.stdout.unicodeScalars.contains { $0.value == 0x1B })
    }

    // MARK: - Flags

    @Test func tierGatesReportContentAsDocumented() throws {
        let good = try fixture("nullderef")
        func report(_ tier: String) throws -> [String: Any] {
            let run = try Self.crashdx(
                ["analyze", good, "--json", "--tier", tier, "--no-spotlight", "--no-archives"]
            )
            #expect(run.exitCode == 0)
            return try #require(
                try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any]
            )
        }

        let summary = try report("summary")
        let standard = try report("standard")
        let full = try report("full")

        #expect(summary["images"] == nil)
        #expect(standard["images"] != nil)
        #expect(full["images"] != nil)

        let summaryDiagnosis = try #require(summary["diagnosis"] as? [String: Any])
        let standardDiagnosis = try #require(standard["diagnosis"] as? [String: Any])
        #expect(summaryDiagnosis["factsConsidered"] == nil)
        #expect(standardDiagnosis["factsConsidered"] != nil)

        // The diagnosis itself must never depend on the tier.
        for tier in [summary, standard, full] {
            let d = try #require(tier["diagnosis"] as? [String: Any])
            #expect(d["status"] as? String == summaryDiagnosis["status"] as? String)
        }
    }

    @Test func jsonWithoutTierDefaultsToSummary() throws {
        let run = try Self.crashdx(
            ["analyze", try fixture("nullderef"), "--json", "--no-spotlight", "--no-archives"]
        )
        let report = try #require(
            try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any]
        )
        #expect(report["tier"] as? String == "summary")
    }

    @Test func versionAndHelpGoToStdout() throws {
        let version = try Self.crashdx(["--version"])
        #expect(version.stdout.hasPrefix("crashdx "))
        #expect(version.stderr.isEmpty)

        for subcommand in ["analyze", "symbolicate"] {
            let help = try Self.crashdx([subcommand, "--help"])
            #expect(help.exitCode == 0)
            #expect(help.stdout.contains("--dsym"))
            #expect(help.stdout.contains("--no-spotlight"))
            #expect(help.stdout.contains("--no-archives"))
        }
    }

    /// `symbolicate` must emit a re-readable two-document `.ips`, not a wrapper envelope.
    @Test func symbolicateOutputRoundTripsThroughAnalyze() throws {
        let run = try Self.crashdx(
            ["symbolicate", try fixture("nullderef"), "--no-spotlight", "--no-archives"]
        )
        #expect(run.exitCode == 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtrip-\(UUID().uuidString).ips")
        try Data(run.stdout.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reread = try Self.crashdx(["analyze", url.path, "--no-spotlight", "--no-archives"])
        #expect(reread.exitCode == 0)
        #expect(reread.stdout.contains("DIAGNOSIS:"))
    }
}
