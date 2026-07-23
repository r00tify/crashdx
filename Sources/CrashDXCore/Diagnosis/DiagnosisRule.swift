import Foundation

/// Stage 2 of the diagnosis engine: consumes the Facts extracted from a file (plus the
/// file itself, for lookups that aren't worth fact-izing, like locating exact frame
/// content) and emits zero or more `Hypothesis` values.
///
/// **No first-match-wins.** `DiagnosisEngine` runs every registered rule against every
/// input; a rule that finds no applicable evidence simply returns `[]`. Ranking among
/// however many hypotheses fire happens once, centrally, in Stage 3 — individual rules
/// never need to know about (or rank against) each other.
public protocol DiagnosisRule: Sendable {
    func evaluate(facts: [Fact], file: IPSFile) -> [Hypothesis]
}
