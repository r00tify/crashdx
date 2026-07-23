import Foundation

/// A `Fact` reference carrying the weight a `DiagnosisRule` assigns it toward (or away
/// from) a `Hypothesis` — see `docs/DESIGN.md`'s Stage 3. A struct rather than a tuple
/// because tuples aren't `Codable`.
///
/// Weight convention (Stage 3): 1 = weak corroboration, 2 = strong indicator,
/// 3 = pathognomonic (e.g. termination code 0x8badf00d for watchdog-timeout).
public struct WeightedFact: Codable, Equatable, Sendable {
    public let factID: String
    public let weight: Int

    public init(factID: String, weight: Int) {
        self.factID = factID
        self.weight = weight
    }
}

/// A pointer to a specific frame worth a human (or agent) looking at directly, cited by a
/// `Hypothesis`. Either `threadIndex` (a numbered thread) or `leb == true`
/// (`lastExceptionBacktrace`) identifies which frame list `frameIndex` indexes into.
public struct InspectionPoint: Codable, Equatable, Sendable {
    /// Index into `payload.threads`, when this point is not in the LEB.
    public let threadIndex: Int?
    /// Index into the identified frame list (thread frames or LEB frames).
    public let frameIndex: Int?
    /// `true` when this point is in `lastExceptionBacktrace` rather than a numbered thread.
    public let leb: Bool
    public let symbol: String?
    public let sourceFile: String?
    public let sourceLine: Int?

    public init(
        threadIndex: Int? = nil, frameIndex: Int? = nil, leb: Bool = false,
        symbol: String? = nil, sourceFile: String? = nil, sourceLine: Int? = nil
    ) {
        self.threadIndex = threadIndex
        self.frameIndex = frameIndex
        self.leb = leb
        self.symbol = symbol
        self.sourceFile = sourceFile
        self.sourceLine = sourceLine
    }
}

/// A candidate explanation for the crash, emitted by a `DiagnosisRule`. Per
/// `docs/DESIGN.md` Stage 2: rules never claim to be the sole answer — every
/// applicable rule fires, and `DiagnosisEngine` ranks the results in Stage 3. A
/// `Hypothesis` is honest about its own evidence: `supporting`/`contradicting` cite Facts
/// by id with a weight, and `confirmFurtherBy` lists what would settle the question when
/// the cited evidence alone isn't conclusive.
public struct Hypothesis: Codable, Equatable, Sendable {
    /// Stable identifier, e.g. `"watchdog-timeout"`. Matches the rule catalog id in
    /// `docs/DESIGN.md` unless a rule emits variants (documented on the rule).
    public let id: String
    public let title: String
    /// 2-5 sentences: the mechanism, not a narrative guess.
    public let explanation: String
    /// Coarse grouping, e.g. `"watchdog"`, `"memory"`, `"objc-exception"`.
    public let category: String
    /// Evidence FOR this hypothesis. Scoring counts a fact's weight only if that fact id
    /// is actually present in the engine's extracted facts for this input.
    public let supporting: [WeightedFact]
    /// Evidence AGAINST this hypothesis that the rule itself acknowledges (e.g. a
    /// competing sentinel frame). Same presence rule as `supporting`.
    public let contradicting: [WeightedFact]
    /// Frames worth looking at directly.
    public let inspect: [InspectionPoint]
    /// What would settle this hypothesis further, e.g. "reproduce with Zombies enabled".
    public let confirmFurtherBy: [String]

    public init(
        id: String, title: String, explanation: String, category: String,
        supporting: [WeightedFact], contradicting: [WeightedFact],
        inspect: [InspectionPoint], confirmFurtherBy: [String]
    ) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.category = category
        self.supporting = supporting
        self.contradicting = contradicting
        self.inspect = inspect
        self.confirmFurtherBy = confirmFurtherBy
    }
}
