import Foundation

/// Measures which extracted Facts a diagnosis actually rests on, by re-running Stages 2
/// and 3 with one Fact withheld at a time.
///
/// The question it answers is "if this single observation were absent or wrong, would the
/// verdict change?" That is not the same as the weight a rule assigns the Fact: a Fact
/// cited at weight 3 is not load-bearing if the hypothesis still clears `strong` and its
/// margin without it, and a Fact cited at weight 1 is load-bearing if it is the one
/// carrying a score from 3 to 4.
///
/// The ablation is a full re-run, not a score adjustment: rules are re-evaluated against
/// the reduced Fact list, so a Fact that gates a rule's `guard` shows up as removing the
/// hypothesis entirely. Rules that read `IPSFile` directly rather than through Facts (e.g.
/// `WatchdogTimeoutRule` reads the `termination` dict to decide whether to fire) keep
/// firing when their Facts are withheld — that asymmetry is real and worth seeing.
///
/// This is diagnostics for the engine itself, not part of the analyze pipeline; nothing in
/// `AnalyzePipeline` calls it.
struct DiagnosisAblation: Sendable {
    let engine: DiagnosisEngine

    init(engine: DiagnosisEngine = DiagnosisEngine()) {
        self.engine = engine
    }

    /// What withholding one Fact did to the diagnosis.
    struct FactImpact: Sendable {
        let fact: Fact
        let channel: EvidenceChannel
        /// Status the engine reached without this Fact.
        let ablatedStatus: Diagnosis.Status
        /// Verdict id without this Fact, `nil` when the ablated run was inconclusive.
        let ablatedVerdictID: String?
        /// Score the baseline's top hypothesis got without this Fact, or `nil` if that
        /// hypothesis stopped firing altogether.
        let ablatedScoreOfBaselineTop: Int?
        /// Baseline status/verdict differ from the ablated ones: this Fact is carrying the
        /// outcome.
        let changesOutcome: Bool
        /// The highest-ranked hypothesis changed identity, even if the status did not.
        let changesTopHypothesis: Bool
    }

    struct Result: Sendable {
        let scoring: DiagnosisEngine.Scoring
        let facts: [Fact]
        let baseline: Diagnosis
        let impacts: [FactImpact]

        var loadBearing: [FactImpact] { impacts.filter(\.changesOutcome) }

        /// The baseline reached a verdict that no single Fact removal disturbs.
        ///
        /// Over-determination is the signature the correlated-evidence concern predicts:
        /// a verdict resting on several renderings of one observation cannot be moved by
        /// dropping any one of them, so it looks maximally robust while actually resting
        /// on a single point of failure. It is not automatically a defect — genuinely
        /// independent corroboration produces the same shape — so read it together with
        /// the channel breakdown, which says whether the surviving support is independent.
        var isOverDetermined: Bool {
            baseline.status == .verdict && loadBearing.isEmpty
        }

        /// Distinct channels the baseline's top hypothesis draws present supporting Facts
        /// from. `1` means every piece of support came from one source artifact.
        var supportingChannelsOfTop: Set<EvidenceChannel> {
            guard let top = baseline.hypotheses.first?.hypothesis else { return [] }
            let byID = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return Set(top.supporting.compactMap { byID[$0.factID].map(EvidenceChannel.of) })
        }
    }

    func run(_ file: IPSFile) -> Result {
        let facts = engine.extractors.flatMap { $0.extract(from: file) }
        let baseline = diagnose(facts: facts, file: file)
        let baselineTopID = baseline.hypotheses.first?.hypothesis.id

        var impacts: [FactImpact] = []
        impacts.reserveCapacity(facts.count)

        for index in facts.indices {
            var reduced = facts
            reduced.remove(at: index)
            let ablated = diagnose(facts: reduced, file: file)

            let ablatedTopID = ablated.hypotheses.first?.hypothesis.id
            impacts.append(FactImpact(
                fact: facts[index],
                channel: EvidenceChannel.of(facts[index]),
                ablatedStatus: ablated.status,
                ablatedVerdictID: ablated.verdict?.id,
                ablatedScoreOfBaselineTop: baselineTopID.flatMap { id in
                    ablated.hypotheses.first { $0.hypothesis.id == id }?.score
                },
                changesOutcome: ablated.status != baseline.status || ablated.verdict?.id != baseline.verdict?.id,
                changesTopHypothesis: ablatedTopID != baselineTopID
            ))
        }

        return Result(scoring: engine.scoring, facts: facts, baseline: baseline, impacts: impacts)
    }

    private func diagnose(facts: [Fact], file: IPSFile) -> Diagnosis {
        let hypotheses = engine.rules.flatMap { $0.evaluate(facts: facts, file: file) }
        return DiagnosisEngine.rank(hypotheses: hypotheses, facts: facts, scoring: engine.scoring)
    }

