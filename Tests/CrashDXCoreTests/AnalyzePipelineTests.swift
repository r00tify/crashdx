import Foundation
import Testing
@testable import CrashDXCore

// AnalyzePipeline is the extracted "parse -> locate dSYMs -> symbolicate ->
// diagnose -> AnalysisReport.build" sequence shared by the `crashdx` CLI and
// `crashdx-mcp`. These tests exercise it directly, independent of either front end;
// `main.swift`'s CLI behavior is covered end-to-end by CLIIntegrationTests.swift, which
// runs the real binary.

@Suite struct AnalyzePipelineTests {
    /// The directory containing the on-disk `nsexcrash.ips`/`nsexcrash.dSYM` fixtures —
    /// `AnalyzePipeline` takes real file paths (not `Bundle.module` resource handles), so
    /// tests need the fixture bundle's actual on-disk location.
    private func fixturesDirectory() throws -> URL {
        let ipsURL = try #require(
            Bundle.module.url(forResource: "nsexcrash", withExtension: "ips", subdirectory: "Fixtures")
        )
        return ipsURL.deletingLastPathComponent()
    }

    private func nsexcrashPath() throws -> String {
        try fixturesDirectory().appendingPathComponent("nsexcrash.ips").path
    }

    // MARK: - analyze: happy path

    @Test func analyzeHappyPathOnNSExcrashFixture() throws {
        let fixturesDir = try fixturesDirectory()
        let result = try AnalyzePipeline.analyze(
            path: try nsexcrashPath(), tier: .standard, dsymPaths: [fixturesDir], useSpotlight: false, searchArchives: false
        )

        // Symbolication ran (a dSYM was found via the extra search path) and the
        // diagnosis reached its ground-truth verdict for this fixture.
        #expect(result.symbolication != nil)
        #expect(result.diagnosis.status == .verdict)
        #expect(result.diagnosis.verdict?.id == "uncaught-objc-exception")
        #expect(result.report.diagnosis.verdict?.id == "uncaught-objc-exception")
        #expect(result.report.tier == .standard)

        // diagnosedFile is the symbolicated file (not the raw parse) - it carries the
        // enriched throwingHelper() symbol used by the inspect-point ground truth.
        let lebSymbols = result.diagnosedFile.payload.lastExceptionBacktrace?.compactMap(\.symbol) ?? []
        #expect(lebSymbols.contains("throwingHelper()"))
    }

    @Test func analyzeReportIsJSONEncodableAtEveryTier() throws {
        let fixturesDir = try fixturesDirectory()
        for tier: AnalysisReport.Tier in [.summary, .standard, .full] {
            let result = try AnalyzePipeline.analyze(
                path: try nsexcrashPath(), tier: tier, dsymPaths: [fixturesDir],
                useSpotlight: false, searchArchives: false
            )
            let data = try JSONEncoder().encode(result.report)
            #expect(!data.isEmpty)
        }
    }

    @Test func analyzeWithoutDSYMsStillDiagnosesUnsymbolicated() throws {
        // No dsymPaths and Spotlight off: symbolication is skipped entirely, but
        // diagnosis still runs against the raw parse (nsexcrash's LEB carries
        // objc_exception_throw even unsymbolicated - see LEBAndASITests.swift).
        let result = try AnalyzePipeline.analyze(
            path: try nsexcrashPath(), tier: .summary, dsymPaths: [], useSpotlight: false, searchArchives: false
        )
        #expect(result.symbolication == nil)
        #expect(result.diagnosedFile.payload.lastExceptionBacktrace != nil)
        #expect(result.diagnosis.status == .verdict)
        #expect(result.diagnosis.verdict?.id == "uncaught-objc-exception")
    }

    /// A dSYM from the WRONG BUILD must be reported as `uuid_mismatch`, distinctly from
    /// `no_dsym`. The two have different remedies — "find the matching archive" vs "go
    /// find a dSYM" — and collapsing them sends the user hunting for a file they already
    /// have. Built by rewriting the report's recorded build UUID so the real, correctly
    /// named `nsexcrash.dSYM` on disk no longer matches it.
    @Test func wrongBuildDSYMIsReportedAsUUIDMismatchNotMissing() throws {
        let fixturesDir = try fixturesDirectory()
        let raw = try String(contentsOf: URL(fileURLWithPath: try nsexcrashPath()), encoding: .utf8)
        var (headerLine, payloadText) = (raw.components(separatedBy: "\n")[0],
                                         raw.components(separatedBy: "\n").dropFirst().joined(separator: "\n"))
        var payload = try #require(
            try JSONSerialization.jsonObject(with: Data(payloadText.utf8)) as? [String: Any]
        )
        var images = try #require(payload["usedImages"] as? [[String: Any]])
        let idx = try #require(images.firstIndex { ($0["name"] as? String) == "nsexcrash" })
        images[idx]["uuid"] = "deadbeef-0000-0000-0000-000000000000"
        payload["usedImages"] = images
        payloadText = String(
            data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8
        ) ?? ""

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uuid-mismatch-\(UUID().uuidString).ips")
        try (headerLine + "\n" + payloadText).write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try AnalyzePipeline.analyze(
            path: tmp.path, tier: .standard, dsymPaths: [fixturesDir], useSpotlight: false, searchArchives: false
        )

        let statuses = try #require(result.report.symbolication?.images)
        let nsexcrash = try #require(statuses.first { $0.imageName == "nsexcrash" })
        #expect(nsexcrash.outcome == .uuidMismatch)
        #expect(nsexcrash.outcome != .noDSYM)
        // The reason names the offending bundle so the user can see WHICH dSYM is stale.
        #expect(nsexcrash.reason?.contains("nsexcrash.dSYM") == true)
    }

    // MARK: - symbolicate: happy path

    @Test func symbolicateToIPSDataProducesTwoDocumentIPSShape() throws {
        let fixturesDir = try fixturesDirectory()
        let data = try AnalyzePipeline.symbolicateToIPSData(
            path: try nsexcrashPath(), dsymPaths: [fixturesDir], useSpotlight: false, searchArchives: false
        )

        let text = try #require(String(data: data, encoding: .utf8))
        let lines = text.split(separator: "\n", maxSplits: 1)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("{")) // header line
        #expect(text.contains("throwingHelper")) // dSYM was applied

        // The bytes are a valid, reparseable .ips file.
        let reparsed = try IPSFile.parse(data: data)
        #expect(reparsed.payload.lastExceptionBacktrace?.compactMap(\.symbol).contains("throwingHelper()") == true)
    }

    // MARK: - Errors: file not found

    @Test func analyzeThrowsFileNotFoundForMissingPath() {
        do {
            _ = try AnalyzePipeline.analyze(
                path: "/nonexistent/path/does-not-exist.ips", tier: .summary, dsymPaths: [],
                useSpotlight: false, searchArchives: false
            )
            Issue.record("expected AnalyzePipeline.analyze to throw")
        } catch let error as AnalyzePipeline.PipelineError {
            guard case .fileNotFound(let path) = error else {
                Issue.record("expected .fileNotFound, got \(error)")
                return
            }
            #expect(path == "/nonexistent/path/does-not-exist.ips")
            #expect(error.description == "file not found: /nonexistent/path/does-not-exist.ips")
        } catch {
            Issue.record("expected AnalyzePipeline.PipelineError, got \(error)")
        }
    }

    @Test func symbolicateThrowsFileNotFoundForMissingPath() {
        #expect(throws: AnalyzePipeline.PipelineError.self) {
            _ = try AnalyzePipeline.symbolicateToIPSData(
                path: "/nonexistent/path/does-not-exist.ips", dsymPaths: [],
                useSpotlight: false, searchArchives: false
            )
        }
    }

    // MARK: - Errors: parse failure

    @Test func analyzeThrowsParseFailedForGarbageInput() throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("crashdx-pipeline-test-\(UUID().uuidString).ips")
        try Data("not json\nstill not json".utf8).write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            _ = try AnalyzePipeline.analyze(
                path: tmpURL.path, tier: .summary, dsymPaths: [],
                useSpotlight: false, searchArchives: false
            )
            Issue.record("expected AnalyzePipeline.analyze to throw")
        } catch let error as AnalyzePipeline.PipelineError {
            guard case .parseFailed(let path, _) = error else {
                Issue.record("expected .parseFailed, got \(error)")
                return
            }
            #expect(path == tmpURL.path)
            #expect(error.description.hasPrefix("failed to parse \(tmpURL.path):"))
        } catch {
            Issue.record("expected AnalyzePipeline.PipelineError, got \(error)")
        }
    }
}
