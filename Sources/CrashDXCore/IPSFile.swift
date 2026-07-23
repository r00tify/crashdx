import Foundation

/// Errors thrown while parsing an .ips file.
public enum IPSParseError: Error, CustomStringConvertible {
    case emptyFile
    case invalidHeader(underlying: Error?)
    case invalidPayload(underlying: Error?)

    public var description: String {
        switch self {
        case .emptyFile:
            return "file is empty"
        case .invalidHeader(let e):
            return "first line is not a valid JSON header object" + (e.map { ": \($0)" } ?? "")
        case .invalidPayload(let e):
            return "payload after the header line is not a valid JSON object" + (e.map { ": \($0)" } ?? "")
        }
    }
}

/// A parsed modern (iOS 15+/macOS 12+) .ips diagnostic file: one JSON header line
/// followed by a JSON payload object.
///
/// Parsing is deliberately lenient: real-world files carry undocumented header keys and
/// per-OS-release payload variations, so both objects are retained raw and exposed
/// through typed accessors that tolerate absence. Nothing is dropped — fields this
/// library doesn't yet model (lastExceptionBacktrace, asi, threadState, vmSummary, …)
/// remain reachable through `header.raw` / `payload.raw`.
// The `[String: Any]`-backed parse types are `@unchecked Sendable` on a verified basis,
// not a hopeful one:
//
//   * `raw` is `let` on every one of them and is never written anywhere in Sources/.
//   * It is produced by `JSONSerialization.jsonObject(with:)` with NO options — in
//     particular WITHOUT `.mutableContainers` — so the leaves are immutable
//     NSString/NSNumber/NSArray/NSDictionary/NSNull.
//
// Concurrent reads of one parsed report are therefore safe, which matters because
// analysing a directory of crash reports in parallel is the main reason to reach for
// this library instead of the CLI. If `raw` ever becomes mutable, this annotation must
// come off with it.
public struct IPSFile: @unchecked Sendable {
    public let header: IPSHeader
    public let payload: CrashPayload

    public static func parse(data: Data) throws -> IPSFile {
        guard !data.isEmpty else { throw IPSParseError.emptyFile }
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else {
            throw IPSParseError.invalidHeader(underlying: nil)
        }
        let headerData = data[data.startIndex..<newline]
        let payloadData = data[data.index(after: newline)...]

        let headerObj: [String: Any]
        do {
            guard let obj = try JSONSerialization.jsonObject(with: Data(headerData)) as? [String: Any] else {
                throw IPSParseError.invalidHeader(underlying: nil)
            }
            headerObj = obj
        } catch let e as IPSParseError {
            throw e
        } catch {
            throw IPSParseError.invalidHeader(underlying: error)
        }

        let payloadObj: [String: Any]
        do {
            guard let obj = try JSONSerialization.jsonObject(with: Data(payloadData)) as? [String: Any] else {
                throw IPSParseError.invalidPayload(underlying: nil)
            }
            payloadObj = obj
        } catch let e as IPSParseError {
            throw e
        } catch {
            throw IPSParseError.invalidPayload(underlying: error)
        }

        return IPSFile(header: IPSHeader(raw: headerObj), payload: CrashPayload(raw: payloadObj))
    }

    public static func parse(contentsOf url: URL) throws -> IPSFile {
        try parse(data: Data(contentsOf: url))
    }
}

/// The single-line JSON metadata header at the top of an .ips file.
public struct IPSHeader: @unchecked Sendable {
    public let raw: [String: Any]

    /// Documented values: "309" (crash, incl. user faults), "288" (stackshot).
    /// Other values observed in the wild are undocumented — treat as opaque.
    public var bugType: String? { string("bug_type") }
    public var appName: String? { string("app_name") ?? string("name") }
    public var osVersion: String? { string("os_version") }
    public var incidentID: String? { string("incident_id") }
    public var timestamp: String? { string("timestamp") }

    private func string(_ key: String) -> String? { raw[key] as? String }
}

/// The crash-report payload object (everything after the header line).
public struct CrashPayload: @unchecked Sendable {
    public let raw: [String: Any]

    public var procName: String? { raw["procName"] as? String }
    public var procPath: String? { raw["procPath"] as? String }

    public var exceptionType: String? { exception?["type"] as? String }
    public var exceptionSignal: String? { exception?["signal"] as? String }
    public var exception: [String: Any]? { raw["exception"] as? [String: Any] }

    public var termination: [String: Any]? { raw["termination"] as? [String: Any] }
    public var terminationIndicator: String? { termination?["indicator"] as? String }

    public var faultingThreadIndex: Int? { intValue(raw["faultingThread"]) }

    /// Present for uncaught NSExceptions; the throw-site frames often exist ONLY here,
    /// and are easily lost when a report is re-serialized by a tool that only models the
    /// thread list — crashdx must not drop them.
    public var lastExceptionBacktrace: [StackFrame]? {
        lastExceptionBacktraceRaw?.map(StackFrame.init(raw:))
    }

    /// The raw dictionaries backing `lastExceptionBacktrace`, before `StackFrame` wraps
    /// them. Kept for callers (and Symbolicator's in-place JSON patching) that need to
    /// round-trip the exact payload shape.
    public var lastExceptionBacktraceRaw: [[String: Any]]? {
        raw["lastExceptionBacktrace"] as? [[String: Any]]
    }

    /// Application Specific Information: keyed by originating library/dylib name (e.g.
    /// "CoreFoundation", "libsystem_c.dylib"), values are arrays of message strings.
    /// Verified against a real uncaught-NSException fixture (corpus/fixtures/nsexcrash) —
    /// see corpus/README.md for what it does and doesn't contain in practice.
    public var asiRaw: [String: Any]? {
        raw["asi"] as? [String: Any]
    }

