import Foundation
import Testing
@testable import CrashDXCore

// These parse the OUTPUT OF EXTERNAL TOOLS (`atos`, `dwarfdump`), which is the one place
// crashdx can produce a confidently wrong answer rather than an honest "unknown": a
// mis-parsed line attaches a real-looking symbol and source location to a frame, and
// every downstream hypothesis inherits that mistake.
//
// A prior mutation audit found ten behaviours here that the suite could not detect at
// all — the mutants below are each pinned by one test.

@Suite struct ParserEdgeCaseTests {

    // MARK: - atos line parsing

    @Test func parsesTheOrdinaryResolvedForm() {
        let r = Symbolicator.parseAtosLine("applyDiscount(_:) (in crashspike) (main.swift:10)")
        #expect(r?.symbol == "applyDiscount(_:)")
        #expect(r?.sourceFile == "main.swift")
        #expect(r?.sourceLine == 10)
    }

    /// `file:LINE:COLUMN` must not be read as file `file:LINE` at line COLUMN — that
    /// names a file which does not exist and points at the wrong line.
    @Test func columnSuffixDoesNotCorruptTheFileNameOrLine() {
        let r = Symbolicator.parseAtosLine("f() (in M) (Widget.swift:120:8)")
        #expect(r?.sourceFile == "Widget.swift")
        #expect(r?.sourceLine == 120)
    }

    /// atos's form when it resolved a symbol but has no line table for the address.
    /// Dropping it made crashdx report "did not resolve any frames" for an image atos
    /// had in fact symbolicated.
    @Test func symbolOnlyFormKeepsTheSymbol() {
        let r = Symbolicator.parseAtosLine("applyDiscount(_:) (in crashspike) + 44")
        #expect(r?.symbol == "applyDiscount(_:)")
        #expect(r?.sourceFile == nil)
        #expect(r?.sourceLine == nil)
    }

    /// MUTANT: keeping `<compiler-generated>` as a real `sourceFile`. It is atos's marker
    /// for source-less code, not a file anyone can open.
    @Test func compilerGeneratedIsNotReportedAsASourceFile() {
        for line in [
            "thunk (in M) (/<compiler-generated>:0)",
            "thunk (in M) (<compiler-generated>:0)",
        ] {
            let r = Symbolicator.parseAtosLine(line)
            #expect(r?.symbol.isEmpty == false)
            #expect(r?.sourceFile == nil, "\(line)")
            #expect(r?.sourceLine == nil)
        }
    }

