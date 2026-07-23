import Foundation

/// A single piece of evidence extracted from a parsed `.ips` payload by an
/// `EvidenceExtractor`. Facts are the atomic, verifiable unit the diagnosis engine builds
/// hypotheses from — see `docs/DESIGN.md`'s Stage 1.
///
/// `id` is stable across runs of the same input (same extractor logic, same payload
/// shape) so `DiagnosisRule`s can cite it by name in a `Hypothesis`'s `supporting` /
/// `contradicting` lists, and so `DiagnosisEngine`'s scoring can look it up by identity.
/// It is deliberately NOT guaranteed globally unique across every conceivable input —
/// extractors emit at most one Fact per `id` for a given payload (v1 payloads carry a
/// single exception/termination/LEB, so this holds in practice).
public struct Fact: Codable, Equatable, Sendable {
    /// Stable identifier, e.g. `"termination.code"`, `"frames.sentinel.cxa-throw"`.
    public let id: String
    /// Human-readable, one-line description of what was observed.
    public let statement: String
    /// JSON-path-ish pointer into the raw `.ips` payload this Fact was read from, e.g.
    /// `"termination.reasons[0]"` or `"threads[0].frames[9]"`, so any consumer can verify
    /// it against the source file.
    public let sourcePath: String

    public init(id: String, statement: String, sourcePath: String) {
        self.id = id
        self.statement = statement
        self.sourcePath = sourcePath
    }
}
