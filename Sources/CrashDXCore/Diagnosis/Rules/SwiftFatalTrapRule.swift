import Foundation

/// `swift-fatal-trap`: the Swift runtime detected a fatal condition — a force-unwrapped
/// nil `Optional`, a failed `precondition`/`assert`, an explicit `fatalError()`, an
/// out-of-bounds/overflow check — and called `_assertionFailure`/`swift_runtime_report`,
/// which traps (`llvm.trap`), surfacing as `EXC_BREAKPOINT`/`SIGTRAP`. Distinct from
/// `abort()`-based paths (SIGABRT): the Swift runtime's fatal-trap family never calls
/// `abort()` on Apple platforms.
///
/// GROUND TRUTH (crashspike-stripped, real fixture): carries NO `asi` at all
/// (`payload.asiRaw == nil`) — this rule reaches a strong, verdict-worthy score from the
/// exception-type + sentinel-frame evidence alone; `asi` text (when present) only refines
/// the explanation's subclassification, it is never required to fire.
struct SwiftFatalTrapRule: DiagnosisRule {
    init() {}

    /// `codes[0] == 1` accompanies a deliberate `brk` trap on arm64 — as opposed to a
    /// hardware breakpoint or a debugger interrupt.
    static func isDeliberateBreakpointTrap(_ payload: CrashPayload) -> Bool {
        guard let raw = payload.exception?["rawCodes"] as? [Any], let first = raw.first else { return false }
        return diagnosisIntValue(first) == 1
    }

    /// Deliberately `moderate`, never a verdict on its own: this says "something trapped
    /// on purpose", which is true and useful, without naming a cause it cannot see.
    private func inlineTrapHypothesis(facts: [Fact], payload: CrashPayload) -> Hypothesis {
        var supporting: [WeightedFact] = []
        if let f = facts.first(where: { $0.id == "exception.type" }) {
            supporting.append(WeightedFact(factID: f.id, weight: 2))
        }
        if let f = facts.first(where: { $0.id == "exception.codes" }) {
            supporting.append(WeightedFact(factID: f.id, weight: 1))
        }
        return Hypothesis(
            id: "swift-runtime-trap-no-sentinel",
            title: "Deliberate runtime trap (no runtime frame visible)",
            explanation: """
            The process took EXC_BREAKPOINT/SIGTRAP with exception code 1 — a `brk` \
            instruction, i.e. something trapped ON PURPOSE rather than faulting. No Swift \
            runtime frame (_assertionFailure / swift_runtime_report) is visible, which \
            happens in two common ways: an inline trap emitted directly into your own \
            frame (arithmetic overflow, some bounds checks), or runtime frames that did \
            not symbolicate. The faulting frame is therefore the trap site itself rather \
            than a runtime helper. This is deliberately not a confident verdict — it says \
            a trap happened, not which check failed.
            """,
            category: "swift-runtime",
            supporting: supporting,
            contradicting: [],
            inspect: inspectionPointForDeepestAppFrame(in: payload, leb: false).map { [$0] } ?? [],
            confirmFurtherBy: [
                "Symbolicate with the matching dSYM — the runtime frame is often just unsymbolicated",
                "Check the failing expression at the faulting frame for arithmetic overflow or an index",
            ]
        )
    }

