import Foundation
import Testing
@testable import CrashDXCore

// Ground truth this suite depends on:
// - corpus/README.md "fixtures/nsexcrash/": real uncaught-NSException CLI crash, LEB
//   present, faulting thread carries BOTH __cxa_throw AND objc_exception_throw (ObjC
//   exceptions ride the C++ ABI) — the asymmetry test for cxx-terminate vs
//   uncaught-objc-exception.
// - corpus/README.md "fixtures/crashspike/": EXC_BREAKPOINT/SIGTRAP force-unwrap; no
//   termination/exception-family rule should claim anything about it — swift-fatal-trap
//   owns this fixture.
// - corpus/raw/swift-frontend-2026-07-15-212005.ips (real, copied into Fixtures/): SIGABRT
//   via abort()/pthread_kill with an llvm::report_fatal_error chain — no __cxa_throw, no
//   objc_exception_throw, no lastExceptionBacktrace anywhere in the file (verified by
//   direct inspection before writing these tests).
// - Synthetic fixtures under Fixtures/synthetic/ built from crashspike-stripped.ips's
//   payload with `termination`/`exception` blocks transplanted to match Apple's
//   documented shapes for watchdog, 0xdead10cc, jetsam, and code-signing kills (we have no
//   real reports for these four); cxx-terminate-only.ips is nsexcrash.ips with the
//   objc_exception_throw/-[NSException raise] frames and lastExceptionBacktrace removed,
//   isolating the pure-C++ std::terminate path docs/DESIGN.md's testing policy asks
//   for. Decimal termination codes were independently verified: 0x8badf00d = 2343432205,
//   0xdead10cc = 3735883980, 0xc51bad01/02/03 = 3306925313/3306925314/3306925315.

private func fixtureURL(_ name: String, subdirectory: String = "Fixtures") throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "ips", subdirectory: subdirectory))
}

private func loadFixture(_ name: String, subdirectory: String = "Fixtures") throws -> IPSFile {
    try IPSFile.parse(contentsOf: fixtureURL(name, subdirectory: subdirectory))
}

/// Parses `crashspike-stripped.ips` and applies `mutate` to its JSON payload before
/// re-parsing — the established in-repo pattern (see LEBAndASITests.swift) for exercising
/// a payload shape we don't have a standalone fixture for.
private func mutatedCrashspike(_ mutate: (inout [String: Any]) -> Void) throws -> IPSFile {
    var data = try Data(contentsOf: fixtureURL("crashspike-stripped"))
    let newline = try #require(data.firstIndex(of: UInt8(ascii: "\n")))
    let headerLine = data[data.startIndex...newline]
    var payload = try #require(
        try JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any]
    )
    mutate(&payload)
    data = headerLine + (try JSONSerialization.data(withJSONObject: payload))
    return try IPSFile.parse(data: data)
}

@Suite struct DiagnosisEngineTests {

    // MARK: - watchdog-timeout

