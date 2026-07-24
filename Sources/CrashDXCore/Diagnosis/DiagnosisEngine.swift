import Foundation

/// A `Hypothesis` together with its Stage-3 score and confidence band. `docs/DESIGN.md`
/// describes `Diagnosis.hypotheses` as a ranked list but also requires "raw score
/// is kept in the JSON so consumers can re-rank" — since `Hypothesis` itself (id/title/
/// explanation/category/supporting/contradicting/inspect/confirmFurtherBy) carries no
/// score field, this wrapper is how that requirement is met without overloading
/// `Hypothesis`'s shape. Resolves an ambiguity between the two design doc passages.
public struct RankedHypothesis: Codable, Equatable, Sendable {
    public let hypothesis: Hypothesis
    /// `Σ support − Σ contradiction`, counting only facts actually present in
    /// `Diagnosis.factsConsidered`.
    public let score: Int
    public let band: ConfidenceBand

    public enum ConfidenceBand: String, Codable, Sendable {
        /// score ≥ 4
        case strong
        /// 2 ≤ score ≤ 3
        case moderate
        /// score ≤ 1
        case weak
    }

    public init(hypothesis: Hypothesis, score: Int, band: ConfidenceBand) {
        self.hypothesis = hypothesis
        self.score = score
        self.band = band
    }
}

/// Stage 3's output: the ranked, honest result of running the diagnosis engine on one
/// `.ips` file, carried by `AnalysisReport.diagnosis`. Per `docs/DESIGN.md`'s output
/// contract.
public struct Diagnosis: Codable, Equatable, Sendable {
    public let status: Status
    /// The winning hypothesis, present only when `status == .verdict`.
    public let verdict: Hypothesis?
    /// Every hypothesis any rule produced, ranked: score descending, then `id` ascending
    /// (deterministic — never dependent on rule registration order).
    public let hypotheses: [RankedHypothesis]
    /// Every Fact any extractor produced for this input.
    public let factsConsidered: [Fact]

    public enum Status: String, Codable, Sendable {
        case verdict
        case inconclusive
        /// Reserved for inputs the engine doesn't attempt to diagnose (e.g. non-crash
        /// `bug_type`s). No current rule produces this; kept for forward compatibility
        /// with the design doc's contract.
        case notApplicable = "not_applicable"
    }

    public init(status: Status, verdict: Hypothesis?, hypotheses: [RankedHypothesis], factsConsidered: [Fact]) {
        self.status = status
        self.verdict = verdict
        self.hypotheses = hypotheses
        self.factsConsidered = factsConsidered
    }
}

/// Runs Stage 1 (extraction) → Stage 2 (hypothesis generation) → Stage 3 (scoring,
/// ranking, verdict) per `docs/DESIGN.md`. Deterministic; no I/O, no LLM calls.
///
/// New crash patterns are added by appending rules (and, if needed, extractors) to the
/// default lists below — the engine itself does not change.
public struct DiagnosisEngine: Sendable {
    /// How Stage 3 combines a Hypothesis's cited Facts into a score.
    public enum Scoring: String, Codable, Sendable, CaseIterable {
        /// `Σ support − Σ contradiction`, every cited Fact counted independently. The
        /// shipped behaviour and the one `docs/DESIGN.md`'s bands are written against.
        case additive
        /// Facts are pooled by `EvidenceChannel` and only the highest-weighted Fact in
        /// each channel counts, on both sides: `Σ_channels max(support) − Σ_channels
        /// max(contradiction)`. Stops a single source artifact from supplying several
        /// renderings of one observation as if they were several observations — see
        /// `EvidenceChannel`.
        ///
        /// EXPERIMENTAL, not the default: the `>= 4 strong` / `+2 margin` thresholds were
        /// chosen against `additive` totals, so switching scoring without re-deriving
        /// them demotes rules that legitimately rest on one pathognomonic Fact. Measure
        /// with `DiagnosisAblation.compareScoring` before considering a default change.
        case channelCapped
    }

    public let extractors: [EvidenceExtractor]
    public let rules: [DiagnosisRule]
    public let scoring: Scoring

    public init(
        extractors: [EvidenceExtractor] = DiagnosisEngine.defaultExtractors,
        rules: [DiagnosisRule] = DiagnosisEngine.defaultRules,
        scoring: Scoring = .additive
    ) {
        self.extractors = extractors
        self.rules = rules
        self.scoring = scoring
    }

    public static let defaultExtractors: [EvidenceExtractor] = [
        ExceptionFactsExtractor(),
        TerminationFactsExtractor(),
        FrameFactsExtractor(),
        ASIFactsExtractor(),
        MemoryFactsExtractor(),
        RegisterFactsExtractor(),
    ]

