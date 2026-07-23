import Foundation

/// Sentinel frames (see `FrameSentinel`) on the faulting thread AND `lastExceptionBacktrace`,
/// plus each list's "deepest app-image frame" (the "your code starts here" pointer). Per
/// `docs/DESIGN.md`'s FrameFacts bullet — this is the sentinel-frame extractor only;
/// register/memory facts are the `MemoryFacts`/`RegisterFacts` extractors.
struct FrameFactsExtractor: EvidenceExtractor {
    init() {}

    func extract(from file: IPSFile) -> [Fact] {
        var facts: [Fact] = []
        let payload = file.payload

        guard let faultingIdx = payload.faultingThreadIndex, payload.threads.indices.contains(faultingIdx) else {
            return facts
        }
        let threadFrames = payload.threads[faultingIdx].frames

        for sentinel in FrameSentinel.allCases {
            guard let idx = firstFrameIndex(matching: sentinel, in: threadFrames) else { continue }
            let frame = threadFrames[idx]
            facts.append(Fact(
                id: "frames.sentinel.\(sentinel.rawValue)",
                statement: "Faulting thread frame \(idx) matches sentinel '\(sentinel.rawValue)': \(frame.symbol ?? "?")",
                sourcePath: "threads[\(faultingIdx)].frames[\(idx)]"
            ))
        }

        if let appIdx = appImageIndex(payload: payload), let (idx, frame) = deepestAppFrame(in: threadFrames, appImageIndex: appIdx) {
            facts.append(Fact(
                id: "frames.deepest-app-frame",
                statement: "Deepest app-image frame on faulting thread: \(frame.symbol ?? "<unsymbolicated>") (frame \(idx))",
                sourcePath: "threads[\(faultingIdx)].frames[\(idx)]"
            ))
        }

        // StackOverflowRule corroboration: the SAME non-nil symbol appears in >= 3
        // CONSECUTIVE frames on the faulting thread — a straight-line recursion signature.
        if let (idx, symbol, count) = Self.firstConsecutiveRepeat(in: threadFrames) {
            facts.append(Fact(
                id: "frames.recursion-pattern",
                statement: "Faulting thread has \(count) consecutive frames with identical symbol '\(symbol)' starting at frame \(idx) — a recursion signature",
                sourcePath: "threads[\(faultingIdx)].frames[\(idx)...\(idx + count - 1)]"
            ))
        }

        if let leb = payload.lastExceptionBacktrace, !leb.isEmpty {
            facts.append(Fact(
                id: "leb.present",
                statement: "lastExceptionBacktrace is present with \(leb.count) frame(s)",
                sourcePath: "lastExceptionBacktrace"
            ))

            for sentinel in FrameSentinel.allCases {
                guard let idx = firstFrameIndex(matching: sentinel, in: leb) else { continue }
                let frame = leb[idx]
                facts.append(Fact(
                    id: "leb.sentinel.\(sentinel.rawValue)",
                    statement: "lastExceptionBacktrace frame \(idx) matches sentinel '\(sentinel.rawValue)': \(frame.symbol ?? "?")",
                    sourcePath: "lastExceptionBacktrace[\(idx)]"
                ))
            }

            if let appIdx = appImageIndex(payload: payload), let (idx, frame) = deepestAppFrame(in: leb, appImageIndex: appIdx) {
                let resolved = resolveLEBFrameSymbol(frame, threadFrames: threadFrames)
                let label = resolved.symbol ?? "<unsymbolicated>"
                let suspectNote = resolved.trustLow ? " (symbolLocation==0, low trust)" : ""
                facts.append(Fact(
                    id: "leb.deepest-app-frame",
                    statement: "Deepest app-image frame in lastExceptionBacktrace: \(label)\(suspectNote) (frame \(idx))",
                    sourcePath: "lastExceptionBacktrace[\(idx)]"
                ))
            }
        }

        return facts
    }

    /// Index of the first frame that starts a run of >= 3 consecutive frames sharing the
    /// same non-nil `symbol`, that symbol, and the run length — or `nil` if no such run
    /// exists.
    /// Symbolication placeholders that are NOT function names. Repeats of these mean the
    /// opposite of recursion: `<deduplicated_symbol>` is the linker folding several
    /// distinct functions onto one address, so three in a row is three DIFFERENT
    /// functions. Before this exclusion, 9 of the 20 real reports in the corpus carried a
    /// false "recursion signature" — and that fact is the +1 that lifts stack-overflow
    /// from moderate into strong, so the false positive was load-bearing.
    static let nonSymbolPlaceholders: Set<String> = [
        "<deduplicated_symbol>", "<redacted>", "<unknown>", "<compiler-generated>",
    ]

    private static func firstConsecutiveRepeat(in frames: [StackFrame]) -> (index: Int, symbol: String, count: Int)? {
        guard frames.count >= 3 else { return nil }
        var i = 0
        while i <= frames.count - 3 {
            guard let symbol = frames[i].symbol,
                  !Self.nonSymbolPlaceholders.contains(symbol),
                  frames[i + 1].symbol == symbol, frames[i + 2].symbol == symbol else {
                i += 1
                continue
            }
            var count = 3
            while i + count < frames.count, frames[i + count].symbol == symbol {
                count += 1
            }
            return (i, symbol, count)
        }
        return nil
    }
}