    @Test func watchdogTimeoutFiresOnSyntheticFixture() throws {
        let file = try loadFixture("watchdog-scene-create", subdirectory: "Fixtures/synthetic")
        let diagnosis = DiagnosisEngine().diagnose(file)

        let ranked = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "watchdog-timeout" })
        #expect(ranked.score >= 4)
        #expect(ranked.band == .strong)
        #expect(ranked.hypothesis.explanation.contains("STUCK"))
        #expect(diagnosis.status == .verdict)
        #expect(diagnosis.verdict?.id == "watchdog-timeout")
    }

    @Test func watchdogTimeoutDoesNotFireOnUnrelatedCrash() throws {
        let file = try loadFixture("crashspike-stripped")
        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "watchdog-timeout" })
    }

    // MARK: - background-task-overrun (0xdead10cc)

    @Test func backgroundTaskOverrunFiresOnSyntheticFixture() throws {
        let file = try loadFixture("dead10cc", subdirectory: "Fixtures/synthetic")
        let diagnosis = DiagnosisEngine().diagnose(file)

        let ranked = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "background-task-overrun" })
        #expect(ranked.score >= 4)
        #expect(ranked.band == .strong)
        #expect(diagnosis.verdict?.id == "background-task-overrun")
    }

    @Test func backgroundTaskOverrunDoesNotFireOnUnrelatedCrash() throws {
        let file = try loadFixture("crashspike-stripped")
        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "background-task-overrun" })
    }

    // MARK: - jetsam-memory-kill

    @Test func jetsamMemoryKillDistinguishesPerProcessLimit() throws {
        let file = try loadFixture("jetsam-per-process-limit", subdirectory: "Fixtures/synthetic")
        let diagnosis = DiagnosisEngine().diagnose(file)

        let ranked = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "jetsam-memory-kill" })
        #expect(ranked.hypothesis.explanation.contains("OWN per-process"))
        #expect(!ranked.hypothesis.explanation.contains("SYSTEM-WIDE"))
    }

    @Test func jetsamMemoryKillDistinguishesSystemPressure() throws {
        let file = try loadFixture("jetsam-vm-pageshortage", subdirectory: "Fixtures/synthetic")
        let diagnosis = DiagnosisEngine().diagnose(file)

        let ranked = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "jetsam-memory-kill" })
        #expect(ranked.hypothesis.explanation.contains("SYSTEM-WIDE"))
        #expect(!ranked.hypothesis.explanation.contains("OWN per-process"))
    }

    @Test func jetsamMemoryKillDoesNotFireOnUnrelatedCrash() throws {
        let file = try loadFixture("crashspike-stripped")
        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "jetsam-memory-kill" })
    }

    // MARK: - watchos-background-task-overrun

    // GROUND TRUTH (Apple, "EXC_CRASH (SIGKILL)"): 0xc51bad01/02/03 are watchOS
    // BACKGROUND-TASK budget codes, not code-signing codes. An earlier version of this
    // rule read them as CS_KILLED and told developers to run `codesign --verify` for what
    // is actually a slow background task — and these tests asserted that wrong answer.

    @Test func watchOSBackgroundTaskFiresForCPUBudget() throws {
        let file = try loadFixture("code-signing-invalid-page", subdirectory: "Fixtures/synthetic")
        let diagnosis = DiagnosisEngine().diagnose(file)

        let ranked = try #require(
            diagnosis.hypotheses.first { $0.hypothesis.id == "system-termination" }
        )
        #expect(ranked.hypothesis.title.contains("CPU budget"))
        #expect(ranked.hypothesis.explanation.contains("background task"))
        // Must NOT send the developer to audit code signing.
        #expect(!ranked.hypothesis.confirmFurtherBy.contains { $0.contains("codesign") })
    }

    @Test func watchOSBackgroundTaskDistinguishesTimeoutCode() throws {
        // 0xc51bad02 = 3306925314, via in-memory mutation rather than a second fixture.
        let file = try mutatedCrashspike { payload in
            payload["termination"] = [
                "flags": 0, "code": 3_306_925_314, "namespace": "WATCHDOG",
                "indicator": "BACKGROUND_TASK_TIMEOUT",
            ]
        }
        let diagnosis = DiagnosisEngine().diagnose(file)
        let ranked = try #require(
            diagnosis.hypotheses.first { $0.hypothesis.id == "system-termination" }
        )
        #expect(ranked.hypothesis.title.contains("ran out of time"))
    }

    /// Apple states plainly that 0xc51bad03 "doesn't indicate that the app did anything
    /// wrong" — the system was simply too busy. The verdict must not blame the app.
    @Test func watchOSBackgroundTaskDoesNotBlameTheAppForSystemLoad() throws {
        let file = try mutatedCrashspike { payload in
            payload["termination"] = [
                "flags": 0, "code": 3_306_925_315, "namespace": "WATCHDOG",
                "indicator": "BACKGROUND_TASK_TIMEOUT",
            ]
        }
        let diagnosis = DiagnosisEngine().diagnose(file)
        let ranked = try #require(
            diagnosis.hypotheses.first { $0.hypothesis.id == "system-termination" }
        )
        #expect(ranked.hypothesis.explanation.contains("NOT indicating"))
        #expect(ranked.hypothesis.confirmFurtherBy.first?.contains("without the app") == true)
    }

    @Test func watchOSBackgroundTaskDoesNotFireOnUnrelatedCrash() throws {
        let file = try loadFixture("crashspike-stripped")
        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "system-termination" })
    }

    // MARK: - cxx-terminate

    @Test func cxxTerminateFiresOnSyntheticPureCxxFixture() throws {
        let file = try loadFixture("cxx-terminate-only", subdirectory: "Fixtures/synthetic")
        let diagnosis = DiagnosisEngine().diagnose(file)

        let ranked = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "cxx-terminate" })
        // No objc_exception_throw anywhere in this fixture, so no contradiction fires.
        #expect(ranked.score == 4)
        #expect(ranked.band == .strong)
        #expect(diagnosis.verdict?.id == "cxx-terminate")
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "uncaught-objc-exception" })
    }

    @Test func cxxTerminateDoesNotFireOnUnrelatedCrash() throws {
        let file = try loadFixture("crashspike-stripped")
        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "cxx-terminate" })
    }

    // MARK: - uncaught-objc-exception

    @Test func uncaughtObjCExceptionFiresOnRealNsexcrashFixture() throws {
        let file = try loadFixture("nsexcrash")
        let diagnosis = DiagnosisEngine().diagnose(file)
        let ranked = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "uncaught-objc-exception" })
        #expect(ranked.band == .strong)
    }

    @Test func uncaughtObjCExceptionDoesNotFireWithoutLEB() throws {
        let file = try loadFixture("crashspike-stripped")
        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "uncaught-objc-exception" })
    }

    @Test func uncaughtObjCExceptionDoesNotFireWithLEBButNoObjcThrowFrame() throws {
        // LEB present, but its frames don't include objc_exception_throw anywhere — the
        // rule requires that specific combination (ground truth), not LEB presence alone.
        let file = try mutatedCrashspike { payload in
            payload["lastExceptionBacktrace"] = [["imageIndex": 0, "imageOffset": 1234, "symbol": "someUnrelatedFunction"]]
        }
        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "uncaught-objc-exception" })
    }

    @Test func uncaughtExceptionAsiTextAbsenceIsNotHeldAgainstIt() throws {
        // nsexcrash's real asi carries no "Terminating app due to uncaught exception"
        // text (ground truth) — confirm the rule still fires at full pathognomonic
        // strength (no missing-fact penalty).
        let file = try loadFixture("nsexcrash")
        #expect(file.payload.uncaughtExceptionName == nil)

        let diagnosis = DiagnosisEngine().diagnose(file)
        let ranked = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "uncaught-objc-exception" })
        #expect(ranked.hypothesis.contradicting.isEmpty)
    }

    // MARK: - abort-generic

    @Test func abortGenericFiresOnRealSwiftFrontendFixture() throws {
        let file = try loadFixture("swift-frontend-2026-07-15-212005")
        let diagnosis = DiagnosisEngine().diagnose(file)
        let ranked = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "abort-generic" })
        #expect(ranked.band == .weak)
    }

    @Test func abortGenericDoesNotFireOnNonAbortSignal() throws {
        let file = try loadFixture("crashspike-stripped")
        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "abort-generic" })
    }

    // MARK: - Real-fixture ground truth: nsexcrash competing hypotheses

    @Test func nsexcrashUncaughtObjCExceptionIsTheVerdict() throws {
        let file = try loadFixture("nsexcrash")
        let diagnosis = DiagnosisEngine().diagnose(file)

        #expect(diagnosis.status == .verdict)
        #expect(diagnosis.verdict?.id == "uncaught-objc-exception")

        let byID = Dictionary(uniqueKeysWithValues: diagnosis.hypotheses.map { ($0.hypothesis.id, $0) })
        let objcScore = try #require(byID["uncaught-objc-exception"]).score
        let cxxScore = try #require(byID["cxx-terminate"]).score
        let abortScore = try #require(byID["abort-generic"]).score

        // cxx-terminate fires (both __cxa_throw and terminate-handler are on the faulting
        // thread) but ranks below uncaught-objc-exception because the same-thread
        // objc_exception_throw sentinel contradicts it.
        #expect(cxxScore < objcScore)
        // abort-generic — the honest low-confidence fallback — ranks below both.
        #expect(abortScore < cxxScore)
        #expect(abortScore < objcScore)

        // Deterministic ranking should place them in this exact order.
        let ids = diagnosis.hypotheses.map(\.hypothesis.id)
        let objcIdx = try #require(ids.firstIndex(of: "uncaught-objc-exception"))
        let cxxIdx = try #require(ids.firstIndex(of: "cxx-terminate"))
        let abortIdx = try #require(ids.firstIndex(of: "abort-generic"))
        #expect(objcIdx < cxxIdx)
        #expect(cxxIdx < abortIdx)

        // inspect must point at an app-image frame IN THE LEB (ground truth).
        let verdict = try #require(diagnosis.verdict)
        let point = try #require(verdict.inspect.first)
        #expect(point.leb == true)
        #expect(point.threadIndex == nil)
        let lebFrames = try #require(file.payload.lastExceptionBacktrace)
        let frameIdx = try #require(point.frameIndex)
        #expect(lebFrames.indices.contains(frameIdx))
        #expect(lebFrames[frameIdx].imageIndex == 0) // nsexcrash's own image
    }

    // MARK: - crashspike: swift-fatal-trap turns this into a verdict

    @Test func crashspikeIsSwiftFatalTrapVerdict() throws {
        // With only the termination/exception-family rules, crashspike-stripped (Swift
        // force-unwrap, EXC_BREAKPOINT/_assertionFailure) was honestly inconclusive —
        // none of them applies to it. swift-fatal-trap is the rule that turns this
        // fixture into a confident verdict
        // — see Rules/SwiftFatalTrapRule.swift and DiagnosisMemoryRulesTests.swift
        // for the full positive/negative coverage of that rule; this test only guards the
        // flip itself so a future regression here is caught immediately.
        let file = try loadFixture("crashspike-stripped")
        let diagnosis = DiagnosisEngine().diagnose(file)

        #expect(!diagnosis.hypotheses.isEmpty)
        #expect(diagnosis.status == .verdict)
        #expect(diagnosis.verdict?.id == "swift-fatal-trap")
        #expect(!diagnosis.factsConsidered.isEmpty)
    }

    // MARK: - swift-frontend corpus fixture ground truth

    @Test func swiftFrontendCorpusFixtureIsAbortGenericWeakNotConfident() throws {
        // Verified by direct inspection before writing this test: SIGABRT via
        // __pthread_kill/pthread_kill/abort, then llvm::report_fatal_error /
        // swift::DiagnosticHelper frames — no __cxa_throw, no objc_exception_throw, no
        // lastExceptionBacktrace anywhere in the file. Only abort-generic applies, and its
        // weak band keeps the overall diagnosis honestly inconclusive.
        let file = try loadFixture("swift-frontend-2026-07-15-212005")
        #expect(file.payload.exceptionSignal == "SIGABRT")
        #expect(file.payload.lastExceptionBacktrace == nil)

        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(diagnosis.status == .inconclusive)
        #expect(diagnosis.verdict == nil)

        let top = try #require(diagnosis.hypotheses.first)
        #expect(top.hypothesis.id == "abort-generic")
        #expect(top.band == .weak)
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "cxx-terminate" })
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "uncaught-objc-exception" })
    }

    // MARK: - Scoring unit tests

    private func fact(_ id: String) -> Fact {
        Fact(id: id, statement: id, sourcePath: id)
    }

    private func hypothesis(
        id: String, supporting: [WeightedFact], contradicting: [WeightedFact] = []
    ) -> Hypothesis {
        Hypothesis(
            id: id, title: id, explanation: id, category: "test",
            supporting: supporting, contradicting: contradicting, inspect: [], confirmFurtherBy: []
        )
    }

    @Test func scoreOnlyCountsFactsActuallyPresent() {
        let h = hypothesis(id: "h", supporting: [WeightedFact(factID: "present", weight: 3), WeightedFact(factID: "missing", weight: 5)])
        let score = DiagnosisEngine.score(h, presentFactIDs: ["present"])
        #expect(score == 3)
    }

    @Test func scoreSubtractsOnlyPresentContradictions() {
        let h = hypothesis(
            id: "h",
            supporting: [WeightedFact(factID: "a", weight: 4)],
            contradicting: [WeightedFact(factID: "b", weight: 2), WeightedFact(factID: "absent", weight: 10)]
        )
        let score = DiagnosisEngine.score(h, presentFactIDs: ["a", "b"])
        #expect(score == 2)
    }

    @Test func bandBoundaries() {
        #expect(DiagnosisEngine.band(for: 4) == .strong)
        #expect(DiagnosisEngine.band(for: 5) == .strong)
        #expect(DiagnosisEngine.band(for: 3) == .moderate)
        #expect(DiagnosisEngine.band(for: 2) == .moderate)
        #expect(DiagnosisEngine.band(for: 1) == .weak)
        #expect(DiagnosisEngine.band(for: 0) == .weak)
        #expect(DiagnosisEngine.band(for: -3) == .weak)
    }

    @Test func verdictRequiresStrongBandAndTwoPointMargin() {
        // Strong leader, but only 1 ahead of the runner-up -> inconclusive.
        let h1 = hypothesis(id: "leader", supporting: [WeightedFact(factID: "f1", weight: 4)])
        let h2 = hypothesis(id: "runnerup", supporting: [WeightedFact(factID: "f2", weight: 3)])
        let facts = [fact("f1"), fact("f2")]
        let diag = DiagnosisEngine.rank(hypotheses: [h1, h2], facts: facts)
        #expect(diag.status == .inconclusive)
        #expect(diag.verdict == nil)
    }

    @Test func verdictFiresWithStrongBandAndExactlyTwoPointMargin() {
        let h1 = hypothesis(id: "leader", supporting: [WeightedFact(factID: "f1", weight: 4)])
        let h2 = hypothesis(id: "runnerup", supporting: [WeightedFact(factID: "f2", weight: 2)])
        let facts = [fact("f1"), fact("f2")]
        let diag = DiagnosisEngine.rank(hypotheses: [h1, h2], facts: facts)
        #expect(diag.status == .verdict)
        #expect(diag.verdict?.id == "leader")
    }

    @Test func moderateBandLeaderNeverBecomesVerdictRegardlessOfMargin() {
        let h1 = hypothesis(id: "leader", supporting: [WeightedFact(factID: "f1", weight: 3)])
        let facts = [fact("f1")]
        let diag = DiagnosisEngine.rank(hypotheses: [h1], facts: facts)
        #expect(diag.status == .inconclusive)
        #expect(diag.verdict == nil)
        #expect(diag.hypotheses.first?.band == .moderate)
    }

    @Test func rankingIsStableSortScoreDescThenIDAsc() {
        // Three hypotheses tie at score 2; must come back sorted by id ascending.
        let hz = hypothesis(id: "zzz", supporting: [WeightedFact(factID: "f", weight: 2)])
        let ha = hypothesis(id: "aaa", supporting: [WeightedFact(factID: "f", weight: 2)])
        let hm = hypothesis(id: "mmm", supporting: [WeightedFact(factID: "f", weight: 2)])
        let facts = [fact("f")]
        let diag = DiagnosisEngine.rank(hypotheses: [hz, ha, hm], facts: facts)
        #expect(diag.hypotheses.map(\.hypothesis.id) == ["aaa", "mmm", "zzz"])
    }

    @Test func rankingSortsByScoreDescendingAcrossDifferentScores() {
        let low = hypothesis(id: "low", supporting: [WeightedFact(factID: "f", weight: 1)])
        let high = hypothesis(id: "high", supporting: [WeightedFact(factID: "f", weight: 5)])
        let mid = hypothesis(id: "mid", supporting: [WeightedFact(factID: "f", weight: 3)])
        let facts = [fact("f")]
        let diag = DiagnosisEngine.rank(hypotheses: [low, high, mid], facts: facts)
        #expect(diag.hypotheses.map(\.hypothesis.id) == ["high", "mid", "low"])
    }

    @Test func emptyHypothesesListIsInconclusive() {
        let diag = DiagnosisEngine.rank(hypotheses: [], facts: [])
        #expect(diag.status == .inconclusive)
        #expect(diag.verdict == nil)
        #expect(diag.hypotheses.isEmpty)
    }

    // MARK: - Codable round-trip (output contract sanity)

    @Test func diagnosisRoundTripsThroughJSON() throws {
        let file = try loadFixture("nsexcrash")
        let diagnosis = DiagnosisEngine().diagnose(file)

        let data = try JSONEncoder().encode(diagnosis)
        let decoded = try JSONDecoder().decode(Diagnosis.self, from: data)
        #expect(decoded == diagnosis)
    }
}
