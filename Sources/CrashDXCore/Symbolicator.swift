import Foundation

/// Restores `symbol` / `sourceFile` / `sourceLine` on stack frames of an unsymbolicated
/// `.ips` file, given a map of build UUID -> dSYM bundle URL (as produced by
/// `DSYMLocator`).
///
/// Two engines are used, in order:
/// 1. Apple's `CrashSymbolicator.py` (ships inside Xcode's CoreSymbolicationDT
///    framework). It understands inlines, demangling, and multi-image crash logs in one
///    shot, so it is tried first whenever it's available and at least one dSYM was
///    supplied.
/// 2. `/usr/bin/atos`, run once per image that has a matching dSYM, as a fallback when
///    the script is missing or fails for any reason.
///
/// `symbolicate` never throws to report a *symbolication* failure — every image gets an
/// honest `ImageStatus` (`.noDSYM`, `.symbolicated`, or `.failed(reason)`) instead. It
/// only throws for input that can't be parsed, or output that can't be re-serialized.
public struct Symbolicator: Sendable {
    public enum Engine: Equatable, Sendable {
        case crashSymbolicator
        case atos
    }

    public struct ImageStatus: Sendable {
        public let imageName: String
        public let uuid: String?

        public enum Outcome: Equatable, Sendable {
            case symbolicated(Engine)
            case noDSYM
            /// A dSYM for this image WAS found, but its UUID doesn't match the one the
            /// crash report records — i.e. it belongs to a different build. Reported
            /// distinctly from `.noDSYM` because the remedy is different: you already
            /// have a dSYM, it's just the wrong one, so the fix is to find the matching
            /// archive rather than to go looking for a file you may already possess.
            /// Never used for symbolication — a stale dSYM yields confidently wrong
            /// symbols, which is worse than none.
            case uuidMismatch(candidates: [URL])
            case failed(String)
        }
        public let outcome: Outcome
    }

    public struct Output: Sendable {
        /// The (possibly enriched) crash report.
        public let file: IPSFile
        /// One entry per binary image referenced by any frame.
        public let imageStatuses: [ImageStatus]
        /// The engine that produced `file`.
        ///
        /// When nothing was actually symbolicated — `dsyms` was empty, or every candidate
        /// was rejected as a wrong-build `uuidMismatch` — this reports `.atos`, because
        /// that is the (no-op) path that ran. Read it together with `imageStatuses`
        /// rather than as proof that symbolication happened.
        public let engine: Engine
    }

    public enum SymbolicatorError: Error, CustomStringConvertible {
        case reserializationFailed(underlying: Error)

        public var description: String {
            switch self {
            case .reserializationFailed(let e):
                return "failed to re-serialize the symbolicated payload: \(e)"
            }
        }
    }

    /// Lowercase build UUID -> dSYM bundles that were found for that image but whose
    /// own UUID didn't match. Never used for symbolication; carried so the resulting
    /// `ImageStatus` can say "wrong build" instead of the misleading "no dSYM".
    public let mismatchedUUIDs: [String: [URL]]

    public init(mismatchedUUIDs: [String: [URL]] = [:]) {
        self.mismatchedUUIDs = mismatchedUUIDs
    }

