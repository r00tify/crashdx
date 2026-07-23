import Foundation
import Testing
@testable import CrashDXCore

// Ground truth for this fixture lives in corpus/fixtures/crashspike: a deliberate Swift
// force-unwrap crash (EXC_BREAKPOINT/SIGTRAP) in a stripped binary, symbolicated by
// ReportCrash via the Spotlight-indexed dSYM. See corpus/README.md.

private func fixtureURL(_ name: String) throws -> URL {
    let url = Bundle.module.url(forResource: name, withExtension: "ips", subdirectory: "Fixtures")
    return try #require(url)
}

@Suite struct IPSFileTests {
    @Test func parsesCrashspikeFixture() throws {
        let file = try IPSFile.parse(contentsOf: fixtureURL("crashspike-stripped"))

        #expect(file.header.bugType == "309")
        #expect(file.header.appName == "crashspike")
        #expect(file.payload.procName == "crashspike")
        #expect(file.payload.exceptionType == "EXC_BREAKPOINT")
        #expect(file.payload.exceptionSignal == "SIGTRAP")
        #expect(file.payload.terminationIndicator == "Trace/BPT trap: 5")
    }

    @Test func resolvesFaultingThreadAndFrames() throws {
        let file = try IPSFile.parse(contentsOf: fixtureURL("crashspike-stripped"))

        let thread = try #require(file.payload.faultingThread)
        #expect(thread.triggered)

        let symbols = thread.frames.compactMap(\.symbol)
        #expect(symbols.contains("applyDiscount(_:)"))
        #expect(symbols.contains("processOrder(_:)"))

        // Every frame must carry a resolvable image reference with a UUID.
        let images = file.payload.usedImages
        for frame in thread.frames {
            let idx = try #require(frame.imageIndex)
            #expect(images.indices.contains(idx))
            #expect(frame.imageOffset != nil)
        }
        #expect(images.allSatisfy { $0.uuid != nil && $0.base != nil })
    }

    @Test func leniencyPreservesUnmodeledKeys() throws {
        let file = try IPSFile.parse(contentsOf: fixtureURL("crashspike-stripped"))

        // Full-fidelity requirement: unmodeled payload keys must survive in raw form.
        #expect(file.payload.raw["vmSummary"] != nil || file.payload.raw["instructionByteStream"] != nil)
        // Undocumented header keys observed in real files must be retained too.
        #expect(file.header.raw["slice_uuid"] != nil)
    }

    @Test func rejectsGarbageInput() {
        #expect(throws: IPSParseError.self) {
            _ = try IPSFile.parse(data: Data("not json\nstill not json".utf8))
        }
        #expect(throws: IPSParseError.self) {
            _ = try IPSFile.parse(data: Data())
        }
    }
}

// LEB (lastExceptionBacktrace) and ASI (applicationSpecificInformation) are now
// first-class, backed by a real uncaught-NSException fixture — see LEBAndASITests.swift
// and corpus/README.md ("fixtures/nsexcrash/") for ground truth.