    /// Every `asi` message string, flattened across all libraries, in encounter order.
    public var asiMessages: [String] {
        guard let asiRaw else { return [] }
        // Dictionary key order isn't guaranteed; sort for deterministic output since this
        // is a diagnostic convenience view, not a faithful raw accessor.
        return asiRaw.keys.sorted().flatMap { asiRaw[$0] as? [String] ?? [] }
    }

    /// The exception name from the standard `*** Terminating app due to uncaught
    /// exception 'NAME', reason: 'REASON'` message, when present in any `asi` string.
    /// Empirically this pattern is an AppKit/UIKit-installed-handler phenomenon — plain
    /// CLI/Foundation crashes (verified via corpus/fixtures/nsexcrash and four real
    /// corpus/raw/ files) do NOT carry it, so `nil` here is a common, expected outcome.
    public var uncaughtExceptionName: String? {
        uncaughtExceptionNameAndReason?.name
    }

    /// The reason string from the same pattern as `uncaughtExceptionName`.
    public var uncaughtExceptionReason: String? {
        uncaughtExceptionNameAndReason?.reason
    }

    private var uncaughtExceptionNameAndReason: (name: String, reason: String)? {
        for message in asiMessages {
            if let match = Self.uncaughtExceptionRegex.firstMatch(
                in: message, range: NSRange(message.startIndex..<message.endIndex, in: message)
            ), match.numberOfRanges == 3,
               let nameRange = Range(match.range(at: 1), in: message),
               let reasonRange = Range(match.range(at: 2), in: message) {
                return (String(message[nameRange]), String(message[reasonRange]))
            }
        }
        return nil
    }

    /// Tolerates the documented `'NAME', reason: 'REASON'` form; reason may itself embed
    /// single quotes so this matches greedily to the LAST `reason: '...'` occurrence up to
    /// end of string rather than the first closing quote.
    private static let uncaughtExceptionRegex = try! NSRegularExpression(
        pattern: #"Terminating app due to uncaught exception '([^']+)', reason: '(.+)'"#
    )

    public var threads: [CrashThread] {
        (raw["threads"] as? [[String: Any]])?.map(CrashThread.init(raw:)) ?? []
    }

    public var usedImages: [BinaryImage] {
        (raw["usedImages"] as? [[String: Any]])?.map(BinaryImage.init(raw:)) ?? []
    }

    public var faultingThread: CrashThread? {
        guard let idx = faultingThreadIndex, threads.indices.contains(idx) else { return nil }
        return threads[idx]
    }

    /// Freeform kernel-produced text describing whether the faulting address falls inside a
    /// known VM region (and which one), e.g. `"0x8 is not in any region. ..."` or `"0x...
    /// is in a 16K region. ... STACK GUARD ..."`. Present on real `EXC_BAD_ACCESS` reports
    /// (verified: corpus/raw/axassetsd-*, corpus/raw/contactsd-*, corpus/fixtures/nullderef)
    /// — see `MemoryFactsExtractor`.
    public var vmregioninfo: String? { raw["vmregioninfo"] as? String }
}

public struct CrashThread: @unchecked Sendable {
    public let raw: [String: Any]

    public var triggered: Bool { (raw["triggered"] as? Bool) ?? false }
    public var queue: String? { raw["queue"] as? String }
    public var frames: [StackFrame] {
        (raw["frames"] as? [[String: Any]])?.map(StackFrame.init(raw:)) ?? []
    }

    /// The ARM64 (`ARM_THREAD_STATE64`) register snapshot at the fault, when present.
    /// Verified shape (real corpus/raw + corpus/fixtures/nullderef threads):
    /// `{"x": [{"value": N, "symbol"?: ..., "symbolLocation"?: ...}, ...], "flavor":
    /// "ARM_THREAD_STATE64", "lr"/"fp"/"sp"/"pc"/"far": {"value": N, "matchesCrashFrame"?:
    /// N}, "cpsr": {"value": N}, "esr": {"value": N, "description"?: ...}}`. Register
    /// values are DECIMAL (not the hex strings `exception.codes`/`subtype` use).
    public var threadState: [String: Any]? { raw["threadState"] as? [String: Any] }
}

public struct StackFrame: @unchecked Sendable {
    public let raw: [String: Any]

    public var imageIndex: Int? { intValue(raw["imageIndex"]) }
    /// Offset into the image, in bytes. Stored as a DECIMAL number in the file
    /// (Apple-documented); convert to hex before handing to atos.
    public var imageOffset: Int? { intValue(raw["imageOffset"]) }
    /// Present only when the OS or a symbolicator resolved it.
    public var symbol: String? { raw["symbol"] as? String }
    public var symbolLocation: Int? { intValue(raw["symbolLocation"]) }
    public var sourceFile: String? { raw["sourceFile"] as? String }
    public var sourceLine: Int? { intValue(raw["sourceLine"]) }
}

public struct BinaryImage: @unchecked Sendable {
    public let raw: [String: Any]

    public var name: String? { raw["name"] as? String }
    public var path: String? { raw["path"] as? String }
    /// Build UUID; dSYM matching requires an identical UUID (compare case-insensitively —
    /// headers use lowercase, dwarfdump prints uppercase).
    public var uuid: String? { raw["uuid"] as? String }
    public var base: Int? { intValue(raw["base"]) }
    public var size: Int? { intValue(raw["size"]) }
    public var arch: String? { raw["arch"] as? String }
}

/// JSON numbers may decode as Int, Int64, or NSNumber depending on magnitude; some
/// third-party writers emit numeric fields as strings. Accept all of them.
private func intValue(_ any: Any?) -> Int? {
    switch any {
    case let i as Int: return i
    case let n as NSNumber: return n.intValue
    case let s as String: return Int(s)
    default: return nil
    }
}