    /// `dsyms` maps build UUID -> dSYM bundle URL. Keys are matched case-insensitively.
    ///
    /// Callers previously had to supply lowercase keys, while `DSYMLocator` normalises
    /// UUIDs to UPPERCASE — so a consumer following the locator's convention got every
    /// image reported as `.noDSYM`, which is indistinguishable from genuinely not having
    /// the dSYM. Normalising here removes the trap rather than documenting it.
    public func symbolicate(ipsData: Data, dsyms rawDSYMs: [String: URL]) throws -> Output {
        let dsyms = Dictionary(
            rawDSYMs.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        if !dsyms.isEmpty,
           let scriptURL = Self.locateCrashSymbolicatorScript(),
           let output = attemptCrashSymbolicator(scriptURL: scriptURL, ipsData: ipsData, dsyms: dsyms) {
            return output
        }
        return try symbolicateWithAtos(ipsData: ipsData, dsyms: dsyms)
    }

    // MARK: - Engine 1: CrashSymbolicator.py

    /// `<DeveloperDir>/../SharedFrameworks/CoreSymbolicationDT.framework/Versions/A/Resources/CrashSymbolicator.py`,
    /// where `DeveloperDir` comes from `xcode-select -p`.
    static func locateCrashSymbolicatorScript() -> URL? {
        guard let devPath = Self.runCapturingStdout(
            executable: "/usr/bin/xcode-select", arguments: ["-p"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines), !devPath.isEmpty else {
            return nil
        }
        // devPath ends in ".../Xcode.app/Contents/Developer"; the script lives under
        // the sibling "SharedFrameworks" directory inside Contents.
        let contentsURL = URL(fileURLWithPath: devPath).deletingLastPathComponent()
        let scriptURL = contentsURL
            .appendingPathComponent("SharedFrameworks")
            .appendingPathComponent("CoreSymbolicationDT.framework")
            .appendingPathComponent("Versions/A/Resources/CrashSymbolicator.py")
        return FileManager.default.isReadableFile(atPath: scriptURL.path) ? scriptURL : nil
    }

    /// Runs CrashSymbolicator.py against `ipsData` with a search directory built out of
    /// `dsyms`. Returns `nil` (never throws) on any failure so the caller can fall back
    /// to atos.
    ///
    /// CrashSymbolicator.py's `-d` flag accepts either a single dSYM bundle, or a
    /// directory it recursively globs for `DWARF/<imageName>` paths (see
    /// `debugsymbols_search_directory_for_dsym` / `session_for_image` in the script).
    /// That recursive glob does **not** descend into symlinked directories, so a
    /// directory of symlinked `*.dSYM` bundles silently fails to match anything
    /// (verified empirically). Symlinking at the leaf *file* level — i.e. building
    /// `<tmp>/<uuid>/DWARF/<imageName> -> <real DWARF file>` for each image, with real
    /// (non-symlink) intermediate directories — works, because the glob only needs to
    /// traverse real directories and merely opens the final symlinked file. This is the
    /// approach used below, which supports arbitrarily many dSYMs in one invocation.
    private func attemptCrashSymbolicator(
        scriptURL: URL, ipsData: Data, dsyms: [String: URL]
    ) -> Output? {
        guard let original = try? IPSFile.parse(data: ipsData) else { return nil }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("crashdx-crashsym-\(UUID().uuidString)")
        let searchDir = workDir.appendingPathComponent("dsyms")
        let ipsPath = workDir.appendingPathComponent("crash.ips")
        do {
            try fm.createDirectory(at: searchDir, withIntermediateDirectories: true)
            try ipsData.write(to: ipsPath)
        } catch {
            return nil
        }
        defer { try? fm.removeItem(at: workDir) }

        var linkedAny = false
        for image in original.payload.usedImages {
            guard let uuid = image.uuid?.lowercased(), let dsymURL = dsyms[uuid] else { continue }
            guard let dwarfURL = DSYMLocator.dwarfURL(inDSYM: dsymURL) else { continue }
            let imageName = image.name ?? dwarfURL.lastPathComponent
            let dwarfDirDest = searchDir
                .appendingPathComponent(uuid, isDirectory: true)
                .appendingPathComponent("DWARF", isDirectory: true)
            do {
                try fm.createDirectory(at: dwarfDirDest, withIntermediateDirectories: true)
                let linkURL = dwarfDirDest.appendingPathComponent(imageName)
                try fm.createSymbolicLink(at: linkURL, withDestinationURL: dwarfURL)
                linkedAny = true
            } catch {
                continue
            }
        }
        guard linkedAny else { return nil }

        guard let run = Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [scriptURL.path, "-d", searchDir.path, ipsPath.path]
        ), run.exitCode == 0,
              let outputString = String(data: run.stdout, encoding: .utf8) else { return nil }
        guard let resultFile = Self.parseCrashSymbolicatorOutput(outputString) else { return nil }

        let statuses = Self.imageStatuses(
            original: original, result: resultFile, dsyms: dsyms,
            mismatched: mismatchedUUIDs, engine: .crashSymbolicator
        )
        return Output(file: resultFile, imageStatuses: statuses, engine: .crashSymbolicator)
    }

    /// CrashSymbolicator.py's stdout is zero or more `Symbolicating thread <id>` status
    /// lines, then the compact single-line .ips header, then the (usually pretty-printed)
    /// payload JSON. Skip everything before the first line starting with `{`; that line is
    /// the header, everything after it is the payload.
    static func parseCrashSymbolicatorOutput(_ output: String) -> IPSFile? {
        let lines = output.components(separatedBy: "\n")
        guard let headerIdx = lines.firstIndex(where: { $0.hasPrefix("{") }) else { return nil }
        let headerLine = lines[headerIdx]
        let payloadRest = lines[(headerIdx + 1)...].joined(separator: "\n")
        let combined = headerLine + "\n" + payloadRest
        guard let data = combined.data(using: .utf8) else { return nil }
        return try? IPSFile.parse(data: data)
    }

    // MARK: - Engine 2: atos fallback

    /// Symbolicates using `/usr/bin/atos`, once per image that has a matching dSYM.
    /// Internal (not private) so it can be exercised directly in tests without depending
    /// on CrashSymbolicator.py being installed.
    func symbolicateWithAtos(ipsData: Data, dsyms: [String: URL]) throws -> Output {
        let original = try IPSFile.parse(data: ipsData)

        guard let newlineIdx = ipsData.firstIndex(of: UInt8(ascii: "\n")) else {
            // IPSFile.parse would already have thrown in this case.
            return Output(file: original, imageStatuses: [], engine: .atos)
        }
        let headerBytes = Data(ipsData[ipsData.startIndex..<newlineIdx])
        let payloadData = Data(ipsData[ipsData.index(after: newlineIdx)...])

        guard var payloadObj = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return Output(file: original, imageStatuses: [], engine: .atos)
        }

        var threadsArray = payloadObj["threads"] as? [[String: Any]] ?? []
        var lebArray = payloadObj["lastExceptionBacktrace"] as? [[String: Any]]

        // Group every frame (across all threads, plus the synthetic last-exception
        // backtrace) by the image it belongs to.
        enum FrameLocation {
            case thread(threadIndex: Int, frameIndex: Int)
            case lastExceptionBacktrace(frameIndex: Int)
        }
        var locationsByImage: [Int: [(location: FrameLocation, offset: Int)]] = [:]

        for (tIdx, thread) in threadsArray.enumerated() {
            let frames = thread["frames"] as? [[String: Any]] ?? []
            for (fIdx, frame) in frames.enumerated() {
                guard let imgIdx = intValue(frame["imageIndex"]), let offset = intValue(frame["imageOffset"]) else { continue }
                locationsByImage[imgIdx, default: []].append((.thread(threadIndex: tIdx, frameIndex: fIdx), offset))
            }
        }
        if let leb = lebArray {
            for (fIdx, frame) in leb.enumerated() {
                guard let imgIdx = intValue(frame["imageIndex"]), let offset = intValue(frame["imageOffset"]) else { continue }
                locationsByImage[imgIdx, default: []].append((.lastExceptionBacktrace(frameIndex: fIdx), offset))
            }
        }

        let images = original.payload.usedImages
        var statuses: [ImageStatus] = []

        for imgIdx in locationsByImage.keys.sorted() {
            guard images.indices.contains(imgIdx) else { continue }
            let image = images[imgIdx]
            let imageName = image.name ?? image.path ?? "image[\(imgIdx)]"
            let locations = locationsByImage[imgIdx] ?? []

            guard let uuidLower = image.uuid?.lowercased(), let dsymURL = dsyms[uuidLower] else {
                statuses.append(ImageStatus(
                    imageName: imageName, uuid: image.uuid,
                    outcome: Self.outcomeForUnsymbolicated(uuid: image.uuid, mismatched: mismatchedUUIDs)
                ))
                continue
            }
            guard let dwarfURL = DSYMLocator.dwarfURL(inDSYM: dsymURL) else {
                statuses.append(ImageStatus(
                    imageName: imageName, uuid: image.uuid,
                    outcome: .failed("no DWARF file found under \(dsymURL.path)")
                ))
                continue
            }
            let arch = image.arch ?? "arm64"
            let hexOffsets = locations.map { "0x" + String($0.offset, radix: 16) }

            guard let atosOutput = Self.runAtos(arch: arch, dwarfURL: dwarfURL, hexOffsets: hexOffsets) else {
                statuses.append(ImageStatus(
                    imageName: imageName, uuid: image.uuid, outcome: .failed("atos invocation failed")
                ))
                continue
            }
            let lines = atosOutput
                .trimmingCharacters(in: .newlines)
                .components(separatedBy: "\n")
            guard lines.count == locations.count else {
                statuses.append(ImageStatus(
                    imageName: imageName, uuid: image.uuid,
                    outcome: .failed("atos returned \(lines.count) lines for \(locations.count) offsets")
                ))
                continue
            }

            var resolvedAny = false
            for (loc, line) in zip(locations, lines) {
                guard let resolution = Self.parseAtosLine(line) else { continue }
                resolvedAny = true
                switch loc.location {
                case .thread(let tIdx, let fIdx):
                    var frame = threadsArray[tIdx]["frames"] as? [[String: Any]] ?? []
                    var f = frame[fIdx]
                    f["symbol"] = resolution.symbol
                    if let sourceFile = resolution.sourceFile { f["sourceFile"] = sourceFile }
                    if let sourceLine = resolution.sourceLine { f["sourceLine"] = sourceLine }
                    frame[fIdx] = f
                    threadsArray[tIdx]["frames"] = frame
                case .lastExceptionBacktrace(let fIdx):
                    guard lebArray != nil else { continue }
                    var f = lebArray![fIdx]
                    f["symbol"] = resolution.symbol
                    if let sourceFile = resolution.sourceFile { f["sourceFile"] = sourceFile }
                    if let sourceLine = resolution.sourceLine { f["sourceLine"] = sourceLine }
                    lebArray![fIdx] = f
                }
            }
            statuses.append(ImageStatus(
                imageName: imageName, uuid: image.uuid,
                outcome: resolvedAny ? .symbolicated(.atos) : .failed("atos did not resolve any frames for this image")
            ))
        }

        payloadObj["threads"] = threadsArray
        if let lebArray {
            payloadObj["lastExceptionBacktrace"] = lebArray
        }

        let payloadData2: Data
        do {
            payloadData2 = try JSONSerialization.data(withJSONObject: payloadObj, options: [])
        } catch {
            throw SymbolicatorError.reserializationFailed(underlying: error)
        }

        var finalData = headerBytes
        finalData.append(UInt8(ascii: "\n"))
        finalData.append(payloadData2)
        let finalFile = try IPSFile.parse(data: finalData)
        return Output(file: finalFile, imageStatuses: statuses, engine: .atos)
    }

