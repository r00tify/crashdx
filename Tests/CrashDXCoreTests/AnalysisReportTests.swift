import Foundation
import Testing
@testable import CrashDXCore

// Ground truth for the fixtures used here (crashspike-stripped.ips, nsexcrash.ips) lives
// in corpus/README.md and is exercised in more depth by IPSFileTests.swift and
// LEBAndASITests.swift. This suite is about the AnalysisReport *contract* built on top
// of that parsed data: schema stability, tier gating, and the "never drop the LEB"
// promise, plus a synthetic multi-thread fixture (built in-process, not on disk) to
// exercise the app-thread heuristic and the summary-tier frame cap, since neither real
// fixture happens to have more than one thread or a >15-frame faulting thread.

private func fixtureURL(_ name: String, extension ext: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
}

private func loadFixture(_ name: String) throws -> IPSFile {
    try IPSFile.parse(contentsOf: fixtureURL(name, extension: "ips"))
}

/// A synthetic 3-thread report with a 20-frame faulting thread, built directly from raw
/// JSON (not from a captured `.ips`) so it can exercise the summary-tier frame cap and
/// the standard-tier "app thread" heuristic, neither of which either real fixture
/// happens to trigger (crashspike-stripped and nsexcrash both have exactly one thread).
///
/// Thread 0 (faulting): 20 frames, all in "synthapp" (imageIndex 0).
/// Thread 1: 1 frame in "synthapp" (imageIndex 0) -> should count as an "app thread".
/// Thread 2: 1 frame in "libsynth.dylib" (imageIndex 1) only -> should NOT count as an
///           "app thread" under the imageName == procName heuristic.
private func makeSyntheticMultiThreadFile() throws -> IPSFile {
    let header = "{\"app_name\":\"synthapp\",\"bug_type\":\"309\",\"os_version\":\"macOS 99.0\",\"incident_id\":\"SYNTH-0001\",\"name\":\"synthapp\"}"

    let faultingFrames = (0..<20).map { i in ["imageIndex": 0, "imageOffset": 100 + i * 4] }
    let payload: [String: Any] = [
        "procName": "synthapp",
        "faultingThread": 0,
        "threads": [
            ["triggered": true, "queue": "com.apple.main-thread", "frames": faultingFrames],
            ["triggered": false, "queue": "com.apple.app-thread", "frames": [["imageIndex": 0, "imageOffset": 900]]],
            ["triggered": false, "queue": "com.apple.system-thread", "frames": [["imageIndex": 1, "imageOffset": 500]]],
        ],
        "usedImages": [
            ["source": "P", "name": "synthapp", "uuid": "aaaaaaaa-1111-1111-1111-111111111111", "path": "/tmp/synthapp", "arch": "arm64", "base": 1000, "size": 100],
            ["source": "P", "name": "libsynth.dylib", "uuid": "bbbbbbbb-2222-2222-2222-222222222222", "path": "/usr/lib/libsynth.dylib", "arch": "arm64", "base": 2000, "size": 100],
        ],
        "exception": ["type": "EXC_BREAKPOINT", "signal": "SIGTRAP"],
        "termination": ["namespace": "SIGNAL", "indicator": "Trace/BPT trap: 5"],
    ]
    let payloadData = try JSONSerialization.data(withJSONObject: payload)
    let data = Data((header + "\n").utf8) + payloadData
    return try IPSFile.parse(data: data)
}

@Suite struct AnalysisReportTests {
    private static let allTiers: [AnalysisReport.Tier] = [.summary, .standard, .full]

    // MARK: - Schema version / tier plumbing

