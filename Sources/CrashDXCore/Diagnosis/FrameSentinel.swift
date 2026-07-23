import Foundation

/// Sentinel stack-frame symbols the diagnosis engine's Stage-1 extractors and Stage-2
/// rules key off (`docs/DESIGN.md`'s FrameFacts bullet). Centralized here so
/// extractor Facts and rule logic can never drift out of sync — both consult the same
/// symbol-matching predicate.
///
/// `FrameFactsExtractor` covers the design doc's full sentinel list, so a new rule can
/// usually be added without touching the extractor — `.assertionFailure` and
/// `.swiftRuntimeReport`, for example, are consumed by `SwiftFatalTrapRule`.
enum FrameSentinel: String, CaseIterable {
    case assertionFailure = "assertion-failure"
    case swiftRuntimeReport = "swift-runtime-report"
    case objcExceptionThrow = "objc-exception-throw"
    case exceptionPreprocess = "exception-preprocess"
    case cxaThrow = "cxa-throw"
    case terminateHandler = "terminate-handler"
    case abortChain = "abort-chain"
    case stackChkFail = "stack-chk-fail"
    case dispatchMarker = "dispatch-marker"

    /// Symbol substrings (case-sensitive; documented/observed mangled or demangled forms)
    /// that mark a frame as this sentinel.
    var matchSubstrings: [String] {
        switch self {
        case .assertionFailure:
            return ["_assertionFailure", "assertionFailure("]
        case .swiftRuntimeReport:
            return ["swift_runtime_report", "_swift_runtime_on_report"]
        case .objcExceptionThrow:
            return ["objc_exception_throw"]
        case .exceptionPreprocess:
            return ["__exceptionPreprocess"]
        case .cxaThrow:
            return ["__cxa_throw"]
        case .terminateHandler:
            // Apple's libobjc installs `_objc_terminate` as the process-wide C++ terminate
            // handler for ALL uncaught C++ exceptions (not only NSExceptions) because it
            // gives a more informative message — so this sentinel deliberately does NOT
            // imply an ObjC exception on its own. See `objcExceptionThrow` for that signal.
            return [
                "std::__terminate", "std::terminate", "__cxxabiv1::failed_throw",
                "demangling_terminate_handler", "_objc_terminate",
            ]
        case .abortChain:
            return ["abort", "__abort", "pthread_kill", "__pthread_kill"]
        case .stackChkFail:
            return ["__stack_chk_fail"]
        case .dispatchMarker:
            return ["_dispatch_", "dispatch_async", "dispatch_sync"]
        }
    }

    func matches(symbol: String) -> Bool {
        matchSubstrings.contains { symbol.contains($0) }
    }
}

/// Index of the first frame in `frames` matching `sentinel`, or `nil`.
func firstFrameIndex(matching sentinel: FrameSentinel, in frames: [StackFrame]) -> Int? {
    frames.firstIndex { frame in
        guard let symbol = frame.symbol else { return false }
        return sentinel.matches(symbol: symbol)
    }
}

/// The `usedImages` index that represents the crashing process's own binary: the image
/// whose `name` equals `procName`, falling back to index 0 (the conventional slot for the
/// main executable in every fixture and real report examined so far).
func appImageIndex(payload: CrashPayload) -> Int? {
    let images = payload.usedImages
    guard !images.isEmpty else { return nil }
    guard let procName = payload.procName else { return 0 }

    // Which images does the faulting thread actually stand in? An image the crash never
    // touches is useless as a "your code starts here" pointer — and picking one is how
    // this used to fail: a test host is listed under the bare process name (`Passport`)
    // while every app frame lives in `Passport.debug.dylib` / `PassportTests`, so an
    // exact-name match resolved to an image with no frames and `inspect` came back empty
    // for every SwiftPM app, framework-based app, and test bundle.
    var referenced = Set<Int>()
    if let threadIdx = payload.faultingThreadIndex, payload.threads.indices.contains(threadIdx) {
        for frame in payload.threads[threadIdx].frames {
            if let idx = frame.imageIndex { referenced.insert(idx) }
        }
    }

    // Candidates, best first: the executable itself, then images carrying the app's own
    // code under a related name, then anything inside the process's own bundle.
    var candidates: [Int] = []
    if let idx = images.firstIndex(where: { $0.name == procName }) { candidates.append(idx) }
    candidates += images.indices
        .filter { idx in
            guard let name = images[idx].name, name != procName else { return false }
            return name.hasPrefix(procName)
        }
        .sorted { (images[$0].name?.count ?? 0) < (images[$1].name?.count ?? 0) }
    if let procPath = payload.procPath,
       let bundleRoot = procPath.components(separatedBy: ".app/").first, !bundleRoot.isEmpty {
        candidates += images.indices.filter { ($0 < images.count) && (images[$0].path ?? "").hasPrefix(bundleRoot) }
    }

    // Prefer a candidate the faulting thread actually uses; otherwise keep the best-named
    // one so behaviour is unchanged for ordinary single-image apps.
    if let idx = candidates.first(where: { referenced.contains($0) }) { return idx }
    return candidates.first ?? 0
}


