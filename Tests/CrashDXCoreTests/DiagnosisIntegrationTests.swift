import Foundation
import Testing
@testable import CrashDXCore

// Exercises the wiring between `Symbolicator`, `DiagnosisEngine`, and
// `AnalysisReport` end to end — none of the existing suites cover a symbolicated file
// being fed to the diagnosis engine. Ground truth: corpus/README.md's nsexcrash section
// (`doWork()` calls `throwingHelper()`, which raises); LEBAndASITests.swift's
// `nsexcrashFixtureSymbolicatesThrowingHelper` independently establishes that atos
// resolves the LEB's deepest app frame to `throwingHelper()` at main.swift:8.

private let nsexcrashUUID = "af44f940-3b8b-30e8-b88a-0297504b10d2"

private func fixtureURL(_ name: String, extension ext: String, subdirectory: String = "Fixtures") throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory))
}

private func loadFixture(_ name: String) throws -> IPSFile {
    try IPSFile.parse(contentsOf: fixtureURL(name, extension: "ips"))
}

@Suite struct DiagnosisIntegrationTests {

    // MARK: - Diagnosing an unsymbolicated file still reaches the same verdict...

    @Test func nsexcrashUnsymbolicatedInspectPointHasNoSourceInfo() throws {
        // Baseline: without symbolication, the uncaught-objc-exception inspect point
        // carries a symbol (already present in the raw report for this LEB frame's
        // same-offset thread neighbor — see FrameSentinel's LEB-trust resolution) but no
        // source file/line, since nothing has run atos/CrashSymbolicator on it yet.
        let file = try loadFixture("nsexcrash")
        let diagnosis = DiagnosisEngine().diagnose(file)
        let verdict = try #require(diagnosis.verdict)
        #expect(verdict.id == "uncaught-objc-exception")
        let point = try #require(verdict.inspect.first)
        #expect(point.sourceFile == nil)
        #expect(point.sourceLine == nil)
    }

    // MARK: - ...but symbolicating FIRST enriches the frames the rules see (deliberate)

    @Test func nsexcrashSymbolicatedInspectPointCarriesSymbolAndSourceInfo() throws {
        let ipsData = try Data(contentsOf: fixtureURL("nsexcrash", extension: "ips"))
        let dsymURL = try fixtureURL("nsexcrash", extension: "dSYM")
        let dsyms = [nsexcrashUUID: dsymURL]

        let output = try Symbolicator().symbolicateWithAtos(ipsData: ipsData, dsyms: dsyms)

        // Diagnose the SYMBOLICATED file (output.file), not the original — this is the
        // exact ordering `runAnalyze` in main.swift now uses.
        let diagnosis = DiagnosisEngine().diagnose(output.file)

        #expect(diagnosis.status == .verdict)
        let verdict = try #require(diagnosis.verdict)
        #expect(verdict.id == "uncaught-objc-exception")

        let point = try #require(verdict.inspect.first)
        #expect(point.leb == true)
        #expect(point.symbol == "throwingHelper()")
        #expect(point.sourceFile == "main.swift")
        #expect(point.sourceLine == 8)
    }

    @Test func symbolicatedDiagnosisFlowsThroughAnalysisReportBuild() throws {
        let ipsData = try Data(contentsOf: fixtureURL("nsexcrash", extension: "ips"))
        let dsymURL = try fixtureURL("nsexcrash", extension: "dSYM")
        let dsyms = [nsexcrashUUID: dsymURL]

        let output = try Symbolicator().symbolicateWithAtos(ipsData: ipsData, dsyms: dsyms)
        let diagnosis = DiagnosisEngine().diagnose(output.file)

        let originalFile = try loadFixture("nsexcrash")
        let report = AnalysisReport.build(from: originalFile, symbolication: output, tier: .standard, diagnosis: diagnosis)

        #expect(report.diagnosis.status == .verdict)
        let verdictInReport = try #require(report.diagnosis.verdict)
        #expect(verdictInReport.id == "uncaught-objc-exception")
        let point = try #require(verdictInReport.inspect.first)
        #expect(point.symbol == "throwingHelper()")
        #expect(point.sourceFile == "main.swift")
    }
}
