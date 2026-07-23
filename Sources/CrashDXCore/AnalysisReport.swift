import Foundation

/// crashdx's versioned, structured-JSON output contract: the stable public API surface
/// consumed by agents and other tooling (as opposed to the human-readable CLI summary,
/// which may change freely between releases).
///
/// Every optional field is genuinely optional Codable — `nil` values are omitted from
/// the encoded JSON (standard `JSONEncoder` behavior), which is what keeps the
/// `.summary` tier lean. Nothing here is ever fabricated: fields reflect only what the
/// `.ips` file and (optionally) a completed symbolication pass actually established.
/// When something couldn't be resolved, that is represented explicitly (e.g.
/// `SymbolicationInfo.ImageStatus.outcome == .noDSYM`) rather than by silent omission.
///
/// Bump `schemaVersion` (and keep old-version decoders/fixtures around) for any breaking
/// change to field names, types, or semantics. Purely additive optional fields may ship
/// under the same minor version.
/// Decodes a `String`-backed enum, falling back to a designated case instead of throwing
/// on a value it doesn't recognise.
///
/// Without this, one unrecognised field destroys the ENTIRE report for a consumer: a
/// future crashdx adding a symbolication outcome would make every deployed decoder throw
/// `dataCorrupted` and lose the verdict, the hypotheses, everything — over a field they
/// may never read. That would also mean crashdx could never add an outcome or a tier
/// without breaking every consumer, so this must be settled before 1.0.
protocol LenientDecodableEnum: RawRepresentable, Codable where RawValue == String {
    static var unrecognisedFallback: Self { get }
}

extension LenientDecodableEnum {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.unrecognisedFallback
    }
}

public struct AnalysisReport: Codable, Sendable {
    /// The schema version this type currently encodes/decodes. Independent of the crashdx
    /// executable's own version (see `main.swift`'s `--version`).
    ///
    /// `"0.2"` is the first published schema: a `diagnosis` object carrying the verdict,
    /// ranked hypotheses, and tier-gated facts. Its vocabulary — including the full set of
    /// `SymbolicationInfo.ImageStatus.Outcome` values — is defined by the 0.1.0 release,
    /// not by any earlier unpublished revision, so no bump is owed for values added before
    /// that release. Adding an outcome value AFTER it is a breaking change for strict
    /// decoders and does require a bump.
    public static let currentSchemaVersion = "0.2"

    public let schemaVersion: String
    public let tier: Tier

    public let process: ProcessInfo
    public let event: EventInfo

    /// The thread that triggered the crash, when the report identifies one. Frame count
    /// is capped in `.summary` tier (see `ThreadDump.truncatedFrameCount`); uncapped in
    /// `.standard`/`.full`.
    public let faultingThread: ThreadDump?

    /// The synthetic Objective-C/`NSException` throw-site backtrace, when present in the
    /// input. **Never dropped or truncated at any tier** when the source `.ips` carries
    /// one — this is often the only place the true throw site survives (see
    /// `IPSFile.swift`'s `CrashPayload.lastExceptionBacktrace` doc comment), so omitting
    /// or capping it here would silently defeat crashdx's core promise.
    public let lastExceptionBacktrace: [FrameDump]?

    /// Threads other than the faulting one. `nil` in `.summary` (kept out entirely to stay
    /// lean); in `.standard`, only threads with at least one frame in the process's own
    /// binary (see the heuristic note on `build(from:symbolication:tier:)`); in `.full`,
    /// every thread.
    public let otherThreads: [ThreadDump]?

    /// Every `asi` message, flattened and sorted (see `CrashPayload.asiMessages`). `nil`
    /// when the input carries no `asi` section at all, rather than an empty array.
    public let asiMessages: [String]?

