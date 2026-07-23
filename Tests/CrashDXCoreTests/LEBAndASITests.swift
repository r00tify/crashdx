import Foundation
import Testing
@testable import CrashDXCore

// Ground truth for corpus/fixtures/nsexcrash lives in corpus/README.md. Summary: a CLI
// Swift binary raises an uncaught NSException through doWork() -> throwingHelper(). The
// harvested .ips DOES carry lastExceptionBacktrace (7 frames, all with imageIndex +
// imageOffset). Its `asi` is present but is `{"libsystem_c.dylib": ["abort() called"]}` —
// the classic "*** Terminating app due to uncaught exception 'NAME', reason: 'REASON'"
// message is NOT written into `asi` for a plain CLI/Foundation process (verified, plus a
// negative NSSetUncaughtExceptionHandler experiment, plus 4 matching real corpus/raw/
// files). So this fixture exercises uncaughtExceptionName/-Reason as a NEGATIVE case; the
// positive (pattern-present) case is covered by a synthetic-asi test below.

private let nsexcrashUUID = "af44f940-3b8b-30e8-b88a-0297504b10d2"

private func fixtureURL(_ name: String, extension ext: String) throws -> URL {
    let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
    return try #require(url)
}

@Suite struct LEBAndASITests {
    @Test func nsexcrashFixtureExceptionAndTermination() throws {
        let file = try IPSFile.parse(contentsOf: fixtureURL("nsexcrash", extension: "ips"))

        #expect(file.header.bugType == "309")
        #expect(file.payload.procName == "nsexcrash")
        // Ground truth: the abort, not the original NSException, is what exception/
        // termination describe here.
        #expect(file.payload.exceptionType == "EXC_CRASH")
        #expect(file.payload.exceptionSignal == "SIGABRT")
        #expect(file.payload.terminationIndicator == "Abort trap: 6")
    }

    @Test func nsexcrashFixtureHasLastExceptionBacktrace() throws {
        let file = try IPSFile.parse(contentsOf: fixtureURL("nsexcrash", extension: "ips"))

        let leb = try #require(file.payload.lastExceptionBacktrace)
        #expect(leb.count == 7)
        for frame in leb {
            #expect(frame.imageIndex != nil)
            #expect(frame.imageOffset != nil)
        }
        // The three innermost app frames (doWork/throwingHelper/top-level) are
        // unsymbolicated in the raw report since the binary was stripped before crashing.
        #expect(leb.contains { $0.symbol == "objc_exception_throw" })
    }

    @Test func nsexcrashFixtureASIIsAbortOnlyNoExceptionMessage() throws {
        let file = try IPSFile.parse(contentsOf: fixtureURL("nsexcrash", extension: "ips"))

        #expect(file.payload.asiRaw != nil)
        #expect(!file.payload.asiMessages.isEmpty)
        #expect(file.payload.asiMessages.contains("abort() called"))

        // Ground truth negative case: no "Terminating app due to uncaught exception"
        // message reaches `asi` for this CLI process, so parsing correctly yields nil
        // rather than fabricating "NSRangeException" from context it doesn't have.
        #expect(file.payload.uncaughtExceptionName == nil)
        #expect(file.payload.uncaughtExceptionReason == nil)
    }

    @Test func nsexcrashFixtureSymbolicatesThrowingHelper() throws {
        let ipsData = try Data(contentsOf: fixtureURL("nsexcrash", extension: "ips"))
        let dsymURL = try fixtureURL("nsexcrash", extension: "dSYM")
        let dsyms = [nsexcrashUUID: dsymURL]

        let output = try Symbolicator().symbolicateWithAtos(ipsData: ipsData, dsyms: dsyms)

        let leb = try #require(output.file.payload.lastExceptionBacktrace)
        let symbols = leb.compactMap(\.symbol)
        // Verified empirically via atos directly against the fixture's dSYM.
        #expect(symbols.contains("throwingHelper()"))
        #expect(symbols.contains("doWork()"))

        let throwingHelperFrame = try #require(leb.first { $0.symbol == "throwingHelper()" })
        #expect(throwingHelperFrame.sourceFile == "main.swift")
        #expect(throwingHelperFrame.sourceLine == 8)
    }

    // Positive case for the "*** Terminating app due to uncaught exception" pattern:
    // exercised via a synthetic `asi`, since the real fixture doesn't naturally produce
    // one (see corpus/README.md).
    @Test func parsesUncaughtExceptionMessageWhenPresent() throws {
        var data = try Data(contentsOf: fixtureURL("crashspike-stripped", extension: "ips"))
        let newline = try #require(data.firstIndex(of: UInt8(ascii: "\n")))
        let headerLine = data[data.startIndex...newline]
        var payload = try #require(
            try JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any]
        )
        payload["asi"] = [
            "CoreFoundation": [
                "*** Terminating app due to uncaught exception 'NSRangeException', reason: 'index 42 beyond bounds'"
            ]
        ]
        data = headerLine + (try JSONSerialization.data(withJSONObject: payload))

        let file = try IPSFile.parse(data: data)
        #expect(file.payload.uncaughtExceptionName == "NSRangeException")
        #expect(file.payload.uncaughtExceptionReason == "index 42 beyond bounds")
        #expect(file.payload.asiMessages.contains {
            $0.contains("Terminating app due to uncaught exception")
        })
    }

    @Test func syntheticLastExceptionBacktraceIsExposed() throws {
        // xcsym's verified failure mode: LEB silently dropped. Guarantee we never regress.
        var data = try Data(contentsOf: fixtureURL("crashspike-stripped", extension: "ips"))
        let newline = try #require(data.firstIndex(of: UInt8(ascii: "\n")))
        let headerLine = data[data.startIndex...newline]
        var payload = try #require(
            try JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any]
        )
        payload["lastExceptionBacktrace"] = [["imageIndex": 0, "imageOffset": 1234]]
        payload["asi"] = ["CoreFoundation": ["*** Terminating app due to uncaught exception 'NSRangeException'"]]
        data = headerLine + (try JSONSerialization.data(withJSONObject: payload))

        let file = try IPSFile.parse(data: data)
        let leb = try #require(file.payload.lastExceptionBacktrace)
        #expect(leb.count == 1)
        #expect(leb[0].imageIndex == 0)
        #expect(leb[0].imageOffset == 1234)
        #expect(file.payload.lastExceptionBacktraceRaw?.count == 1)
        #expect(file.payload.asiRaw != nil)
    }
}