    @Test func symbolsContainingSpacesParensAndInAreRecoveredWhole() {
        #expect(Symbolicator.parseAtosLine("foo (in place) (fast) (in M) (a.swift:1)")?.symbol
                == "foo (in place) (fast)")
        #expect(Symbolicator.parseAtosLine(
            "std::__1::vector<int, std::allocator<int>>::push_back(int&&) (in M) (v.h:1512)"
        )?.symbol == "std::__1::vector<int, std::allocator<int>>::push_back(int&&)")
        #expect(Symbolicator.parseAtosLine("-[NSException raise] (in CoreFoundation) (x.m:1)")?.symbol
                == "-[NSException raise]")
    }

    /// Unresolvable addresses are echoed back verbatim; that is not a symbol.
    @Test func unparseableLinesYieldNilRatherThanAFabricatedSymbol() {
        for line in ["", "0x100003f4c", "garbage", "0x1 (in M)", " (in M) (a.swift:1)"] {
            #expect(Symbolicator.parseAtosLine(line) == nil, "should not parse: \(line.debugDescription)")
        }
    }

    @Test func locationWithNoFileNameYieldsNoSourceFile() {
        let r = Symbolicator.parseAtosLine("f() (in M) (:12)")
        #expect(r?.symbol == "f()")
        #expect(r?.sourceFile == nil)
    }

    // MARK: - CrashSymbolicator.py output

    /// The script prints `Symbolicating thread N` to stdout before its JSON, so the
    /// parser must skip leading noise — but must not accept output with no JSON at all.
    @Test func crashSymbolicatorNoiseIsSkippedAndAbsentJSONFailsClosed() throws {
        let real = try Data(contentsOf: #require(
            Bundle.module.url(forResource: "nsexcrash", withExtension: "ips", subdirectory: "Fixtures")
        ))
        let text = String(decoding: real, as: UTF8.self)

        let noisy = "Symbolicating thread 0\nSymbolicating thread 1\n" + text
        #expect(Symbolicator.parseCrashSymbolicatorOutput(noisy) != nil)
        #expect(Symbolicator.parseCrashSymbolicatorOutput(text) != nil)

        for bad in ["", "Symbolicating thread 0\n", "no json here at all\n"] {
            #expect(Symbolicator.parseCrashSymbolicatorOutput(bad) == nil, "parsed: \(bad.debugDescription)")
        }
    }

    // MARK: - Mutants in the parsing/model layer

    /// MUTANT: collapsing the error taxonomy. `rejectsGarbageInput` only asserts the
    /// error TYPE, so every case was interchangeable.
    @Test func emptyInputThrowsEmptyFileSpecifically() {
        do {
            _ = try IPSFile.parse(data: Data())
            Issue.record("expected a throw")
        } catch IPSParseError.emptyFile {
            // correct
        } catch {
            Issue.record("expected IPSParseError.emptyFile, got \(error)")
        }
    }

    @Test func badPayloadAfterGoodHeaderThrowsInvalidPayload() {
        do {
            _ = try IPSFile.parse(data: Data("{\"a\":1}\nnot json".utf8))
            Issue.record("expected a throw")
        } catch IPSParseError.invalidPayload {
            // correct
        } catch {
            Issue.record("expected .invalidPayload, got \(error)")
        }

        // A payload that is valid JSON but not an object is still a payload problem.
        do {
            _ = try IPSFile.parse(data: Data("{\"a\":1}\n[1,2,3]".utf8))
            Issue.record("expected a throw")
        } catch IPSParseError.invalidPayload {
            // correct
        } catch {
            Issue.record("expected .invalidPayload, got \(error)")
        }

        // ...and a bad HEADER must not be conflated with it in the other direction.
        do {
            _ = try IPSFile.parse(data: Data("[1,2]\n{}".utf8))
            Issue.record("expected a throw")
        } catch IPSParseError.invalidHeader {
            // correct
        } catch {
            Issue.record("expected .invalidHeader, got \(error)")
        }
    }

    /// MUTANT: dropping tolerance for string-encoded numbers, which the parser documents
    /// because third-party report writers emit them.
    @Test func stringEncodedNumbersAreAccepted() throws {
        let data = Data("""
        {"bug_type":"309"}
        {"faultingThread":"0","threads":[{"triggered":true,"frames":[{"imageIndex":"0","imageOffset":"2596"}]}],"usedImages":[{"name":"x","arch":"arm64"}]}
        """.utf8)
        let file = try IPSFile.parse(data: data)
        #expect(file.payload.faultingThreadIndex == 0)
        let frame = try #require(file.payload.threads.first?.frames.first)
        #expect(frame.imageIndex == 0)
        #expect(frame.imageOffset == 2596)
    }

    /// MUTANT: dropping `.sorted()` from `asiMessages`, whose doc promises determinism.
    /// Twelve keys make an accidental sorted order vanishingly unlikely (1/12!).
    @Test func asiMessagesAreSortedByLibraryName() throws {
        let libs = (0..<12).map { "lib\(UnicodeScalar(UInt8(97 + $0)))" }
        let asi = Dictionary(uniqueKeysWithValues: libs.map { ($0, ["msg from \($0)"]) })
        let payload = try JSONSerialization.data(withJSONObject: ["asi": asi])
        let file = try IPSFile.parse(data: Data("{}\n".utf8) + payload)
        #expect(file.payload.asiMessages == file.payload.asiMessages.sorted())
    }

    /// MUTANT: `>= 3 consecutive` loosened to `>= 2`. Two adjacent identical symbols is a
    /// routine shape (a thunk beside its target); calling it recursion adds a point to
    /// stack-overflow and can flip an honest inconclusive into a verdict.
    @Test func twoConsecutiveIdenticalSymbolsIsNotARecursionPattern() throws {
        func facts(symbols: [String]) throws -> [Fact] {
            let frames = symbols.map { ["imageIndex": 0, "imageOffset": 4, "symbol": $0] as [String: Any] }
            let payload = try JSONSerialization.data(withJSONObject: [
                "faultingThread": 0,
                "threads": [["triggered": true, "frames": frames]],
                "usedImages": [["name": "x", "arch": "arm64"]],
            ])
            let file = try IPSFile.parse(data: Data("{}\n".utf8) + payload)
            return FrameFactsExtractor().extract(from: file)
        }
        func hasRecursion(_ symbols: [String]) throws -> Bool {
            try facts(symbols: symbols).contains { $0.id == "frames.recursion-pattern" }
        }

        #expect(try !hasRecursion(["a", "a", "b", "c"]))
        #expect(try !hasRecursion(["a", "b", "b", "c"]))
        #expect(try !hasRecursion(["a", "b", "c", "c"]))
        #expect(try hasRecursion(["a", "b", "b", "b", "c"]))
    }

    /// MUTANT: greedy `(.+)` made lazy. Exception reasons routinely embed single quotes,
    /// and a lazy match truncates at the first one while presenting the fragment as the
    /// whole reason.
    @Test func uncaughtExceptionReasonKeepsEmbeddedSingleQuotes() throws {
        let reason = "-[__NSCFString objectForKey:]: unrecognized selector sent to instance 'x' at 'y'"
        let asi = ["CoreFoundation": [
            "*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: '\(reason)'",
        ]]
        let payload = try JSONSerialization.data(withJSONObject: ["asi": asi])
        let file = try IPSFile.parse(data: Data("{}\n".utf8) + payload)
        #expect(file.payload.uncaughtExceptionName == "NSInvalidArgumentException")
        #expect(file.payload.uncaughtExceptionReason == reason)
    }
}