    // MARK: - Scoring comparison

    /// One hypothesis scored both ways.
    struct ScoreRow: Sendable {
        let hypothesisID: String
        let additive: Int
        let capped: Int
        let additiveBand: RankedHypothesis.ConfidenceBand
        let cappedBand: RankedHypothesis.ConfidenceBand
        /// Channels the present supporting Facts came from. `1` with a `additive > capped`
        /// gap is the "one artifact, counted N times" signature.
        let supportingChannels: Int
    }

    struct ScoringComparison: Sendable {
        let additive: Diagnosis
        let capped: Diagnosis
        let rows: [ScoreRow]

        /// The two scorings disagree about the outcome, not merely about the numbers.
        var outcomeDiffers: Bool {
            additive.status != capped.status || additive.verdict?.id != capped.verdict?.id
        }
    }

    /// Runs one file under both scorings and pairs the results per hypothesis.
    static func compareScoring(
        file: IPSFile,
        extractors: [EvidenceExtractor] = DiagnosisEngine.defaultExtractors,
        rules: [DiagnosisRule] = DiagnosisEngine.defaultRules
    ) -> ScoringComparison {
        let facts = extractors.flatMap { $0.extract(from: file) }
        let hypotheses = rules.flatMap { $0.evaluate(facts: facts, file: file) }
        let additive = DiagnosisEngine.rank(hypotheses: hypotheses, facts: facts, scoring: .additive)
        let capped = DiagnosisEngine.rank(hypotheses: hypotheses, facts: facts, scoring: .channelCapped)

        let byID = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let cappedByID = Dictionary(capped.hypotheses.map { ($0.hypothesis.id, $0) }, uniquingKeysWith: { first, _ in first })

        let rows = additive.hypotheses.compactMap { additiveRanked -> ScoreRow? in
            guard let cappedRanked = cappedByID[additiveRanked.hypothesis.id] else { return nil }
            let channels = Set(additiveRanked.hypothesis.supporting.compactMap { byID[$0.factID].map(EvidenceChannel.of) })
            return ScoreRow(
                hypothesisID: additiveRanked.hypothesis.id,
                additive: additiveRanked.score,
                capped: cappedRanked.score,
                additiveBand: additiveRanked.band,
                cappedBand: cappedRanked.band,
                supportingChannels: channels.count
            )
        }

        return ScoringComparison(additive: additive, capped: capped, rows: rows)
    }
}

// MARK: - Plain-text reporting

extension DiagnosisAblation.Result {
    /// Human-readable ablation table. Intended for test output and manual inspection, not
    /// for machine consumption — nothing parses this.
    func renderReport(title: String) -> String {
        var out = "=== ablation: \(title) (scoring: \(scoring.rawValue))\n"
        let top = baseline.hypotheses.first
        out += "    baseline: \(baseline.status.rawValue)"
        if let top {
            out += " top=\(top.hypothesis.id) score=\(top.score) band=\(top.band.rawValue)"
        }
        let channels = supportingChannelsOfTop.map(\.rawValue).sorted().joined(separator: ",")
        out += "\n    facts=\(facts.count) load-bearing=\(loadBearing.count)"
        out += " top-support-channels=\(supportingChannelsOfTop.count)[\(channels)]"
        if isOverDetermined { out += " OVER-DETERMINED" }
        out += "\n"

        for impact in impacts where impact.changesOutcome || impact.changesTopHypothesis {
            let score = impact.ablatedScoreOfBaselineTop.map(String.init) ?? "gone"
            out += "      - drop \(impact.fact.id) [\(impact.channel.rawValue)]"
            out += " -> \(impact.ablatedStatus.rawValue)"
            out += " verdict=\(impact.ablatedVerdictID ?? "none") topScore=\(score)\n"
        }
        return out
    }
}

extension DiagnosisAblation.ScoringComparison {
    func renderReport(title: String) -> String {
        var out = "=== scoring: \(title)\n"
        out += "    additive: \(additive.status.rawValue) verdict=\(additive.verdict?.id ?? "none")\n"
        out += "    capped:   \(capped.status.rawValue) verdict=\(capped.verdict?.id ?? "none")"
        out += outcomeDiffers ? "   <- DIFFERS\n" : "\n"
        for row in rows {
            let marker = row.additive != row.capped ? "  *" : ""
            out += "      \(row.hypothesisID): \(row.additive)(\(row.additiveBand.rawValue))"
            out += " -> \(row.capped)(\(row.cappedBand.rawValue))"
            out += " channels=\(row.supportingChannels)\(marker)\n"
        }
        return out
    }
}