/// The "your code starts here" pointer for a frame list: the frame CLOSEST to the crash
/// point (lowest index — frame 0 is innermost) that belongs to the app's own image.
func deepestAppFrame(in frames: [StackFrame], appImageIndex: Int) -> (index: Int, frame: StackFrame)? {
    for (i, f) in frames.enumerated() where f.imageIndex == appImageIndex {
        return (i, f)
    }
    return nil
}

/// The first frame with index STRICTLY GREATER than `sentinelIndex` that belongs to
/// `appImageIndex` — used by rules whose pathognomonic evidence is a runtime-internal
/// sentinel frame (e.g. `_assertionFailure`) sitting closest to the fault: the actual
/// failing expression in the app's own code is the next app-owned frame walking OUTWARD
/// (increasing index / toward the caller) from that sentinel, not the sentinel itself.
func appFrame(after sentinelIndex: Int, in frames: [StackFrame], appImageIndex: Int) -> (index: Int, frame: StackFrame)? {
    guard sentinelIndex + 1 < frames.count else { return nil }
    for i in (sentinelIndex + 1)..<frames.count where frames[i].imageIndex == appImageIndex {
        return (i, frames[i])
    }
    return nil
}

/// The symbol/source info to trust for a `lastExceptionBacktrace` frame.
///
/// GROUND TRUTH: ReportCrash itself mis-symbolicates LEB frames — the same
/// image+offset can resolve to a different (wrong) symbol in the LEB than it does in the
/// faulting thread, with the LEB variant showing `symbolLocation == 0`. Rule: when a LEB
/// frame's image+offset matches a faulting-thread frame with a DIFFERENT symbol, trust the
/// thread frame's symbol; a `symbolLocation == 0` LEB symbol with no thread frame to
/// cross-check is marked `trustLow` (suspect) rather than silently accepted.
struct ResolvedFrameSymbol {
    let symbol: String?
    let sourceFile: String?
    let sourceLine: Int?
    let trustLow: Bool
}

func resolveLEBFrameSymbol(_ lebFrame: StackFrame, threadFrames: [StackFrame]) -> ResolvedFrameSymbol {
    if let imgIdx = lebFrame.imageIndex, let offset = lebFrame.imageOffset,
       let match = threadFrames.first(where: { $0.imageIndex == imgIdx && $0.imageOffset == offset }),
       match.symbol != lebFrame.symbol {
        return ResolvedFrameSymbol(
            symbol: match.symbol, sourceFile: match.sourceFile, sourceLine: match.sourceLine, trustLow: false
        )
    }
    let suspect = lebFrame.symbol != nil && lebFrame.symbolLocation == 0
    return ResolvedFrameSymbol(
        symbol: lebFrame.symbol, sourceFile: lebFrame.sourceFile, sourceLine: lebFrame.sourceLine, trustLow: suspect
    )
}

/// An `InspectionPoint` at the deepest app-image frame of the faulting thread (`leb ==
/// false`) or of `lastExceptionBacktrace` (`leb == true`), or `nil` if that frame list is
/// absent or has no app-owned frame. LEB lookups apply `resolveLEBFrameSymbol`'s
/// thread-symbol preference automatically.
func inspectionPointForDeepestAppFrame(in payload: CrashPayload, leb: Bool) -> InspectionPoint? {
    guard let appIdx = appImageIndex(payload: payload) else { return nil }

    if leb {
        guard let lebFrames = payload.lastExceptionBacktrace,
              let (idx, frame) = deepestAppFrame(in: lebFrames, appImageIndex: appIdx) else { return nil }
        let threadFrames = payload.faultingThread?.frames ?? []
        let resolved = resolveLEBFrameSymbol(frame, threadFrames: threadFrames)
        return InspectionPoint(
            frameIndex: idx, leb: true,
            symbol: resolved.symbol, sourceFile: resolved.sourceFile, sourceLine: resolved.sourceLine
        )
    } else {
        guard let threadIdx = payload.faultingThreadIndex, payload.threads.indices.contains(threadIdx) else { return nil }
        let frames = payload.threads[threadIdx].frames
        guard let (idx, frame) = deepestAppFrame(in: frames, appImageIndex: appIdx) else { return nil }
        return InspectionPoint(
            threadIndex: threadIdx, frameIndex: idx, leb: false,
            symbol: frame.symbol, sourceFile: frame.sourceFile, sourceLine: frame.sourceLine
        )
    }
}

/// JSON numbers may decode as Int, Int64, or NSNumber; some fields (e.g. `termination.code`
/// in the wild) may be strings. Mirrors `IPSFile.swift`'s private `intValue`, duplicated
/// here (rather than exposed) because that helper is `private` to its file.
func diagnosisIntValue(_ any: Any?) -> Int? {
    switch any {
    case let i as Int: return i
    case let n as NSNumber: return n.intValue
    case let s as String: return Int(s)
    default: return nil
    }
}
