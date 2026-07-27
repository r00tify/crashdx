import Foundation
import Testing
@testable import CrashDXCore

// Measures, rather than asserts, how the diagnosis engine's confidence is actually
// distributed across evidence — the two questions weights and thresholds can't answer by
// inspection:
//
//   1. Which Facts is a verdict really resting on? (`DiagnosisAblation`)
//   2. How much of a score comes from one source artifact rendered several ways?
//      (`EvidenceChannel` + `DiagnosisEngine.Scoring.channelCapped`)
//
// The expectations below pin the answers as of today so a weight edit that quietly moves
// a verdict onto a single artifact fails here. They are NOT a claim that the current
// numbers are calibrated: nothing in this repo establishes that `strong` means what it
// says, because every fixture with known ground truth is one the rules were written
// against.
//
// They are a record of the current state, not a specification. `docs/DESIGN.md`'s "What a
// real fix looks like" describes a re-derivation of the weight scale and bands that SHOULD
// fail these expectations; when it happens, re-measure and rewrite them deliberately
// rather than editing the arrays to make a build green.

private func fixtureURLs() throws -> [(name: String, url: URL)] {
    var found: [(String, URL)] = []
    for subdirectory in ["Fixtures", "Fixtures/synthetic"] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "ips", subdirectory: subdirectory) ?? []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            found.append((url.deletingPathExtension().lastPathComponent, url))
        }
    }
    #expect(found.count >= 14, "fixture discovery found only \(found.count) .ips files")
    return found
}

@Suite struct DiagnosisAblationTests {

    // MARK: - Channel classification

    @Test func everyExtractedFactClassifiesToAKnownChannel() throws {
        var unclassified: [String] = []
        for (_, url) in try fixtureURLs() {
            let file = try IPSFile.parse(contentsOf: url)
            for fact in DiagnosisEngine.defaultExtractors.flatMap({ $0.extract(from: file) })
            where EvidenceChannel.of(fact) == .other {
                unclassified.append("\(fact.id) <- \(fact.sourcePath)")
            }
        }
        // `.other` is the safety valve, not a resting place: a Fact landing there means an
        // extractor emitted a `sourcePath` whose root `EvidenceChannel.of` doesn't know,
        // and it will be scored uncapped.
        #expect(unclassified.isEmpty, "unclassified facts: \(Set(unclassified).sorted())")
    }

    @Test func extractedFactIDsAreUniquePerFile() throws {
        // A soundness precondition for the whole ablation harness, not just a tidiness
        // check. `DiagnosisEngine.score` tests presence via `Set(facts.map(\.id))`, so if
        // two Facts ever shared an id, withholding one would leave the id present and the
        // ablation would silently report the Fact as not load-bearing. `Fact`'s own doc
        // states extractors emit at most one Fact per id; this is that claim under test.
        for (name, url) in try fixtureURLs() {
            let file = try IPSFile.parse(contentsOf: url)
            let facts = DiagnosisEngine.defaultExtractors.flatMap { $0.extract(from: file) }
            let ids = facts.map(\.id)
            #expect(ids.count == Set(ids).count, "\(name) emitted duplicate fact ids: \(ids)")
        }
    }

    @Test func channelDerivesFromSourcePathRootNotFactID() {
        // The id prefix and the source artifact deliberately disagree here: the faulting
        // address is a `memory.*` fact parsed back out of the `exception` dict, so it
        // pools with `exception.type` rather than with vmregioninfo's observations.
        let address = Fact(id: "memory.fault-address", statement: "", sourcePath: "exception.subtype")
        #expect(EvidenceChannel.of(address) == .machException)

        let region = Fact(id: "memory.fault-address-in-vmregion-stack-guard", statement: "", sourcePath: "vmregioninfo")
        #expect(EvidenceChannel.of(region) == .vmRegion)

        // Same `threads` root, two independently written structures.
        let frame = Fact(id: "frames.sentinel.abort-chain", statement: "", sourcePath: "threads[0].frames[3]")
        #expect(EvidenceChannel.of(frame) == .threadFrames)
        let register = Fact(id: "registers.far", statement: "", sourcePath: "threads[0].threadState.far")
        #expect(EvidenceChannel.of(register) == .threadState)
    }