    /// Binary images referenced by any frame actually included in this report (faulting
    /// thread + other threads + last-exception backtrace), each with a coarse
    /// symbolicated/unsymbolicated status — independent of whether crashdx itself ran
    /// symbolication (system images are frequently pre-symbolicated by ReportCrash).
    /// Note the status is computed over EVERY frame in the payload, not only the frames
    /// this tier includes, so at `.standard` an image can read `symbolicated` while the
    /// frames actually shown for it carry no symbol. `nil` in `.summary`. For
    /// engine-level detail (which dSYM was or wasn't found, per-image failure reasons),
    /// see `symbolication`.
    public let images: [ImageDump]?

    /// Present whenever a `Symbolicator` pass actually ran (regardless of tier — this is
    /// small and central to "what was/wasn't resolved", so it's not tier-gated). `nil`
    /// when `analyze`/`build` was never given a `Symbolicator.Output` (e.g. zero dSYMs
    /// were located, so symbolication was skipped entirely).
    public let symbolication: SymbolicationInfo?

    /// The `DiagnosisEngine`'s ranked, evidence-cited verdict (or honest inconclusive) for
    /// this incident — see `docs/DESIGN.md`'s "Output contract". Always
    /// present, at every tier: when `build` isn't given a `Diagnosis` (the engine wasn't
    /// run), this is a `DiagnosisDump` with `status == .notApplicable` and empty lists
    /// rather than being omitted, so consumers never need to special-case its absence.
    public let diagnosis: DiagnosisDump

    public enum Tier: String, Codable, Sendable, LenientDecodableEnum {
        case summary, standard, full
        /// A tier this build doesn't know. Decoding widens rather than fails, so a report
        /// from a newer crashdx still yields its verdict.
        case unrecognised = "unrecognised"
        static var unrecognisedFallback: Tier { .unrecognised }
    }

    // MARK: - Process / event

    public struct ProcessInfo: Codable, Sendable {
        public let name: String?
        public let bundleID: String?
        public let osVersion: String?
        public let captureTime: String?

        public init(name: String?, bundleID: String?, osVersion: String?, captureTime: String?) {
            self.name = name
            self.bundleID = bundleID
            self.osVersion = osVersion
            self.captureTime = captureTime
        }
    }

    public struct EventInfo: Codable, Sendable {
        /// Documented values: "309" (crash, incl. user faults), "288" (stackshot). See
        /// `IPSHeader.bugType`.
        public let bugType: String?
        public let exceptionType: String?
        public let signal: String?
        public let terminationNamespace: String?
        public let terminationIndicator: String?
        /// From the `*** Terminating app due to uncaught exception 'NAME', reason:
        /// 'REASON'` pattern, when present in `asi`. Commonly `nil` even for genuine
        /// uncaught-exception crashes on plain CLI/Foundation processes — see
        /// `CrashPayload.uncaughtExceptionName`'s doc comment. `nil` here is expected,
        /// not a parsing failure.
        public let uncaughtExceptionName: String?
        public let uncaughtExceptionReason: String?

        public init(
            bugType: String?, exceptionType: String?, signal: String?,
            terminationNamespace: String?, terminationIndicator: String?,
            uncaughtExceptionName: String?, uncaughtExceptionReason: String?
        ) {
            self.bugType = bugType
            self.exceptionType = exceptionType
            self.signal = signal
            self.terminationNamespace = terminationNamespace
            self.terminationIndicator = terminationIndicator
            self.uncaughtExceptionName = uncaughtExceptionName
            self.uncaughtExceptionReason = uncaughtExceptionReason
        }
    }

    // MARK: - Frames / threads

    public struct FrameDump: Codable, Sendable {
        public let imageName: String?
        public let symbol: String?
        public let sourceFile: String?
        public let sourceLine: Int?
        public let imageOffset: Int?

        public init(imageName: String?, symbol: String?, sourceFile: String?, sourceLine: Int?, imageOffset: Int?) {
            self.imageName = imageName
            self.symbol = symbol
            self.sourceFile = sourceFile
            self.sourceLine = sourceLine
            self.imageOffset = imageOffset
        }
    }