    @Test(arguments: allTiers)
    func schemaVersionAndTierAreStamped(tier: AnalysisReport.Tier) throws {
        let file = try loadFixture("crashspike-stripped")
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: tier)
        #expect(report.schemaVersion == AnalysisReport.currentSchemaVersion)
        #expect(report.schemaVersion == "0.2")
        #expect(report.tier == tier)
    }

    // MARK: - Summary tier is lean

    @Test(arguments: ["crashspike-stripped", "nsexcrash"])
    func summaryTierOmitsOtherThreadsAndImages(fixture: String) throws {
        let file = try loadFixture(fixture)
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: .summary)
        #expect(report.otherThreads == nil)
        #expect(report.images == nil)
    }

    @Test(arguments: ["crashspike-stripped", "nsexcrash"])
    func standardAndFullTiersPopulateOtherThreads(fixture: String) throws {
        let file = try loadFixture(fixture)
        // Both real fixtures have exactly one thread, so otherThreads is an empty array
        // (not nil) at standard/full - there's simply nothing else to report.
        for tier: AnalysisReport.Tier in [.standard, .full] {
            let report = AnalysisReport.build(from: file, symbolication: nil, tier: tier)
            #expect(report.otherThreads != nil)
            #expect(report.otherThreads?.isEmpty == true)
        }
    }

    // MARK: - LEB is never dropped (core product promise)

    @Test(arguments: allTiers)
    func lastExceptionBacktraceNeverDroppedForNSExcrash(tier: AnalysisReport.Tier) throws {
        let file = try loadFixture("nsexcrash")
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: tier)
        let leb = try #require(report.lastExceptionBacktrace)
        #expect(leb.count == 7)
        #expect(leb.contains { $0.symbol == "objc_exception_throw" })
    }

    @Test(arguments: allTiers)
    func crashspikeHasNoLastExceptionBacktrace(tier: AnalysisReport.Tier) throws {
        // Ground truth: crashspike is a force-unwrap crash, not an uncaught NSException -
        // it carries no lastExceptionBacktrace at all, at any tier.
        let file = try loadFixture("crashspike-stripped")
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: tier)
        #expect(report.lastExceptionBacktrace == nil)
    }

    // MARK: - Uncaught exception fields (ground truth: nil for nsexcrash)

    @Test func uncaughtExceptionFieldsNilForNSExcrash() throws {
        let file = try loadFixture("nsexcrash")
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: .standard)
        #expect(report.event.uncaughtExceptionName == nil)
        #expect(report.event.uncaughtExceptionReason == nil)
        // But the ASI *is* present (just not the exception-name pattern) - see
        // LEBAndASITests for the ground-truth explanation.
        #expect(report.asiMessages?.contains("abort() called") == true)
    }

    // MARK: - Frame cap + truncatedFrameCount (synthetic fixture)

    @Test func summaryTierCapsFaultingThreadAt15Frames() throws {
        let file = try makeSyntheticMultiThreadFile()
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: .summary)
        let thread = try #require(report.faultingThread)
        #expect(thread.frames.count == 15)
        #expect(thread.truncatedFrameCount == 5) // 20 total - 15 kept
    }

    @Test(arguments: [AnalysisReport.Tier.standard, .full])
    func nonSummaryTiersDoNotCapFaultingThread(tier: AnalysisReport.Tier) throws {
        let file = try makeSyntheticMultiThreadFile()
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: tier)
        let thread = try #require(report.faultingThread)
        #expect(thread.frames.count == 20)
        #expect(thread.truncatedFrameCount == nil)
    }

    @Test func realFixturesNeverTruncateBecauseTheyStayUnderTheCap() throws {
        // crashspike (6 frames) and nsexcrash (15 frames, exactly at the boundary)
        // should never report truncation even in .summary.
        for fixture in ["crashspike-stripped", "nsexcrash"] {
            let file = try loadFixture(fixture)
            let report = AnalysisReport.build(from: file, symbolication: nil, tier: .summary)
            #expect(report.faultingThread?.truncatedFrameCount == nil)
        }
    }

    // MARK: - App-thread heuristic (synthetic fixture)

    @Test func standardTierIncludesOnlyThreadsWithAppFrames() throws {
        let file = try makeSyntheticMultiThreadFile()
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: .standard)
        let otherThreads = try #require(report.otherThreads)
        // Thread 1 (a "synthapp" frame) qualifies; thread 2 (only "libsynth.dylib") does not.
        #expect(otherThreads.map(\.index) == [1])
    }

    @Test func fullTierIncludesEveryOtherThreadRegardless() throws {
        let file = try makeSyntheticMultiThreadFile()
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: .full)
        let otherThreads = try #require(report.otherThreads)
        #expect(otherThreads.map(\.index).sorted() == [1, 2])
    }

    @Test func imagesFieldReflectsOnlyImagesReferencedByReportedThreads() throws {
        let file = try makeSyntheticMultiThreadFile()

        // Standard: faultingThread (imageIndex 0 only) + otherThreads (thread 1, also
        // imageIndex 0 only) -> only "synthapp" should be listed, not "libsynth.dylib",
        // even though libsynth.dylib does appear in the (excluded) system thread.
        let standardReport = AnalysisReport.build(from: file, symbolication: nil, tier: .standard)
        let standardImages = try #require(standardReport.images)
        #expect(standardImages.compactMap(\.name) == ["synthapp"])

        // Full: thread 2 is now included, pulling in libsynth.dylib too.
        let fullReport = AnalysisReport.build(from: file, symbolication: nil, tier: .full)
        let fullImages = try #require(fullReport.images)
        #expect(Set(fullImages.compactMap(\.name)) == Set(["synthapp", "libsynth.dylib"]))
    }

    @Test func imageStatusReflectsWhetherFramesCarrySymbols() throws {
        // None of the synthetic frames carry a `symbol`, so every referenced image
        // should be reported as unsymbolicated.
        let file = try makeSyntheticMultiThreadFile()
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: .full)
        let images = try #require(report.images)
        #expect(images.allSatisfy { $0.status == .unsymbolicated })
    }

    // MARK: - Symbolication info

    @Test func symbolicationInfoNilWhenSymbolicationDidNotRun() throws {
        let file = try loadFixture("crashspike-stripped")
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: .full)
        #expect(report.symbolication == nil)
    }

    @Test func symbolicationInfoReflectsAtosOutcomes() throws {
        let ipsData = try Data(contentsOf: fixtureURL("crashspike-unsymbolicated", extension: "ips"))
        let dsymURL = try fixtureURL("crashspike", extension: "dSYM")
        let dsyms = ["657a6675-2d2c-32ca-8c31-3a8c948df5fe": dsymURL]
        let output = try Symbolicator().symbolicateWithAtos(ipsData: ipsData, dsyms: dsyms)

        let report = AnalysisReport.build(from: output.file, symbolication: output, tier: .standard)
        let symbolication = try #require(report.symbolication)
        #expect(symbolication.engine == .atos)
        let crashspikeStatus = try #require(symbolication.images.first { $0.imageName == "crashspike" })
        #expect(crashspikeStatus.outcome == .symbolicated)
        #expect(crashspikeStatus.reason == nil)
    }

    // MARK: - Diagnosis: always present, never invented when not supplied

    @Test(arguments: allTiers)
    func diagnosisIsNotApplicableWhenNoDiagnosisSupplied(tier: AnalysisReport.Tier) throws {
        // No `diagnosis:` argument -> the report still carries a fully-shaped `diagnosis`
        // field (never omitted), but honestly reports "not_applicable" with empty lists
        // rather than fabricating a verdict.
        let file = try loadFixture("nsexcrash")
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: tier)
        #expect(report.diagnosis.status == .notApplicable)
        #expect(report.diagnosis.verdict == nil)
        #expect(report.diagnosis.hypotheses.isEmpty)
        switch tier {
        case .summary, .unrecognised:
            #expect(report.diagnosis.factsConsidered == nil)
        case .standard, .full:
            #expect(report.diagnosis.factsConsidered == [])
        }
    }

    // MARK: - Diagnosis: wired to DiagnosisEngine

    @Test(arguments: [
        ("crashspike-stripped", "swift-fatal-trap"),
        ("nsexcrash", "uncaught-objc-exception"),
        ("nullderef", "null-dereference"),
    ])
    func realFixturesProduceTheirGroundTruthVerdictInTheReport(fixtureAndVerdict: (String, String)) throws {
        let (fixture, expectedVerdictID) = fixtureAndVerdict
        let file = try loadFixture(fixture)
        let diagnosis = DiagnosisEngine().diagnose(file)
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: .full, diagnosis: diagnosis)

        #expect(report.diagnosis.status == .verdict)
        #expect(report.diagnosis.verdict?.id == expectedVerdictID)
        #expect(report.diagnosis.hypotheses.contains { $0.hypothesis.id == expectedVerdictID })

        // Round-trip through JSON to confirm the verdict actually reaches the encoded
        // contract, not just the in-memory struct.
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(AnalysisReport.self, from: data)
        #expect(decoded.diagnosis.verdict?.id == expectedVerdictID)
    }

    @Test func swiftFrontendCorpusFixtureReachesItsGroundTruthInTheReport() throws {
        // Ground truth (see DiagnosisEngineTests.swiftFrontendCorpusFixtureIsAbortGenericWeakNotConfident):
        // only abort-generic applies, at weak band, so the overall diagnosis is honestly
        // inconclusive rather than a confident wrong label.
        let file = try loadFixture("swift-frontend-2026-07-15-212005")
        let diagnosis = DiagnosisEngine().diagnose(file)
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: .full, diagnosis: diagnosis)

        #expect(report.diagnosis.status == .inconclusive)
        #expect(report.diagnosis.verdict == nil)
        #expect(report.diagnosis.hypotheses.first?.hypothesis.id == "abort-generic")
        #expect(report.diagnosis.hypotheses.first?.band == .weak)
    }

    @Test func summaryTierHasDiagnosisButNoFactsConsidered() throws {
        let file = try loadFixture("nsexcrash")
        let diagnosis = DiagnosisEngine().diagnose(file)
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: .summary, diagnosis: diagnosis)

        // Verdict/hypotheses are present at every tier...
        #expect(report.diagnosis.status == .verdict)
        #expect(report.diagnosis.verdict?.id == "uncaught-objc-exception")
        #expect(!report.diagnosis.hypotheses.isEmpty)
        // ...but factsConsidered is stripped entirely (nil, not merely empty) at summary.
        #expect(report.diagnosis.factsConsidered == nil)

        // And confirm it's actually omitted from the encoded JSON, not just nil in memory.
        let encoder = JSONEncoder()
        let data = try encoder.encode(report)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("factsConsidered"))
    }

    @Test(arguments: [AnalysisReport.Tier.standard, .full])
    func standardAndFullTiersHaveFactsConsidered(tier: AnalysisReport.Tier) throws {
        let file = try loadFixture("nsexcrash")
        let diagnosis = DiagnosisEngine().diagnose(file)
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: tier, diagnosis: diagnosis)

        let facts = try #require(report.diagnosis.factsConsidered)
        #expect(!facts.isEmpty)
        #expect(facts.count == diagnosis.factsConsidered.count)
    }

    // MARK: - Round-trip

    @Test(arguments: allTiers)
    func roundTripsThroughJSON(tier: AnalysisReport.Tier) throws {
        let file = try loadFixture("nsexcrash")
        let original = AnalysisReport.build(from: file, symbolication: nil, tier: tier)

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(AnalysisReport.self, from: data)

        #expect(decoded.schemaVersion == original.schemaVersion)
        #expect(decoded.tier == original.tier)
        #expect(decoded.process.name == original.process.name)
        #expect(decoded.event.exceptionType == original.event.exceptionType)
        #expect(decoded.event.terminationIndicator == original.event.terminationIndicator)
        #expect(decoded.faultingThread?.frames.count == original.faultingThread?.frames.count)
        #expect(decoded.lastExceptionBacktrace?.count == original.lastExceptionBacktrace?.count)
        #expect(decoded.otherThreads?.count == original.otherThreads?.count)
        #expect(decoded.asiMessages == original.asiMessages)
        #expect(decoded.images?.count == original.images?.count)
        #expect(decoded.diagnosis.status == original.diagnosis.status)
    }

    // MARK: - Golden snapshot

    /// Byte-for-byte comparison against a committed golden file. Built WITHOUT
    /// symbolication (`symbolication: nil`) so it's deterministic across machines that
    /// may or may not have Xcode/atos available; `DiagnosisEngine` is itself deterministic
    /// (no I/O, no LLM calls — see `DiagnosisEngine.swift`'s header doc) so including its
    /// output here is still safe for a byte-exact golden. Nothing is normalized on either
    /// side - any change to field names, ordering, or presence must be a deliberate,
    /// reviewed diff to this fixture.
    @Test func nsexcrashSummaryMatchesGoldenSnapshot() throws {
        let file = try loadFixture("nsexcrash")
        let diagnosis = DiagnosisEngine().diagnose(file)
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: .summary, diagnosis: diagnosis)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let actual = try encoder.encode(report)

        let goldenURL = try fixtureURL("nsexcrash-summary-golden", extension: "json")
        let expected = try Data(contentsOf: goldenURL)

        #expect(actual == expected)
    }

    /// Second golden: `.standard` tier (so `factsConsidered` is present) against the real
    /// `nullderef` fixture (EXC_BAD_ACCESS null dereference) — see
    /// DiagnosisMemoryRulesTests.swift for the ground truth this diagnosis rests on.
    @Test func nullderefStandardMatchesGoldenSnapshot() throws {
        let file = try loadFixture("nullderef")
        let diagnosis = DiagnosisEngine().diagnose(file)
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: .standard, diagnosis: diagnosis)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let actual = try encoder.encode(report)

        let goldenURL = try fixtureURL("nullderef-standard-golden", extension: "json")
        let expected = try Data(contentsOf: goldenURL)

        #expect(actual == expected)
    }
}
