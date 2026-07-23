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
    public let extractors: [EvidenceExtractor]
    public let rules: [DiagnosisRule]

    public init(extractors: [EvidenceExtractor] = DiagnosisEngine.defaultExtractors, rules: [DiagnosisRule] = DiagnosisEngine.defaultRules) {
        self.extractors = extractors
        self.rules = rules
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
        return Self.rank(hypotheses: hypotheses, facts: facts)
    }

    // MARK: - Stage 3

    static func score(_ hypothesis: Hypothesis, presentFactIDs: Set<String>) -> Int {
        let support = hypothesis.supporting
            .filter { presentFactIDs.contains($0.factID) }
            .reduce(0) { $0 + $1.weight }
        let contradiction = hypothesis.contradicting
            .filter { presentFactIDs.contains($0.factID) }
            .reduce(0) { $0 + $1.weight }
        return support - contradiction
    }

    static func band(for score: Int) -> RankedHypothesis.ConfidenceBand {
        if score >= 4 { return .strong }
        if score >= 2 { return .moderate }
        return .weak
    }

    static func rank(hypotheses: [Hypothesis], facts: [Fact]) -> Diagnosis {
        let presentFactIDs = Set(facts.map(\.id))

        let ranked = hypotheses
            .map { hyp -> RankedHypothesis in
                let s = score(hyp, presentFactIDs: presentFactIDs)
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