    public struct ThreadDump: Codable, Sendable {
        public let index: Int
        public let queue: String?
        public let triggered: Bool
        public let frames: [FrameDump]
        /// Number of frames dropped from the END of `frames` to satisfy the `.summary`
        /// tier's 15-frame cap on the faulting thread. `nil` whenever no truncation
        /// happened (including for every non-`.summary` tier, and for any thread other
        /// than the faulting one, which is never capped).
        public let truncatedFrameCount: Int?

        public init(index: Int, queue: String?, triggered: Bool, frames: [FrameDump], truncatedFrameCount: Int?) {
            self.index = index
            self.queue = queue
            self.triggered = triggered
            self.frames = frames
            self.truncatedFrameCount = truncatedFrameCount
        }
    }

    // MARK: - Images

    public struct ImageDump: Codable, Sendable {
        public let name: String?
        public let uuid: String?
        public let path: String?
        public let arch: String?
        public let status: Status

        public enum Status: String, Codable, Sendable, LenientDecodableEnum {
            case symbolicated
            case unsymbolicated
            /// A status this build doesn't know — a newer crashdx added one. Decoding
            /// widens rather than throwing away the whole report.
            case unrecognised
            static var unrecognisedFallback: Status { .unrecognised }
        }

        public init(name: String?, uuid: String?, path: String?, arch: String?, status: Status) {
            self.name = name
            self.uuid = uuid
            self.path = path
            self.arch = arch
            self.status = status
        }
    }

    // MARK: - Symbolication

    public struct SymbolicationInfo: Codable, Sendable {
        public let engine: EngineName
        public let images: [ImageStatus]

        public enum EngineName: String, Codable, Sendable {
            case crashSymbolicator
            case atos
        }

        public struct ImageStatus: Codable, Sendable {
            public let imageName: String
            public let uuid: String?
            public let outcome: Outcome
            /// Present for `.failed` (why it failed) and `.uuidMismatch` (which dSYM
            /// was rejected); `nil` otherwise.
            public let reason: String?

            public enum Outcome: String, Codable, Sendable, LenientDecodableEnum {
                case symbolicated
                case noDSYM = "no_dsym"
                /// An outcome this build doesn't know — a newer crashdx added one.
                case unrecognised
                static var unrecognisedFallback: Outcome { .unrecognised }
                /// A dSYM was found for this image but belongs to a different build. Kept
                /// distinct from `no_dsym`: the remedy is "find the matching archive",
                /// not "go find a dSYM". `reason` lists the mismatched candidate paths.
                case uuidMismatch = "uuid_mismatch"
                case failed
            }

            public init(imageName: String, uuid: String?, outcome: Outcome, reason: String?) {
                self.imageName = imageName
                self.uuid = uuid
                self.outcome = outcome
                self.reason = reason
            }
        }

        public init(engine: EngineName, images: [ImageStatus]) {
            self.engine = engine
            self.images = images
        }
    }

    // MARK: - Diagnosis

    /// A tier-shaped view of `Diagnosis` (declared in `DiagnosisEngine.swift`).
    /// Mirrors `Diagnosis`'s fields exactly EXCEPT `factsConsidered`, which becomes
    /// `Optional` here so it can be omitted entirely at `.summary` tier (standard
    /// `JSONEncoder` behavior for `nil` Optionals — see this file's header doc) instead of
    /// requiring a hand-rolled `encode(to:)`/`CodingKeys` trick to hide it conditionally.
    /// `verdict` and `hypotheses` are never tier-gated: every tier gets the full ranked
    /// picture, per `docs/DESIGN.md`'s output contract.
    public struct DiagnosisDump: Codable, Sendable {
        public let status: Diagnosis.Status
        /// The winning hypothesis, present only when `status == .verdict`.
        public let verdict: Hypothesis?
        /// Every hypothesis any rule produced, ranked — present at every tier.
        public let hypotheses: [RankedHypothesis]
        /// Every `Fact` any extractor produced. `nil` (omitted from JSON) at `.summary`;
        /// present (possibly empty, e.g. when there was no `Diagnosis` to draw from) at
        /// `.standard`/`.full`.
        public let factsConsidered: [Fact]?