    /// The termination/exception-family rules, plus the memory & Swift-runtime family:
    /// swift-fatal-trap, null-dereference, wild-or-uaf-address, stack-overflow.
    public static let defaultRules: [DiagnosisRule] = [
        WatchdogTimeoutRule(),
        BackgroundTaskOverrunRule(),
        JetsamMemoryKillRule(),
        SystemTerminationRule(),
        CxxTerminateRule(),
        UncaughtObjCExceptionRule(),
        SwiftFatalTrapRule(),
        NullDereferenceRule(),
        WildOrUAFAddressRule(),
        StackOverflowRule(),
        AbortGenericRule(),
    ]

    public func diagnose(_ file: IPSFile) -> Diagnosis {
        let facts = extractors.flatMap { $0.extract(from: file) }
        let hypotheses = rules.flatMap { $0.evaluate(facts: facts, file: file) }
        return Self.rank(hypotheses: hypotheses, facts: facts, scoring: scoring)
    }

    // MARK: - Stage 3

    /// Additive scoring against a bare set of present fact ids. Retained for callers that
    /// have no Facts to hand (channel capping needs `sourcePath`, so it needs the Facts
    /// themselves) — `score(_:facts:scoring:)` is the general entry point.
    static func score(_ hypothesis: Hypothesis, presentFactIDs: Set<String>) -> Int {
        let support = weigh(hypothesis.supporting, presentFactIDs: presentFactIDs)
        let contradiction = weigh(hypothesis.contradicting, presentFactIDs: presentFactIDs)
        return support - contradiction
    }

    static func score(_ hypothesis: Hypothesis, facts: [Fact], scoring: Scoring) -> Int {
        switch scoring {
        case .additive:
            return score(hypothesis, presentFactIDs: Set(facts.map(\.id)))
        case .channelCapped:
            let byID = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let support = weighCapped(hypothesis.supporting, factsByID: byID)
            let contradiction = weighCapped(hypothesis.contradicting, factsByID: byID)
            return support - contradiction
        }
    }

    /// Σ of the weights of cited Facts that are actually present.
    ///
    /// De-duplicates by fact id first: `supporting` is an array, so a rule that cited the
    /// same Fact twice would otherwise have it counted twice. No shipped rule does that,
    /// but nothing in the type prevents it and the failure would be silent.
    private static func weigh(_ cited: [WeightedFact], presentFactIDs: Set<String>) -> Int {
        var maxWeightByID: [String: Int] = [:]
        for ref in cited where presentFactIDs.contains(ref.factID) {
            maxWeightByID[ref.factID] = max(maxWeightByID[ref.factID] ?? ref.weight, ref.weight)
        }
        return maxWeightByID.values.reduce(0, +)
    }

    /// Σ over channels of the single highest weight cited from that channel.
    private static func weighCapped(_ cited: [WeightedFact], factsByID: [String: Fact]) -> Int {
        var maxWeightByChannel: [String: Int] = [:]
        for ref in cited {
            guard let fact = factsByID[ref.factID] else { continue }
            let key = EvidenceChannel.cappingKey(for: fact)
            maxWeightByChannel[key] = max(maxWeightByChannel[key] ?? ref.weight, ref.weight)
        }
        return maxWeightByChannel.values.reduce(0, +)
    }

    static func band(for score: Int) -> RankedHypothesis.ConfidenceBand {
        if score >= 4 { return .strong }
        if score >= 2 { return .moderate }
        return .weak
    }

    static func rank(hypotheses: [Hypothesis], facts: [Fact], scoring: Scoring = .additive) -> Diagnosis {
        let ranked = hypotheses
            .map { hyp -> RankedHypothesis in
                let s = score(hyp, facts: facts, scoring: scoring)
                return RankedHypothesis(hypothesis: hyp, score: s, band: band(for: s))
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.hypothesis.id < rhs.hypothesis.id
            }

        guard let top = ranked.first, top.band == .strong else {
            return Diagnosis(status: .inconclusive, verdict: nil, hypotheses: ranked, factsConsidered: facts)
        }
        // No runner-up (a single hypothesis fired) trivially satisfies "leads by >= 2" —
        // handled as its own case rather than substituting Int.min, which would overflow
        // `top.score - runnerUpScore` (Int subtraction from Int.min is undefined for any
        // top.score > 0).
        guard ranked.count > 1 else {
            return Diagnosis(status: .verdict, verdict: top.hypothesis, hypotheses: ranked, factsConsidered: facts)
        }
        if top.score - ranked[1].score >= 2 {
            return Diagnosis(status: .verdict, verdict: top.hypothesis, hypotheses: ranked, factsConsidered: facts)
        }
        return Diagnosis(status: .inconclusive, verdict: nil, hypotheses: ranked, factsConsidered: facts)
    }
}