    @Test func nearStackFactReportsTheArtifactItWasActuallyReadFrom() throws {
        // `memory.fault-address-near-stack` fires from `vmregioninfo` naming a STACK GUARD
        // region, from the fault address sitting within a page of `sp`, or from both. The
        // stack-overflow fixture is the only one in the corpus that produces the Fact and
        // it hits BOTH branches, so the sp-only case — the one that used to be mislabelled
        // `sourcePath: "vmregioninfo"` — is unreachable from the fixtures as they stand.
        // Stripping `vmregioninfo` isolates it.
        //
        // This matters beyond the `sourcePath` contract: `EvidenceChannel` derives the
        // channel from the path, so the old label filed a thread-state observation under
        // `vm-region`, where it would have capped against genuine vmregioninfo evidence.
        let url = try #require(Bundle.module.url(
            forResource: "stack-overflow", withExtension: "ips", subdirectory: "Fixtures/synthetic"
        ))
        var data = try Data(contentsOf: url)
        let newline = try #require(data.firstIndex(of: UInt8(ascii: "\n")))
        let headerLine = data[data.startIndex...newline]
        var payload = try #require(
            try JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any]
        )
        payload.removeValue(forKey: "vmregioninfo")
        data = headerLine + (try JSONSerialization.data(withJSONObject: payload))
        let file = try IPSFile.parse(data: data)

        let facts = MemoryFactsExtractor().extract(from: file)
        let nearStack = try #require(facts.first { $0.id == "memory.fault-address-near-stack" })
        #expect(nearStack.sourcePath == "threads[0].threadState.sp")
        #expect(EvidenceChannel.of(nearStack) == .threadState)
        #expect(nearStack.statement.contains("within 500 bytes of sp"))
        #expect(!nearStack.statement.contains("STACK GUARD"))

        // Both-branch case keeps naming vmregioninfo: it is listed first and is the
        // stronger of the two observations.
        let both = try #require(
            MemoryFactsExtractor().extract(from: try IPSFile.parse(contentsOf: url))
                .first { $0.id == "memory.fault-address-near-stack" }
        )
        #expect(both.sourcePath == "vmregioninfo")
        #expect(EvidenceChannel.of(both) == .vmRegion)
    }

    @Test func unclassifiedFactsAreNotPooledWithEachOther() {
        // Two unknown-root facts must not cap each other: an unmapped Fact should lose no
        // weight, so each gets its own capping key.
        let a = Fact(id: "a", statement: "", sourcePath: "somethingNew.x")
        let b = Fact(id: "b", statement: "", sourcePath: "somethingElse.y")
        #expect(EvidenceChannel.of(a) == .other && EvidenceChannel.of(b) == .other)
        #expect(EvidenceChannel.cappingKey(for: a) != EvidenceChannel.cappingKey(for: b))

        let h = Hypothesis(
            id: "h", title: "", explanation: "", category: "",
            supporting: [WeightedFact(factID: "a", weight: 3), WeightedFact(factID: "b", weight: 2)],
            contradicting: [], inspect: [], confirmFurtherBy: []
        )
        #expect(DiagnosisEngine.score(h, facts: [a, b], scoring: .channelCapped) == 5)
    }

    // MARK: - Scoring mechanics

    @Test func channelCappedTakesTheMaxWithinAChannelOnBothSides() {
        let code = Fact(id: "termination.code", statement: "", sourcePath: "termination.code")
        let namespace = Fact(id: "termination.namespace", statement: "", sourcePath: "termination.namespace")
        let event = Fact(id: "termination.watchdog-event", statement: "", sourcePath: "termination.reasons[0]")
        let frame = Fact(id: "frames.sentinel.abort-chain", statement: "", sourcePath: "threads[0].frames[1]")

        // WatchdogTimeoutRule's exact citation shape: 3 + 1 + 2 from one `termination` dict.
        let watchdogShaped = Hypothesis(
            id: "h", title: "", explanation: "", category: "",
            supporting: [
                WeightedFact(factID: "termination.code", weight: 3),
                WeightedFact(factID: "termination.namespace", weight: 1),
                WeightedFact(factID: "termination.watchdog-event", weight: 2),
            ],
            contradicting: [], inspect: [], confirmFurtherBy: []
        )
        let facts = [code, namespace, event, frame]
        #expect(DiagnosisEngine.score(watchdogShaped, facts: facts, scoring: .additive) == 6)
        #expect(DiagnosisEngine.score(watchdogShaped, facts: facts, scoring: .channelCapped) == 3)

        // A second channel adds on top; it is capped, not discarded.
        let twoChannel = Hypothesis(
            id: "h", title: "", explanation: "", category: "",
            supporting: watchdogShaped.supporting + [WeightedFact(factID: "frames.sentinel.abort-chain", weight: 2)],
            contradicting: [], inspect: [], confirmFurtherBy: []
        )
        #expect(DiagnosisEngine.score(twoChannel, facts: facts, scoring: .channelCapped) == 5)

        // Contradiction is pooled the same way, or a rule could out-vote a capped support
        // stack by citing several renderings of one refutation.
        let contradicted = Hypothesis(
            id: "h", title: "", explanation: "", category: "",
            supporting: [WeightedFact(factID: "frames.sentinel.abort-chain", weight: 3)],
            contradicting: [
                WeightedFact(factID: "termination.code", weight: 2),
                WeightedFact(factID: "termination.namespace", weight: 2),
            ],
            inspect: [], confirmFurtherBy: []
        )
        #expect(DiagnosisEngine.score(contradicted, facts: facts, scoring: .additive) == -1)
        #expect(DiagnosisEngine.score(contradicted, facts: facts, scoring: .channelCapped) == 1)
    }

    @Test func aFactCitedTwiceCountsOnce() {
        // `supporting` is an array with no uniqueness constraint. No shipped rule
        // double-cites, but the failure would be a silent score inflation.
        let fact = Fact(id: "x", statement: "", sourcePath: "exception.type")
        let h = Hypothesis(
            id: "h", title: "", explanation: "", category: "",
            supporting: [WeightedFact(factID: "x", weight: 3), WeightedFact(factID: "x", weight: 3)],
            contradicting: [], inspect: [], confirmFurtherBy: []
        )
        #expect(DiagnosisEngine.score(h, presentFactIDs: ["x"]) == 3)
        #expect(DiagnosisEngine.score(h, facts: [fact], scoring: .channelCapped) == 3)
    }

    @Test func additiveScoringIsUnchangedForEveryFixture() throws {
        // The shipped default must not move: `Scoring.channelCapped` is opt-in.
        for (name, url) in try fixtureURLs() {
            let file = try IPSFile.parse(contentsOf: url)
            let viaEngine = DiagnosisEngine().diagnose(file)
            let comparison = DiagnosisAblation.compareScoring(file: file)
            #expect(viaEngine.status == comparison.additive.status, "\(name)")
            #expect(viaEngine.verdict?.id == comparison.additive.verdict?.id, "\(name)")
            #expect(viaEngine.hypotheses == comparison.additive.hypotheses, "\(name)")
        }
    }

    // MARK: - The corpus-wide picture

    @Test func ablationReportAcrossEveryFixture() throws {
        var report = ""
        var overDetermined: [String] = []
        var singleChannelVerdicts: [String] = []

        for (name, url) in try fixtureURLs() {
            let file = try IPSFile.parse(contentsOf: url)
            let result = DiagnosisAblation().run(file)
            report += result.renderReport(title: name)
            if result.isOverDetermined { overDetermined.append(name) }
            if result.baseline.status == .verdict, result.supportingChannelsOfTop.count == 1 {
                singleChannelVerdicts.append("\(name)=\(result.baseline.verdict?.id ?? "?")")
            }
        }

        report += "\nover-determined verdicts (no single fact moves them): \(overDetermined.sorted())\n"
        report += "verdicts resting on ONE source artifact: \(singleChannelVerdicts.sorted())\n"
        print(report)

        // Pinned: these verdicts draw every supporting Fact from a single artifact, so
        // whatever their score says, they rest on one observation. Adding to this list
        // means a rule started claiming `strong` off one artifact; removing from it means
        // a rule gained genuinely independent support. Both are worth a deliberate look.
        //
        // Two are termination-family (one `termination` dict rendered three ways); the
        // third is `cxx-terminate`, whose two weight-2 Facts are adjacent frames in one
        // unwind (`__cxa_throw` -> `std::terminate`) on one thread. Same shape, different
        // artifact — so this is not a quirk of the termination extractor.
        #expect(singleChannelVerdicts.sorted() == [
            "cxx-terminate-only=cxx-terminate",
            "dead10cc=background-task-overrun",
            "watchdog-scene-create=watchdog-timeout",
        ])

        // No verdict in the corpus survives every single-Fact removal. Worth re-checking
        // whenever a rule gains supporting Facts: over-determination is what a verdict
        // resting on redundant renderings of one observation looks like from the outside.
        #expect(overDetermined.isEmpty, "over-determined: \(overDetermined.sorted())")
    }

    // MARK: - Findings the corpus-wide sweep turned up, pinned individually

    @Test func nullDerefSmallOffsetDuplicateRegisterFactNoLongerCarriesTheVerdict() throws {
        // Previously `registers.far` was cited at weight 1 and was, on this fixture, the
        // Fact that produced the verdict: 3 (null page) + 1 (far) = 4 cleared `strong` by
        // exactly that one weight-1 fact — a residual cross-artifact correlation
        // `EvidenceChannel` deliberately does not model, since `far` lives in `threadState`
        // and the null-page Fact is parsed from `exception.subtype`, so channel capping
        // treated them as independent. But `RegisterFactsExtractor`'s own ground truth is
        // that `far.value` EQUALS the subtype address on every real EXC_BAD_ACCESS
        // examined: two artifacts, one number, and the verdict rested on reading it twice.
        //
        // Fixed by citing `registers.far` at weight 0 in `NullDereferenceRule` (see its doc
        // comment). This test now pins the opposite of what it used to: the duplicate Fact
        // is still cited (the corroboration is real, just not independent evidence), but
        // withholding it moves nothing, and the fixture honestly lands at `.inconclusive`
        // rather than a verdict propped up by a re-read number.
        let url = try #require(Bundle.module.url(
            forResource: "null-deref-small-offset", withExtension: "ips", subdirectory: "Fixtures/synthetic"
        ))
        let result = DiagnosisAblation().run(try IPSFile.parse(contentsOf: url))
        #expect(result.baseline.status == .inconclusive)
        #expect(result.baseline.hypotheses.first?.hypothesis.id == "null-dereference")
        #expect(result.baseline.hypotheses.first?.score == 3)

        let far = try #require(result.impacts.first { $0.fact.id == "registers.far" })
        #expect(!far.changesOutcome)
        #expect(far.ablatedScoreOfBaselineTop == 3)
        #expect(far.ablatedStatus == .inconclusive)

        // Channel capping agrees with additive now — there's no cross-channel duplicate
        // left for it to fail to catch.
        let comparison = DiagnosisAblation.compareScoring(file: try IPSFile.parse(contentsOf: url))
        #expect(comparison.capped.verdict == nil)
        #expect(comparison.rows.first?.capped == 3)
    }

    @Test func stackGuardContradictionIsNoLongerLoadBearingAfterTheFarFactFix() throws {
        // This used to demonstrate a dependency reading `supporting` alone can't show: on
        // stack-overflow, withholding the STACK GUARD vmregion Fact left the winning score
        // untouched at 5 but still lost the verdict, because the Fact is cited by
        // `NullDereferenceRule` as a weight-3 CONTRADICTION, and removing it lifted the
        // runner-up from 1 to 4, collapsing the >= 2 margin.
        //
        // Fixing `registers.far`'s cross-artifact duplicate (see NullDereferenceRule's doc)
        // incidentally closed this too: null-dereference's runner-up score without the
        // guard contradiction is now 3 (moderate), not 4 (strong) — the point `far` used to
        // contribute is gone — so the margin (5 - 3 = 2) holds on its own and the verdict
        // survives the ablation. The general mechanism this test named — a rule's
        // `contradicting` list can be load-bearing for another rule's margin — still holds
        // in principle; the corpus just has no live example of it left, which is itself
        // worth re-checking whenever weights or a new rule change the runner-up's score.
        let url = try #require(Bundle.module.url(
            forResource: "stack-overflow", withExtension: "ips", subdirectory: "Fixtures/synthetic"
        ))
        let result = DiagnosisAblation().run(try IPSFile.parse(contentsOf: url))
        #expect(result.baseline.verdict?.id == "stack-overflow")

        let guardFact = try #require(
            result.impacts.first { $0.fact.id == "memory.fault-address-in-vmregion-stack-guard" }
        )
        #expect(!guardFact.changesOutcome)
        #expect(guardFact.ablatedScoreOfBaselineTop == 5)  // winner's own score is unmoved
        #expect(guardFact.ablatedStatus == .verdict)
        #expect(guardFact.ablatedVerdictID == "stack-overflow")
        #expect(!guardFact.changesTopHypothesis)
    }

    @Test func scoringComparisonAcrossEveryFixture() throws {
        var report = ""
        var demoted: [String] = []

        for (name, url) in try fixtureURLs() {
            let file = try IPSFile.parse(contentsOf: url)
            let comparison = DiagnosisAblation.compareScoring(file: file)
            report += comparison.renderReport(title: name)
            if comparison.outcomeDiffers {
                demoted.append("\(name): \(comparison.additive.verdict?.id ?? "none") -> \(comparison.capped.verdict?.id ?? "none")")
            }
        }
        report += "\noutcome changes under channel capping: \(demoted.sorted())\n"
        print(report)

        // The measured cost of removing same-artifact double counting, pinned so the
        // trade-off stays visible. The corpus ships 8 verdicts today under `additive`, one
        // fewer than before `null-deref-small-offset`'s own `registers.far` duplicate was
        // fixed: that fixture no longer reaches `strong` under the shipped scoring at all,
        // so it isn't part of this 8 and can't appear in `demoted` below.
        //
        // Of those 8, channel capping demotes 4. Three demote because their support comes
        // from a single artifact (watchdog-timeout, background-task-overrun, cxx-terminate).
        // The fourth, null-dereference on the real `nullderef` fixture, is a different
        // shape: fixing NullDereferenceRule's cross-artifact `registers.far` duplicate (see
        // its doc comment) removed the one point that used to keep its capped score at the
        // `strong` floor, exposing that its `mach-exception` channel alone — `-null-page`
        // and `-exactly-null` pooled to their max of 3 — caps out one short. The remaining 4
        // verdicts survive, because the memory/frame/LEB rules genuinely combine artifacts
        // and lose only the redundant portion (uncaught-objc 5->4, swift-fatal-trap 6->5,
        // jetsam-memory-kill and stack-overflow unmoved at 5, all still `strong`).
        //
        // Whether these 4 SHOULD be demoted is a threshold question, not a scoring-
        // mechanics one: 0x8badf00d is pathognomonic, so is a fault address of exactly
        // zero, so a verdict off one such Fact is defensible, but `strong >= 4` cannot
        // express "one Fact is enough" while the weight convention caps a single Fact at 3.
        // Reconciling that means re-deriving the bands, which needs evidence this repo does
        // not have. Hence `additive` remains the default and this test records the gap
        // rather than closing it.
        #expect(demoted.sorted() == [
            "cxx-terminate-only: cxx-terminate -> none",
            "dead10cc: background-task-overrun -> none",
            "nullderef: null-dereference -> none",
            "watchdog-scene-create: watchdog-timeout -> none",
        ])
    }
}