        public init(status: Diagnosis.Status, verdict: Hypothesis?, hypotheses: [RankedHypothesis], factsConsidered: [Fact]?) {
            self.status = status
            self.verdict = verdict
            self.hypotheses = hypotheses
            self.factsConsidered = factsConsidered
        }
    }

    public init(
        schemaVersion: String, tier: Tier, process: ProcessInfo, event: EventInfo,
        faultingThread: ThreadDump?, lastExceptionBacktrace: [FrameDump]?,
        otherThreads: [ThreadDump]?, asiMessages: [String]?, images: [ImageDump]?,
        symbolication: SymbolicationInfo?, diagnosis: DiagnosisDump
    ) {
        self.schemaVersion = schemaVersion
        self.tier = tier
        self.process = process
        self.event = event
        self.faultingThread = faultingThread
        self.lastExceptionBacktrace = lastExceptionBacktrace
        self.otherThreads = otherThreads
        self.asiMessages = asiMessages
        self.images = images
        self.symbolication = symbolication
        self.diagnosis = diagnosis
    }
}

// MARK: - Builder

extension AnalysisReport {
    /// Faulting-thread frame cap for `.summary` tier. Chosen to comfortably cover the
    /// app-relevant top of a stack while bounding token cost; see `truncatedFrameCount`.
    private static let summaryFaultingThreadFrameCap = 15

