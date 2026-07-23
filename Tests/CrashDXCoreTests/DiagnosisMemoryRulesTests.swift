import Foundation
import Testing
@testable import CrashDXCore

// Ground truth this suite depends on (verified by direct inspection before writing
// these tests — see MemoryFactsExtractor.swift/RegisterFactsExtractor.swift doc comments
// and corpus/README.md's "fixtures/nullderef/" section for the full empirical record):
//
// - corpus/fixtures/nullderef/nullderef.ips is a REAL crash (`unsafeBitCast`-constructed
//   null `UnsafeMutablePointer<Int>`, dereferenced): `exception.subtype` ==
//   "KERN_INVALID_ADDRESS at 0x0000000000000000", `far.value == 0`, `vmregioninfo` ==
//   "0 is not in any region. ..." (note: NO "0x" prefix for address 0 specifically, unlike
//   every other address rendering observed — `exception.subtype` always keeps the "0x"
//   prefix regardless).
// - `threadState` register values (`far`/`pc`/`lr`/`sp`/`fp`) are `{"value": N}` with N
//   DECIMAL (verified against corpus/raw/contactsd-* and corpus/fixtures/nullderef).
// - crashspike-stripped.ips (real fixture, EXC_BREAKPOINT/SIGTRAP force-unwrap)
//   carries NO `asi` at all (`payload.asiRaw == nil`) — swift-fatal-trap must reach a
//   strong verdict from exception+sentinel evidence alone.
// - Synthetic fixtures under Fixtures/synthetic/ (null-deref-small-offset, wild-address,
//   stack-overflow) are built by transplanting nullderef.ips's real payload shape (frames,
//   threadState, usedImages) with `exception`/`vmregioninfo`/`threadState` fields mutated
//   to the documented-but-unobserved scenarios (small-offset null, a freed/wild region, a
//   guard-page-adjacent address) — see the generation notes inline below each fixture's
//   test group. `stack-overflow.ips` deliberately uses a fault address that is BOTH
//   null-page (< 0x4000) AND adjacent to `sp`, to exercise CONTRIBUTING.md's prefer-a-contradicting-fact
//   rule that stack-overflow and null-dereference may co-fire as competing
//   hypotheses on a guard-page address.

private func fixtureURL(_ name: String, subdirectory: String = "Fixtures") throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "ips", subdirectory: subdirectory))
}

private func loadFixture(_ name: String, subdirectory: String = "Fixtures") throws -> IPSFile {
    try IPSFile.parse(contentsOf: fixtureURL(name, subdirectory: subdirectory))
}

/// Parses a fixture and applies `mutate` to its JSON payload before re-parsing — mirrors
/// `DiagnosisEngineTests.mutatedCrashspike`, generalized to any base fixture, for exercising
/// a payload shape (e.g. a freed vmregioninfo region) we don't have a standalone file for.
private func mutatedFixture(_ name: String, subdirectory: String, _ mutate: (inout [String: Any]) -> Void) throws -> IPSFile {
    var data = try Data(contentsOf: fixtureURL(name, subdirectory: subdirectory))
    let newline = try #require(data.firstIndex(of: UInt8(ascii: "\n")))
    let headerLine = data[data.startIndex...newline]
    var payload = try #require(
        try JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any]
    )
    mutate(&payload)
    data = headerLine + (try JSONSerialization.data(withJSONObject: payload))
    return try IPSFile.parse(data: data)
}

@Suite struct DiagnosisMemoryRulesTests {

    // MARK: - swift-fatal-trap

