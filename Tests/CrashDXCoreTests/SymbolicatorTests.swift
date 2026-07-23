import Foundation
import Testing
@testable import CrashDXCore

// Ground truth: corpus/fixtures/crashspike/crashspike.dSYM, copied into Fixtures/, has
// UUID 657A6675-2D2C-32CA-8C31-3A8C948DF5FE (arm64) with its DWARF file at
// Contents/Resources/DWARF/crashspike — see corpus/README.md's crashspike section.
//
// crashspike-unsymbolicated.ips is a hand-edited derivative of crashspike-stripped.ips
// with `symbol`/`symbolLocation`/`sourceFile`/`sourceLine` removed from every frame in
// every thread. It exists because the harvested report arrives already symbolicated
// (ReportCrash resolves the dSYM locally via Spotlight), so it is the only fixture that
// actually exercises the symbolication path end to end.

private let crashspikeUUID = "657a6675-2d2c-32ca-8c31-3a8c948df5fe"

@Suite struct SymbolicatorTests {
    private func fixtureData(_ name: String, extension ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func fixtureDSYM() throws -> URL {
        try #require(Bundle.module.url(forResource: "crashspike", withExtension: "dSYM", subdirectory: "Fixtures"))
    }

    @Test func crashSymbolicatorRestoresSymbols() throws {
        guard Symbolicator.locateCrashSymbolicatorScript() != nil else {
            // CrashSymbolicator.py isn't available on this machine (no Xcode, or a
            // layout that doesn't match the verified path) - nothing to test here.
            return
        }

        let ipsData = try fixtureData("crashspike-unsymbolicated", extension: "ips")
        let dsyms = [crashspikeUUID: try fixtureDSYM()]

        let output = try Symbolicator().symbolicate(ipsData: ipsData, dsyms: dsyms)

        #expect(output.engine == .crashSymbolicator)

        let thread = try #require(output.file.payload.faultingThread)
        let applyDiscountFrame = try #require(thread.frames.first { $0.symbol == "applyDiscount(_:)" })
        #expect(applyDiscountFrame.sourceFile == "main.swift")
        #expect(applyDiscountFrame.sourceLine == 10)

        let crashspikeStatus = try #require(output.imageStatuses.first { $0.imageName == "crashspike" })
        #expect(crashspikeStatus.outcome == .symbolicated(.crashSymbolicator))
    }

    @Test func atosFallbackRestoresSymbols() throws {
        let ipsData = try fixtureData("crashspike-unsymbolicated", extension: "ips")
        let dsyms = [crashspikeUUID: try fixtureDSYM()]

        let output = try Symbolicator().symbolicateWithAtos(ipsData: ipsData, dsyms: dsyms)

        #expect(output.engine == .atos)

        let thread = try #require(output.file.payload.faultingThread)
        let symbols = thread.frames.compactMap(\.symbol)
        #expect(symbols.contains("applyDiscount(_:)"))

        // atos can return "/<compiler-generated>:0" for the crash-site frame itself, so
        // check source info on the next frame up instead.
        let processOrderFrame = try #require(thread.frames.first { $0.symbol == "processOrder(_:)" })
        #expect(processOrderFrame.sourceFile == "main.swift")
        #expect(processOrderFrame.sourceLine == 14)

        let crashspikeStatus = try #require(output.imageStatuses.first { $0.imageName == "crashspike" })
        #expect(crashspikeStatus.outcome == .symbolicated(.atos))
    }

    @Test func noDSYMReportedHonestly() throws {
        let ipsData = try fixtureData("crashspike-unsymbolicated", extension: "ips")

        let output = try Symbolicator().symbolicate(ipsData: ipsData, dsyms: [:])

        #expect(!output.imageStatuses.isEmpty)
        for status in output.imageStatuses {
            #expect(status.outcome == .noDSYM)
        }

        // No dSYM was supplied for anything, so nothing should have been resolved -
        // system-image frames (e.g. libswiftCore's _assertionFailure) stay untouched.
        let thread = try #require(output.file.payload.faultingThread)
        #expect(thread.frames.allSatisfy { $0.symbol == nil })
        #expect(thread.triggered) // triggered thread survives round-trip
    }
}
