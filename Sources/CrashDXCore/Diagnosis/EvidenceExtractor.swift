import Foundation

/// Stage 1 of the diagnosis engine: pulls typed `Fact`s out of a parsed `.ips` file. See
/// `docs/DESIGN.md`. Every extractor is independent and total — it never throws, and
/// returns an empty array when the payload carries none of the evidence it looks for.
public protocol EvidenceExtractor: Sendable {
    func extract(from file: IPSFile) -> [Fact]
}

/// Mach exception type/signal/subtype/codes.
struct ExceptionFactsExtractor: EvidenceExtractor {
    init() {}

    func extract(from file: IPSFile) -> [Fact] {
        var facts: [Fact] = []
        let payload = file.payload

        if let type = payload.exceptionType {
            facts.append(Fact(id: "exception.type", statement: "Exception type: \(type)", sourcePath: "exception.type"))
        }
        if let signal = payload.exceptionSignal {
            facts.append(Fact(id: "exception.signal", statement: "Signal: \(signal)", sourcePath: "exception.signal"))
        }
        if let subtype = payload.exception?["subtype"] as? String {
            facts.append(Fact(id: "exception.subtype", statement: "Exception subtype: \(subtype)", sourcePath: "exception.subtype"))
        }
        if let codes = payload.exception?["codes"] as? String {
            facts.append(Fact(id: "exception.codes", statement: "Exception codes: \(codes)", sourcePath: "exception.codes"))
        }
        return facts
    }
}

/// `termination` namespace/code/indicator, plus numbers mined from reason/detail text:
/// watchdog event kind + allowance seconds, jetsam per-process-limit vs system-wide
/// pressure indicators.
struct TerminationFactsExtractor: EvidenceExtractor {
    init() {}

    func extract(from file: IPSFile) -> [Fact] {
        var facts: [Fact] = []
        guard let termination = file.payload.termination else { return facts }

        if let namespace = termination["namespace"] as? String {
            facts.append(Fact(id: "termination.namespace", statement: "Termination namespace: \(namespace)", sourcePath: "termination.namespace"))
        }
        if let code = diagnosisIntValue(termination["code"]) {
            let hex = code >= 0 ? String(format: "0x%08x", code) : "n/a"
            facts.append(Fact(id: "termination.code", statement: "Termination code: \(code) (\(hex))", sourcePath: "termination.code"))
        }
        if let indicator = termination["indicator"] as? String {
            facts.append(Fact(id: "termination.indicator", statement: "Termination indicator: \(indicator)", sourcePath: "termination.indicator"))
        }

        let reasonTexts = Self.reasonTexts(from: termination)
        if !reasonTexts.isEmpty {
            let joined = reasonTexts.map(\.text).joined(separator: " | ")
            facts.append(Fact(id: "termination.reason-text", statement: joined, sourcePath: reasonTexts[0].path))
        }

        // Every string that could carry the freeform Apple-documented reason text: the
        // reasons/details arrays, and the indicator itself (some real reports put the
        // jetsam/watchdog keyword there instead of in a separate array).
        var candidates = reasonTexts
        if let indicator = termination["indicator"] as? String {
            candidates.append((indicator, "termination.indicator"))
        }

        if let watchdog = candidates.compactMap({ pair in Self.watchdogMatch(in: pair.text).map { (($0, pair.path)) } }).first {
            let (match, path) = watchdog
            let secondsText = match.seconds.map { String(format: "%.2fs", $0) } ?? "unknown"
            facts.append(Fact(
                id: "termination.watchdog-event",
                statement: "Watchdog event: \(match.kind), allowance \(secondsText)",
                sourcePath: path
            ))
        }

        for (text, path) in candidates {
            let lower = text.lowercased()
            if lower.contains("per-process-limit"), !facts.contains(where: { $0.id == "termination.jetsam-per-process-limit" }) {
                facts.append(Fact(id: "termination.jetsam-per-process-limit", statement: "Jetsam per-process-limit indicator: \(text)", sourcePath: path))
            }
            if (lower.contains("vm-pageshortage") || lower.contains("highwater")),
               !facts.contains(where: { $0.id == "termination.jetsam-system-pressure" }) {
                facts.append(Fact(id: "termination.jetsam-system-pressure", statement: "Jetsam system-wide pressure indicator: \(text)", sourcePath: path))
            }
        }

        return facts
    }

    private static func reasonTexts(from termination: [String: Any]) -> [(text: String, path: String)] {
        var results: [(text: String, path: String)] = []
        for key in ["reasons", "details"] {
            if let arr = termination[key] as? [String] {
                for (i, s) in arr.enumerated() {
                    results.append((s, "termination.\(key)[\(i)]"))
                }
            }
        }
        return results
    }

    private static let watchdogRegex = try! NSRegularExpression(
        pattern: #"([\w-]+) watchdog transgression:.*?allowance of ([\d.]+) seconds"#
    )

    static func watchdogMatch(in text: String) -> (kind: String, seconds: Double?)? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let m = watchdogRegex.firstMatch(in: text, range: range), m.numberOfRanges == 3,
           let kindRange = Range(m.range(at: 1), in: text) {
            let kind = String(text[kindRange])
            var seconds: Double?
            if let secRange = Range(m.range(at: 2), in: text) {
                seconds = Double(text[secRange])
            }
            return (kind, seconds)
        }
        if text.lowercased().contains("watchdog transgression") {
            return ("unknown", nil)
        }
        return nil
    }
}

/// Application Specific Information: whether any `asi` messages exist, and the parsed
/// uncaught-NSException name/reason when present.
///
/// GROUND TRUTH: plain CLI/Foundation processes never carry the classic "Terminating
/// app due to uncaught exception" message in `asi` — its absence is not evidence against
/// an uncaught-NSException hypothesis, so this extractor never emits an "absence" Fact for
/// it; consuming rules must not treat a missing `asi.uncaught-exception-text` fact as
/// contradicting.
struct ASIFactsExtractor: EvidenceExtractor {
    init() {}

    func extract(from file: IPSFile) -> [Fact] {
        var facts: [Fact] = []
        let payload = file.payload
        guard payload.asiRaw != nil else { return facts }

        if !payload.asiMessages.isEmpty {
            facts.append(Fact(
                id: "asi.messages-present",
                statement: "asi carries \(payload.asiMessages.count) message(s)",
                sourcePath: "asi"
            ))
        }
        if let name = payload.uncaughtExceptionName {
            let reason = payload.uncaughtExceptionReason ?? ""
            facts.append(Fact(
                id: "asi.uncaught-exception-text",
                statement: "asi carries an uncaught-exception message: '\(name)', reason: '\(reason)'",
                sourcePath: "asi"
            ))
        }
        return facts
    }
}