    @Test func swiftFatalTrapFiresOnRealCrashspikeFixture() throws {
        let file = try loadFixture("crashspike-stripped")
        #expect(file.payload.asiRaw == nil) // ground truth: no asi at all on this fixture

        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(diagnosis.status == .verdict)
        #expect(diagnosis.verdict?.id == "swift-fatal-trap")

        let ranked = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "swift-fatal-trap" })
        #expect(ranked.band == .strong)
        // Reached strong purely from exception + sentinel evidence, no asi corroboration.
        #expect(ranked.hypothesis.explanation.contains("No asi text was available"))
    }

    @Test func swiftFatalTrapDoesNotFireOnMemoryCrash() throws {
        let file = try loadFixture("nullderef")
        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "swift-fatal-trap" })
    }

    @Test func swiftFatalTrapDoesNotFireOnNsexcrashRegression() throws {
        // Regression: nsexcrash (real, EXC_CRASH/SIGABRT uncaught NSException)
        // must still resolve to uncaught-objc-exception — swift-fatal-trap requires
        // EXC_BREAKPOINT/SIGTRAP, which nsexcrash never has.
        let file = try loadFixture("nsexcrash")
        let diagnosis = DiagnosisEngine().diagnose(file)

        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "swift-fatal-trap" })
        #expect(diagnosis.status == .verdict)
        #expect(diagnosis.verdict?.id == "uncaught-objc-exception")
    }

    // MARK: - null-dereference

    @Test func nullDereferenceFiresOnRealNullderefFixtureExactlyNullBranch() throws {
        let file = try loadFixture("nullderef")
        let diagnosis = DiagnosisEngine().diagnose(file)

        #expect(diagnosis.status == .verdict)
        #expect(diagnosis.verdict?.id == "null-dereference")

        let ranked = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "null-dereference" })
        #expect(ranked.band == .strong)
        #expect(ranked.hypothesis.explanation.contains("true nil-pointer dereference"))
        // registers.far corroboration: far == 0 == the parsed fault address on this real fixture.
        #expect(ranked.hypothesis.supporting.contains { $0.factID == "registers.far" })
        #expect(diagnosis.factsConsidered.contains { $0.id == "memory.fault-address-exactly-null" })
    }

    @Test func nullDereferenceFiresOnSyntheticSmallOffsetBranch() throws {
        let file = try loadFixture("null-deref-small-offset", subdirectory: "Fixtures/synthetic")
        let diagnosis = DiagnosisEngine().diagnose(file)

        #expect(diagnosis.verdict?.id == "null-dereference")
        let ranked = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "null-dereference" })
        #expect(ranked.band == .strong)
        #expect(ranked.hypothesis.explanation.contains("FIELD"))
        #expect(!ranked.hypothesis.explanation.contains("true nil-pointer dereference"))
        #expect(!diagnosis.factsConsidered.contains { $0.id == "memory.fault-address-exactly-null" })
    }

    @Test func nullDereferenceDoesNotFireOnUnrelatedCrash() throws {
        let file = try loadFixture("crashspike-stripped")
        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "null-dereference" })
    }

    @Test func nullDereferenceDoesNotFireOnNonNullPageAddress() throws {
        // Mutual exclusivity with wild-or-uaf-address (see CONTRIBUTING.md: prefer a contradicting fact over suppression).
        let file = try loadFixture("wild-address", subdirectory: "Fixtures/synthetic")
        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "null-dereference" })
    }

    // MARK: - wild-or-uaf-address

    @Test func wildOrUafFiresModerateWithoutRegionInfo() throws {
        // wild-address.ips: far = 0x00000001deadbeef, vmregioninfo says "not in any
        // region" (no positive freed-region fact) — must be capped below strong.
        let file = try loadFixture("wild-address", subdirectory: "Fixtures/synthetic")
        let diagnosis = DiagnosisEngine().diagnose(file)

        let ranked = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "wild-or-uaf-address" })
        #expect(ranked.score <= 3)
        #expect(ranked.band == .moderate)
        // Never strong without a positive freed-region fact -> never a confident verdict.
        #expect(diagnosis.status == .inconclusive)
    }

    @Test func wildOrUafFiresStrongWithPositiveFreedRegionFact() throws {
        let file = try mutatedFixture("wild-address", subdirectory: "Fixtures/synthetic") { payload in
            payload["vmregioninfo"] = "0x1deadbeef is in a 4K region.  Bytes into region: 0\n"
                + "      REGION TYPE                    START - END         [ VSIZE] PRT/MAX SHRMOD  REGION DETAIL\n"
                + "      MALLOC_TINY (freed)          1deadb000-1deadc000    [   4K] rw-/rwx SM=PRV  "
        }
        let diagnosis = DiagnosisEngine().diagnose(file)

        #expect(diagnosis.factsConsidered.contains { $0.id == "memory.fault-address-in-vmregion-malloc-tiny-freed" })
        let ranked = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "wild-or-uaf-address" })
        #expect(ranked.band == .strong)
        #expect(diagnosis.verdict?.id == "wild-or-uaf-address")
    }

    @Test func wildOrUafDoesNotFireOnNullPageAddress() throws {
        // Mutual exclusivity: null-dereference's null-page fact rules this rule out via its
        // own guard (a same-thread null-page fact is also declared as contradicting evidence
        // as defense-in-depth).
        let file = try loadFixture("nullderef")
        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(diagnosis.hypotheses.contains { $0.hypothesis.id == "null-dereference" })
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "wild-or-uaf-address" })
    }

    @Test func wildOrUafDoesNotFireOnUnrelatedCrash() throws {
        let file = try loadFixture("crashspike-stripped")
        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "wild-or-uaf-address" })
    }

    // MARK: - stack-overflow

    @Test func stackOverflowFiresStrongWithRecursionPattern() throws {
        let file = try loadFixture("stack-overflow", subdirectory: "Fixtures/synthetic")
        let diagnosis = DiagnosisEngine().diagnose(file)

        #expect(diagnosis.factsConsidered.contains { $0.id == "frames.recursion-pattern" })
        let ranked = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "stack-overflow" })
        #expect(ranked.band == .strong)
        #expect(ranked.hypothesis.explanation.contains("VICTIMS"))
        #expect(ranked.hypothesis.explanation.contains("recurse(_:)"))
    }

    /// Regression: this fixture's guard-page address is also numerically inside the null
    /// page, so `null-dereference` co-fires (deliberately — see `StackOverflowRule`'s
    /// doc). It must NOT win: a STACK GUARD region hit is a direct kernel observation and
    /// is cited at weight 3 AGAINST null-dereference, so the engine reports competing
    /// hypotheses led by stack-overflow rather than a confident null-dereference verdict.
    /// Asserting on the VERDICT, not merely that the rule fired, is the point of this test.
    @Test func stackGuardRegionPreventsConfidentNullDereferenceVerdict() throws {
        let file = try loadFixture("stack-overflow", subdirectory: "Fixtures/synthetic")
        let diagnosis = DiagnosisEngine().diagnose(file)

        #expect(diagnosis.factsConsidered.contains { $0.id == "memory.fault-address-in-vmregion-stack-guard" })

        // Both hypotheses are present, and neither is suppressed.
        let stackOverflow = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "stack-overflow" })
        let nullDeref = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "null-dereference" })

        // The contradiction is cited explicitly, not applied silently.
        #expect(nullDeref.hypothesis.contradicting.contains {
            $0.factID == "memory.fault-address-in-vmregion-stack-guard" && $0.weight == 3
        })

        #expect(stackOverflow.score > nullDeref.score)
        // Originally this asserted `.inconclusive` — the best outcome achievable when
        // null-dereference had a floor of 5 and stack-overflow a ceiling of 4. With the
        // weights counting independent observations rather than restatements of one
        // address, the correct answer is now reachable, so assert the correct answer.
        #expect(diagnosis.status == .verdict)
        #expect(diagnosis.verdict?.id == "stack-overflow")
        #expect(diagnosis.hypotheses.first?.hypothesis.id == "stack-overflow")
    }

    /// The contradiction must be scoped to the stack-guard case only — a genuine null
    /// dereference with no STACK GUARD region keeps its confident verdict.
    @Test func genuineNullDereferenceKeepsVerdictDespiteContradictionRule() throws {
        let file = try loadFixture("nullderef")
        let diagnosis = DiagnosisEngine().diagnose(file)

        let nullDeref = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "null-dereference" })
        #expect(nullDeref.hypothesis.contradicting.isEmpty)
        #expect(diagnosis.status == .verdict)
        #expect(diagnosis.verdict?.id == "null-dereference")
    }

    @Test func stackOverflowIsOnlyModerateWithoutRecursionPattern() throws {
        let file = try mutatedFixture("stack-overflow", subdirectory: "Fixtures/synthetic") { payload in
            let ft = payload["faultingThread"] as! Int
            var threads = payload["threads"] as! [[String: Any]]
            // Flatten to distinct symbols so no >= 3-consecutive-identical run remains.
            threads[ft]["frames"] = [
                ["imageIndex": 0, "imageOffset": 100, "symbol": "alpha()"],
                ["imageIndex": 0, "imageOffset": 200, "symbol": "beta()"],
                ["imageIndex": 0, "imageOffset": 300, "symbol": "gamma()"],
            ]
            payload["threads"] = threads
        }
        let diagnosis = DiagnosisEngine().diagnose(file)

        #expect(!diagnosis.factsConsidered.contains { $0.id == "frames.recursion-pattern" })
        let ranked = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "stack-overflow" })
        #expect(ranked.band == .moderate)
        #expect(ranked.hypothesis.explanation.contains("No repeated-symbol recursion pattern"))
    }

    @Test func stackOverflowDoesNotFireWithoutNearStackFact() throws {
        let file = try loadFixture("null-deref-small-offset", subdirectory: "Fixtures/synthetic")
        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "stack-overflow" })
    }

    @Test func stackOverflowDoesNotFireOnUnrelatedCrash() throws {
        let file = try loadFixture("crashspike-stripped")
        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(!diagnosis.hypotheses.contains { $0.hypothesis.id == "stack-overflow" })
    }

    // MARK: - Rule interplay: competing hypotheses on a guard-page (null-ish) address

    @Test func stackOverflowAndNullDereferenceBothRankOnGuardPageAddress() throws {
        // stack-overflow.ips's fault address (0x3000) is deliberately BOTH < 0x4000
        // (null-page) AND within 500 bytes of sp (near-stack) — per docs/DESIGN.md's
        // explicit stance, this must surface BOTH hypotheses, ranked deterministically by
        // score, never silently suppressing one in favor of the other.
        let file = try loadFixture("stack-overflow", subdirectory: "Fixtures/synthetic")
        let diagnosis = DiagnosisEngine().diagnose(file)

        let ids = diagnosis.hypotheses.map(\.hypothesis.id)
        #expect(ids.contains("null-dereference"))
        #expect(ids.contains("stack-overflow"))

        let byID = Dictionary(uniqueKeysWithValues: diagnosis.hypotheses.map { ($0.hypothesis.id, $0) })
        let nullDerefRanked = try #require(byID["null-dereference"])
        let stackOverflowRanked = try #require(byID["stack-overflow"])
        #expect(stackOverflowRanked.band == .strong)
        // Demoted to .weak: vmregioninfo names a STACK GUARD region at this address,
        // cited at weight 3 against null-dereference, and the rule no longer counts its
        // own guard condition or a restatement of the address as extra support. See
        // `stackGuardRegionPreventsConfidentNullDereferenceVerdict` for the verdict-level
        // assertion this ranking exists to support.
        #expect(nullDerefRanked.band == .weak)

        // Deterministic: the strictly higher-scoring hypothesis ranks first. The kernel's
        // direct statement about what the faulting address IS (a stack guard page)
        // outweighs the null-page inference drawn from the address value alone.
        #expect(stackOverflowRanked.score > nullDerefRanked.score)
        let nullDerefIdx = try #require(ids.firstIndex(of: "null-dereference"))
        let stackOverflowIdx = try #require(ids.firstIndex(of: "stack-overflow"))
        #expect(stackOverflowIdx < nullDerefIdx)

        // Re-running produces byte-identical ranking — confirms determinism, not luck.
        let secondRun = DiagnosisEngine().diagnose(file)
        #expect(secondRun.hypotheses.map(\.hypothesis.id) == ids)
    }

    // MARK: - MemoryFactsExtractor / RegisterFactsExtractor extractor-level coverage

    @Test func memoryFactsExtractorSkipsExceptionTypesThatArentMemoryRelevant() throws {
        // crashspike-stripped is EXC_BREAKPOINT; its exception.codes second value is a trap
        // PC, not a memory address — must not be misreported as one.
        let file = try loadFixture("crashspike-stripped")
        let facts = MemoryFactsExtractor().extract(from: file)
        #expect(facts.isEmpty)
    }

    @Test func registerFactsExtractorEmitsFarPcLrForRealFaultingThread() throws {
        let file = try loadFixture("nullderef")
        let facts = RegisterFactsExtractor().extract(from: file)
        let ids = Set(facts.map(\.id))
        #expect(ids == ["registers.far", "registers.pc", "registers.lr"])
        #expect(facts.first { $0.id == "registers.far" }?.statement.contains("0x0") == true)
    }
}