    struct AtosResolution {
        let symbol: String
        let sourceFile: String?
        let sourceLine: Int?
    }

    /// Parses one line of `atos` output: `<symbol> (in <module>) (<location>)`, where
    /// `<location>` is `file.swift:14`, `/<compiler-generated>:0` (source-less; dropped
    /// per Apple's own convention), or (for an unresolvable address) just the address
    /// echoed back — which doesn't match this pattern at all, so it correctly yields
    /// `nil`.
    static func parseAtosLine(_ line: String) -> AtosResolution? {
        guard let match = atosLineRegex.firstMatch(
            in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)
        ), match.numberOfRanges == 4,
           let symbolRange = Range(match.range(at: 1), in: line),
           let locationRange = Range(match.range(at: 3), in: line) else {
            // No location clause: accept the symbol-only form rather than dropping a
            // symbol atos successfully resolved.
            if let m = atosSymbolOnlyRegex.firstMatch(
                in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)
            ), let r = Range(m.range(at: 1), in: line), !line[r].isEmpty {
                return AtosResolution(symbol: String(line[r]), sourceFile: nil, sourceLine: nil)
            }
            return nil
        }
        let symbol = String(line[symbolRange])
        let location = String(line[locationRange])
        guard !symbol.isEmpty else { return nil }

        // Split off trailing `:line` and, when present, a further `:column`. Taking only
        // the LAST colon mis-reads `Widget.swift:120:8` as file `Widget.swift:120` at
        // line 8 — a plausible-looking source location pointing at a file that does not
        // exist, which is worse than reporting nothing.
        var remainder = Substring(location)
        var numericSuffixes: [Int] = []
        while let colonIdx = remainder.lastIndex(of: ":"),
              let value = Int(remainder[remainder.index(after: colonIdx)...]),
              numericSuffixes.count < 2 {
            numericSuffixes.insert(value, at: 0)
            remainder = remainder[remainder.startIndex..<colonIdx]
        }
        guard let sourceLine = numericSuffixes.first else {
            return AtosResolution(symbol: symbol, sourceFile: nil, sourceLine: nil)
        }

        let fileName = (String(remainder) as NSString).lastPathComponent
        // `<compiler-generated>` is atos's marker for source-less code; Apple's own tools
        // drop it rather than presenting it as a file. An empty remainder (`(:12)`) has
        // no file to report either.
        guard fileName != "<compiler-generated>", !fileName.isEmpty else {
            return AtosResolution(symbol: symbol, sourceFile: nil, sourceLine: nil)
        }
        return AtosResolution(symbol: symbol, sourceFile: fileName, sourceLine: sourceLine)
    }

    private static let atosLineRegex = try! NSRegularExpression(pattern: #"^(.*) \(in (.+)\) \((.+)\)$"#)

    /// atos emits `<symbol> (in <module>) + <offset>` whenever it resolves a symbol but
    /// the dSYM carries no line table for that address. That is a successful
    /// symbolication with no source location — previously it matched neither branch and
    /// was discarded, so the image was reported as "atos did not resolve any frames"
    /// despite atos having named every one of them.
    private static let atosSymbolOnlyRegex =
        try! NSRegularExpression(pattern: #"^(.*) \(in (.+)\) \+ [0-9]+$"#)

    static func runAtos(arch: String, dwarfURL: URL, hexOffsets: [String]) -> String? {
        guard !hexOffsets.isEmpty, FileManager.default.isExecutableFile(atPath: "/usr/bin/atos") else { return nil }

        // `arch` comes straight out of the crash report, so this argv is partly
        // attacker-controlled — see `Subprocess` for why that matters here.
        guard let run = Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/atos"),
            arguments: ["-arch", arch, "-o", dwarfURL.path, "-offset"] + hexOffsets
        ), run.exitCode == 0 else { return nil }
        return String(data: run.stdout, encoding: .utf8)
    }

    // MARK: - Shared status computation

    /// Distinguishes "we found a dSYM but it's from another build" from "we found
    /// nothing" — the two have different remedies, so they must not collapse together.
    static func outcomeForUnsymbolicated(uuid: String?, mismatched: [String: [URL]]) -> ImageStatus.Outcome {
        if let uuid, let candidates = mismatched[uuid.lowercased()], !candidates.isEmpty {
            return .uuidMismatch(candidates: candidates)
        }
        return .noDSYM
    }

    private static func imageStatuses(
        original: IPSFile, result: IPSFile, dsyms: [String: URL],
        mismatched: [String: [URL]], engine: Engine
    ) -> [ImageStatus] {
        let images = original.payload.usedImages
        var statuses: [ImageStatus] = []
        for idx in referencedImageIndices(in: original).sorted() {
            guard images.indices.contains(idx) else { continue }
            let image = images[idx]
            let imageName = image.name ?? image.path ?? "image[\(idx)]"

            guard let uuidLower = image.uuid?.lowercased(), dsyms[uuidLower] != nil else {
                statuses.append(ImageStatus(
                    imageName: imageName, uuid: image.uuid,
                    outcome: outcomeForUnsymbolicated(uuid: image.uuid, mismatched: mismatched)
                ))
                continue
            }
            if frameCount(forImageIndex: idx, in: result, requiringSymbol: true) > 0 {
                statuses.append(ImageStatus(imageName: imageName, uuid: image.uuid, outcome: .symbolicated(engine)))
            } else {
                statuses.append(ImageStatus(
                    imageName: imageName, uuid: image.uuid,
                    outcome: .failed("no frames for this image were resolved")
                ))
            }
        }
        return statuses
    }

    private static func referencedImageIndices(in file: IPSFile) -> Set<Int> {
        var indices = Set<Int>()
        for thread in file.payload.threads {
            for frame in thread.frames {
                if let idx = frame.imageIndex { indices.insert(idx) }
            }
        }
        if let leb = file.payload.lastExceptionBacktrace {
            for frame in leb {
                if let idx = frame.imageIndex { indices.insert(idx) }
            }
        }
        return indices
    }

    private static func frameCount(forImageIndex idx: Int, in file: IPSFile, requiringSymbol: Bool) -> Int {
        var count = 0
        for thread in file.payload.threads {
            for frame in thread.frames where frame.imageIndex == idx {
                if !requiringSymbol || frame.symbol != nil { count += 1 }
            }
        }
        if let leb = file.payload.lastExceptionBacktrace {
            for frame in leb where frame.imageIndex == idx {
                if !requiringSymbol || frame.symbol != nil { count += 1 }
            }
        }
        return count
    }

    // MARK: - Process helpers

    private static func runCapturingStdout(executable: String, arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        guard let run = Subprocess.run(
            executable: URL(fileURLWithPath: executable), arguments: arguments
        ), run.exitCode == 0 else { return nil }
        return String(data: run.stdout, encoding: .utf8)
    }
}

/// JSON numbers may decode as Int, Int64, or NSNumber depending on magnitude; some
/// third-party writers emit numeric fields as strings. Accept all of them. (Mirrors the
/// private helper in IPSFile.swift; duplicated because that one isn't shared across
/// files.)
private func intValue(_ any: Any?) -> Int? {
    switch any {
    case let i as Int: return i
    case let n as NSNumber: return n.intValue
    case let s as String: return Int(s)
    default: return nil
    }
}