    /// Builds an `AnalysisReport` at the given `tier` from a parsed `.ips` file and an
    /// optional completed symbolication pass.
    ///
    /// - Parameters:
    ///   - ipsFile: The parsed crash report. If `symbolication` is supplied, its
    ///     `.file` (the possibly-enriched report) is used as the source of frame data
    ///     instead — `ipsFile` and `symbolication.file` should describe the same
    ///     incident (`symbolication.file` is `ipsFile` with `symbol`/`sourceFile`/
    ///     `sourceLine` filled in where possible).
    ///   - symbolication: The result of running `Symbolicator`, or `nil` if
    ///     symbolication wasn't attempted (e.g. no dSYMs were located for any
    ///     referenced image).
    ///   - tier: Controls how much of the report is populated; see each field's doc
    ///     comment for its tier-specific behavior.
    ///   - diagnosis: The result of running `DiagnosisEngine.diagnose(_:)`, or `nil` if
    ///     diagnosis wasn't attempted. When `nil`, `diagnosis.status` in the built report
    ///     is `.notApplicable` with empty hypothesis/fact lists rather than being omitted
    ///     — see `DiagnosisDump`. Callers should prefer diagnosing the SYMBOLICATED file
    ///     (i.e. `symbolication?.file ?? ipsFile`) so rules see enriched frames.
    ///
    /// ### "App thread" heuristic (`.standard` tier's `otherThreads`)
    /// A non-faulting thread is included in `.standard` iff at least one of its frames
    /// belongs to an image whose `name` equals the process's own `procName`. This is
    /// deliberately simple: it does not attempt to resolve app-extension bundles,
    /// embedded frameworks, or "responsible process" relationships to the crashing
    /// process — it only asks whether the thread ever runs code from the exact binary
    /// that crashed. Threads that only ever call into system frameworks (dispatch
    /// workers idling in `libdispatch`, etc.) are excluded at this tier; `.full`
    /// includes every thread unconditionally.
    public static func build(
        from ipsFile: IPSFile, symbolication: Symbolicator.Output?, tier: Tier, diagnosis: Diagnosis? = nil
    ) -> AnalysisReport {
        let effectiveFile = symbolication?.file ?? ipsFile
        let payload = effectiveFile.payload
        let header = effectiveFile.header
        let images = payload.usedImages

        let process = ProcessInfo(
            name: payload.procName ?? header.appName,
            bundleID: bundleID(from: payload),
            osVersion: header.osVersion,
            captureTime: payload.raw["captureTime"] as? String
        )

        let event = EventInfo(
            bugType: header.bugType,
            exceptionType: payload.exceptionType,
            signal: payload.exceptionSignal,
            terminationNamespace: payload.termination?["namespace"] as? String,
            terminationIndicator: payload.terminationIndicator,
            uncaughtExceptionName: payload.uncaughtExceptionName,
            uncaughtExceptionReason: payload.uncaughtExceptionReason
        )

        var referencedImageIndices = Set<Int>()

        var faultingThread: ThreadDump?
        if let idx = payload.faultingThreadIndex, payload.threads.indices.contains(idx) {
            let thread = payload.threads[idx]
            var frames = thread.frames
            var truncatedFrameCount: Int?
            if tier == .summary, frames.count > summaryFaultingThreadFrameCap {
                truncatedFrameCount = frames.count - summaryFaultingThreadFrameCap
                frames = Array(frames.prefix(summaryFaultingThreadFrameCap))
            }
            for frame in frames {
                if let imgIdx = frame.imageIndex { referencedImageIndices.insert(imgIdx) }
            }
            faultingThread = ThreadDump(
                index: idx, queue: thread.queue, triggered: thread.triggered,
                frames: frames.map { frameDump($0, images: images) },
                truncatedFrameCount: truncatedFrameCount
            )
        }

        var lastExceptionBacktrace: [FrameDump]?
        if let leb = payload.lastExceptionBacktrace {
            for frame in leb {
                if let imgIdx = frame.imageIndex { referencedImageIndices.insert(imgIdx) }
            }
            lastExceptionBacktrace = leb.map { frameDump($0, images: images) }
        }

        let otherThreads: [ThreadDump]?
        switch tier {
        // `.unrecognised` only ever arrives by decoding a report from a newer crashdx; a
        // freshly built report never carries it. Fall in with the lean tier.
        case .summary, .unrecognised:
            otherThreads = nil
        case .standard:
            let procName = payload.procName
            otherThreads = payload.threads.enumerated().compactMap { idx, thread -> ThreadDump? in
                guard idx != payload.faultingThreadIndex else { return nil }
                let hasAppFrame = thread.frames.contains { frame in
                    guard let imgIdx = frame.imageIndex, images.indices.contains(imgIdx) else { return false }
                    return procName != nil && images[imgIdx].name == procName
                }
                guard hasAppFrame else { return nil }
                for frame in thread.frames {
                    if let imgIdx = frame.imageIndex { referencedImageIndices.insert(imgIdx) }
                }
                return ThreadDump(
                    index: idx, queue: thread.queue, triggered: thread.triggered,
                    frames: thread.frames.map { frameDump($0, images: images) },
                    truncatedFrameCount: nil
                )
            }
        case .full:
            otherThreads = payload.threads.enumerated().compactMap { idx, thread -> ThreadDump? in
                guard idx != payload.faultingThreadIndex else { return nil }
                for frame in thread.frames {
                    if let imgIdx = frame.imageIndex { referencedImageIndices.insert(imgIdx) }
                }
                return ThreadDump(
                    index: idx, queue: thread.queue, triggered: thread.triggered,
                    frames: thread.frames.map { frameDump($0, images: images) },
                    truncatedFrameCount: nil
                )
            }
        }

        let asiMessages = payload.asiMessages.isEmpty ? nil : payload.asiMessages

        let imageDumps: [ImageDump]?
        switch tier {
        case .summary, .unrecognised:
            imageDumps = nil
        case .standard, .full:
            // One pass over every frame, rather than re-scanning them per image: the
            // frame accessors re-wrap their backing dictionaries on each access, so the
            // per-image form was O(images x frames) and a crafted report could stall here.
            let resolvedImages = symbolicatedImageIndices(in: payload)
            imageDumps = referencedImageIndices.sorted().compactMap { idx -> ImageDump? in
                guard images.indices.contains(idx) else { return nil }
                let image = images[idx]
                let resolved = resolvedImages.contains(idx)
                return ImageDump(
                    name: image.name, uuid: image.uuid, path: image.path, arch: image.arch,
                    status: resolved ? .symbolicated : .unsymbolicated
                )
            }
        }

        var symbolicationInfo: SymbolicationInfo?
        if let symbolication {
            let engine: SymbolicationInfo.EngineName = symbolication.engine == .crashSymbolicator ? .crashSymbolicator : .atos
            let statuses = symbolication.imageStatuses.map { status -> SymbolicationInfo.ImageStatus in
                let outcome: SymbolicationInfo.ImageStatus.Outcome
                let reason: String?
                switch status.outcome {
                case .symbolicated:
                    outcome = .symbolicated
                    reason = nil
                case .noDSYM:
                    outcome = .noDSYM
                    reason = nil
                case .uuidMismatch(let candidates):
                    outcome = .uuidMismatch
                    reason = "dSYM found but its UUID does not match this image (wrong build): "
                        + candidates.map(\.path).joined(separator: ", ")
                case .failed(let message):
                    outcome = .failed
                    reason = message
                }
                return SymbolicationInfo.ImageStatus(imageName: status.imageName, uuid: status.uuid, outcome: outcome, reason: reason)
            }
            symbolicationInfo = SymbolicationInfo(engine: engine, images: statuses)
        }

        let diagnosisDump: DiagnosisDump
        switch tier {
        case .summary, .unrecognised:
            // Lean tier: never carry the (potentially large) fact list, regardless of
            // whether a Diagnosis was supplied.
            diagnosisDump = DiagnosisDump(
                status: diagnosis?.status ?? .notApplicable,
                verdict: diagnosis?.verdict,
                hypotheses: diagnosis?.hypotheses ?? [],
                factsConsidered: nil
            )
        case .standard, .full:
            diagnosisDump = DiagnosisDump(
                status: diagnosis?.status ?? .notApplicable,
                verdict: diagnosis?.verdict,
                hypotheses: diagnosis?.hypotheses ?? [],
                factsConsidered: diagnosis?.factsConsidered ?? []
            )
        }

        return AnalysisReport(
            schemaVersion: currentSchemaVersion,
            tier: tier,
            process: process,
            event: event,
            faultingThread: faultingThread,
            lastExceptionBacktrace: lastExceptionBacktrace,
            otherThreads: otherThreads,
            asiMessages: asiMessages,
            images: imageDumps,
            symbolication: symbolicationInfo,
            diagnosis: diagnosisDump
        )
    }

    private static func frameDump(_ frame: StackFrame, images: [BinaryImage]) -> FrameDump {
        let imageName = frame.imageIndex.flatMap { images.indices.contains($0) ? images[$0].name : nil }
        return FrameDump(
            imageName: imageName, symbol: frame.symbol,
            sourceFile: frame.sourceFile, sourceLine: frame.sourceLine, imageOffset: frame.imageOffset
        )
    }

    private static func bundleID(from payload: CrashPayload) -> String? {
        (payload.raw["bundleInfo"] as? [String: Any])?["CFBundleIdentifier"] as? String
    }

    /// Every image index that has at least one frame carrying a symbol, computed in a
    /// single pass over the payload. Replaces a per-image re-scan that made report
    /// building quadratic in (images x frames).
    private static func symbolicatedImageIndices(in payload: CrashPayload) -> Set<Int> {
        var resolved = Set<Int>()
        for thread in payload.threads {
            for frame in thread.frames where frame.symbol != nil {
                if let idx = frame.imageIndex { resolved.insert(idx) }
            }
        }
        for frame in payload.lastExceptionBacktrace ?? [] where frame.symbol != nil {
            if let idx = frame.imageIndex { resolved.insert(idx) }
        }
        return resolved
    }
}