    func evaluate(facts: [Fact], file: IPSFile) -> [Hypothesis] {
        let payload = file.payload
        guard payload.exceptionType == "EXC_BREAKPOINT", payload.exceptionSignal == "SIGTRAP" else { return [] }

        let assertionFact = facts.first { $0.id == "frames.sentinel.assertion-failure" }
        let runtimeReportFact = facts.first { $0.id == "frames.sentinel.swift-runtime-report" }

        // No runtime sentinel is NOT the same as no information. Integer-overflow and some
        // bounds checks emit `brk #1` inline in the user's own frame with no runtime call,
        // and stripped or unsymbolicated runtime frames look identical. That shape covers
        // 9 of the 10 real EXC_BREAKPOINT reports in the corpus, every one of which used
        // to come back "no rule matched this crash" — the single largest recall gap in the
        // tool. `codes[0] == 1` on arm64 is a deliberate `brk`, which is real evidence.
        if assertionFact == nil && runtimeReportFact == nil {
            guard Self.isDeliberateBreakpointTrap(payload) else { return [] }
            return [inlineTrapHypothesis(facts: facts, payload: payload)]
        }

        var supporting: [WeightedFact] = []
        if let f = facts.first(where: { $0.id == "exception.type" }) {
            supporting.append(WeightedFact(factID: f.id, weight: 2))
        }
        if let f = facts.first(where: { $0.id == "exception.signal" }) {
            supporting.append(WeightedFact(factID: f.id, weight: 1))
        }
        if let assertionFact { supporting.append(WeightedFact(factID: assertionFact.id, weight: 3)) }
        if let runtimeReportFact { supporting.append(WeightedFact(factID: runtimeReportFact.id, weight: 2)) }

        // Contradicted by an ObjC exception throw on the same thread — an EXC_BREAKPOINT
        // Swift trap and an uncaught NSException are mutually exclusive causes for the same
        // faulting thread; if both sentinels somehow appear, this rule should not dominate.
        var contradicting: [WeightedFact] = []
        if let objcFact = facts.first(where: { $0.id == "frames.sentinel.objc-exception-throw" }) {
            contradicting.append(WeightedFact(factID: objcFact.id, weight: 3))
        }

        // Frame-based subclassification FIRST. `asi` is null in every one of the ten real
        // EXC_BREAKPOINT reports in the corpus, so an asi-only path never fires on macOS —
        // meanwhile libswiftCore names the exact check right there in the backtrace, and a
        // force-unwrap and an out-of-bounds index have different fixes.
        let frameSymbols = (payload.faultingThreadIndex.flatMap { idx -> [String] in
            guard payload.threads.indices.contains(idx) else { return [] }
            return payload.threads[idx].frames.compactMap(\.symbol)
        } ?? []).joined(separator: " ")

        let frameSubclass: String?
        if frameSymbols.contains("_diagnoseUnexpectedNilOptional") {
            frameSubclass = " The runtime frames name the specific check: force-unwrapping an Optional that was nil."
        } else if frameSymbols.contains("_checkSubscript") || frameSymbols.contains("_checkIndex") {
            frameSubclass = " The runtime frames name the specific check: an out-of-bounds collection index."
        } else if frameSymbols.contains("swift_unexpectedError") {
            frameSubclass = " The runtime frames indicate an error thrown through `try!`."
        } else if frameSymbols.contains("_precondition") || frameSymbols.contains("preconditionFailure") {
            frameSubclass = " The runtime frames name a failed precondition()/preconditionFailure()."
        } else if frameSymbols.contains("_fatalErrorMessage") || frameSymbols.contains("fatalError") {
            frameSubclass = " The runtime frames name an explicit fatalError()."
        } else if frameSymbols.contains("_assertionFailure") && frameSymbols.contains("Range") {
            frameSubclass = " The runtime frames indicate a range/slice violation."
        } else {
            frameSubclass = nil
        }

        let messages = payload.asiMessages.joined(separator: " ")
        let subclass: String
        if let frameSubclass {
            subclass = frameSubclass
        } else if messages.contains("Unexpectedly found nil") {
            subclass = " The asi text confirms the specific case: force-unwrapping an Optional that was nil."
        } else if messages.range(of: "index.*out of range", options: [.regularExpression, .caseInsensitive]) != nil {
            subclass = " The asi text indicates an out-of-bounds index/subscript access."
        } else if messages.contains("Fatal error:") {
            subclass = " The asi text carries a specific 'Fatal error:' message — see the cited asi fact for the exact wording."
        } else if messages.localizedCaseInsensitiveContains("precondition failed") {
            subclass = " The asi text indicates a failed precondition()/preconditionFailure() check."
        } else {
            subclass = " No asi text was available to further subclassify the exact trap kind (force-unwrap vs fatalError vs precondition/assert) — inspect the app frame immediately above the trap sentinel for the failing expression."
        }
        if let asiFact = facts.first(where: { $0.id == "asi.messages-present" }) {
            supporting.append(WeightedFact(factID: asiFact.id, weight: 1))
        }

        var inspect: [InspectionPoint] = []
        if let p = inspectionPointForDeepestAppFrame(in: payload, leb: false) {
            inspect.append(p)
        }
        if let threadIdx = payload.faultingThreadIndex, payload.threads.indices.contains(threadIdx),
           let appIdx = appImageIndex(payload: payload) {
            let frames = payload.threads[threadIdx].frames
            let sentinelIdx = firstFrameIndex(matching: .assertionFailure, in: frames)
                ?? firstFrameIndex(matching: .swiftRuntimeReport, in: frames)
            if let sentinelIdx, let (idx, frame) = appFrame(after: sentinelIdx, in: frames, appImageIndex: appIdx),
               !inspect.contains(where: { $0.threadIndex == threadIdx && $0.frameIndex == idx && $0.leb == false }) {
                inspect.append(InspectionPoint(
                    threadIndex: threadIdx, frameIndex: idx, leb: false,
                    symbol: frame.symbol, sourceFile: frame.sourceFile, sourceLine: frame.sourceLine
                ))
            }
        }

        let explanation = """
        The faulting thread shows an _assertionFailure/swift_runtime_report frame at (or immediately \
        below) the crash point, and the process received EXC_BREAKPOINT/SIGTRAP — the Swift \
        runtime's fatal-trap signature (llvm.trap), not an abort()-based path. This family covers a \
        force-unwrapped nil Optional, a failed precondition()/assert(), an explicit fatalError(), or \
        a runtime-checked overflow/bounds violation.\(subclass)
        """

        return [Hypothesis(
            id: "swift-fatal-trap",
            title: "Swift runtime fatal trap",
            explanation: explanation,
            category: "swift-runtime",
            supporting: supporting,
            contradicting: contradicting,
            inspect: inspect,
            confirmFurtherBy: [
                "Inspect the app frame directly above the trap sentinel for the failing expression",
                "Check the asi/console log for the exact 'Fatal error: ...' message, if available",
            ]
        )]
    }
}
