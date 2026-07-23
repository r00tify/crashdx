import Foundation

/// The shared "load an .ips file, locate & apply dSYMs, diagnose, build a report" pipeline
/// that both the `crashdx` CLI (`analyze`/`symbolicate` subcommands) and `crashdx-mcp`
/// (the `crashdx_analyze`/`crashdx_symbolicate` tools) drive. Extracted so the two
/// front ends can never drift: this is the ONE place the parse -> locate-dSYMs ->
/// symbolicate -> diagnose -> `AnalysisReport.build` sequence is written.
///
/// Every failure mode is reported via `PipelineError` (thrown), never `fatalError`/`exit`
/// — callers (a CLI that turns errors into `stderr` + a process exit code, or an MCP tool
/// that turns them into an `isError: true` tool result) decide how to surface it.
public enum AnalyzePipeline {
    // MARK: - Errors

    /// Every way `AnalyzePipeline` can fail. `description` is the exact text the CLI
    /// prints to stderr for each case, so this type owns the user-facing wording.
    public enum PipelineError: Error, CustomStringConvertible {
        case fileNotFound(path: String)
        case unreadable(path: String, underlying: Error)
        case parseFailed(path: String, underlying: Error)
        case symbolicationFailed(underlying: Error)

        public var description: String {
            switch self {
            case .fileNotFound(let path):
                return "file not found: \(path)"
            case .unreadable(let path, let underlying):
                return "could not read \(path): \(underlying)"
            case .parseFailed(let path, let underlying):
                return "failed to parse \(path): \(underlying)"
            case .symbolicationFailed(let underlying):
                return "symbolication failed: \(underlying)"
            }
        }
    }

    // MARK: - analyze

    /// Everything `analyze` produces along the way — not just the final `AnalysisReport`
    /// — so callers that also need the human-readable summary (the CLI's non-`--json`
    /// path prints `diagnosis`/`diagnosedFile` directly, independent of `report`'s tier
    /// gating) don't have to recompute anything.
    public struct AnalyzeResult: Sendable {
        public let file: IPSFile
        public let symbolication: Symbolicator.Output?
        /// The file diagnosis actually ran against: the symbolicated file when
        /// symbolication happened, `file` otherwise. See `DiagnosisEngine`'s doc comment
        /// on why rules should see enriched frames.
        public let diagnosedFile: IPSFile
        public let diagnosis: Diagnosis
        public let report: AnalysisReport
    }

    /// Parses `path`, locates dSYMs for unsymbolicated referenced images, symbolicates
    /// when at least one dSYM was found, diagnoses the symbolicated (or raw) file, and
    /// builds the `AnalysisReport` — exactly the `crashdx analyze` CLI flow.
    public static func analyze(
        path: String, tier: AnalysisReport.Tier, dsymPaths: [URL], useSpotlight: Bool,
        searchArchives: Bool = true
    ) throws -> AnalyzeResult {
        let (file, data) = try loadIPSFile(path: path)
        let symbolication = locateAndSymbolicateForAnalyze(
            file: file, ipsData: data, dsymPaths: dsymPaths, useSpotlight: useSpotlight,
            searchArchives: searchArchives
        )

        // Diagnose the SYMBOLICATED file (falling back to the raw parse when
        // symbolication didn't run) so rules see enriched frames — e.g. a source
        // file/line on an `inspect` point instead of just a bare image offset.
        let diagnosedFile = symbolication?.file ?? file
        let diagnosis = DiagnosisEngine().diagnose(diagnosedFile)

        let report = AnalysisReport.build(
            from: file, symbolication: symbolication, tier: tier, diagnosis: diagnosis
        )

        return AnalyzeResult(
            file: file, symbolication: symbolication, diagnosedFile: diagnosedFile,
            diagnosis: diagnosis, report: report
        )
    }

    // MARK: - symbolicate

    /// Parses `path`, locates dSYMs for every referenced image, symbolicates (even if zero
    /// dSYMs were found — each image then simply reports `.noDSYM`, matching
    /// `Symbolicator`'s contract), and returns the canonical two-JSON-document `.ips` shape
    /// (header line, newline, pretty-printed payload, trailing newline) as raw bytes —
    /// exactly the `crashdx symbolicate` CLI flow, ready to write straight to a `.ips` file
    /// or hand back as MCP tool text.
    public static func symbolicateToIPSData(
        path: String, dsymPaths: [URL], useSpotlight: Bool, searchArchives: Bool = true
    ) throws -> Data {
        let (file, data) = try loadIPSFile(path: path)
        let (dsyms, mismatched) = locateDSYMs(
            file: file, dsymPaths: dsymPaths, useSpotlight: useSpotlight,
            searchArchives: searchArchives
        )

        do {
            let output = try Symbolicator(mismatchedUUIDs: mismatched)
                .symbolicate(ipsData: data, dsyms: dsyms)
            let headerData = try JSONSerialization.data(
                withJSONObject: output.file.header.raw, options: [.sortedKeys]
            )
            let payloadData = try JSONSerialization.data(
                withJSONObject: output.file.payload.raw, options: [.prettyPrinted, .sortedKeys]
            )
            var result = headerData
            result.append(UInt8(ascii: "\n"))
            result.append(payloadData)
            result.append(UInt8(ascii: "\n"))
            return result
        } catch {
            throw PipelineError.symbolicationFailed(underlying: error)
        }
    }

    // MARK: - Shared loading

    /// Parses the `.ips` file at `path`. Throws `PipelineError` (never `fatalError`/`exit`)
    /// on any failure — the CLI turns these into `stderr` + an exit code; the MCP server
    /// turns them into an `isError: true` tool result.
    public static func loadIPSFile(path: String) throws -> (file: IPSFile, data: Data) {
        guard FileManager.default.fileExists(atPath: path) else {
            throw PipelineError.fileNotFound(path: path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw PipelineError.unreadable(path: path, underlying: error)
        }
        do {
            let file = try IPSFile.parse(data: data)
            return (file, data)
        } catch {
            throw PipelineError.parseFailed(path: path, underlying: error)
        }
    }

    // MARK: - Shared dSYM lookup

    static func referencedImageIndices(in file: IPSFile) -> Set<Int> {
        var referencedIndices = Set<Int>()
        for thread in file.payload.threads {
            for frame in thread.frames where frame.imageIndex != nil {
                referencedIndices.insert(frame.imageIndex!)
            }
        }
        if let leb = file.payload.lastExceptionBacktrace {
            for frame in leb where frame.imageIndex != nil {
                referencedIndices.insert(frame.imageIndex!)
            }
        }
        return referencedIndices
    }

    /// Locates dSYMs for every image referenced by a frame that doesn't already carry a
    /// symbol, and runs `Symbolicator` if at least one was found. Never mdfinds for images
    /// that already have symbols, or for images no frame references at all. Returns `nil`
    /// (skipping symbolication entirely) when nothing needed it or nothing was found —
    /// this is `analyze`'s dSYM step, distinct from `symbolicate`'s (see
    /// `locateDSYMs`/`symbolicateToIPSData`), which always looks up (and always
    /// symbolicates with) every referenced image regardless of pre-existing symbols.
    static func locateAndSymbolicateForAnalyze(
        file: IPSFile, ipsData: Data, dsymPaths: [URL], useSpotlight: Bool,
        searchArchives: Bool
    ) -> Symbolicator.Output? {
        let images = file.payload.usedImages
        let referencedIndices = referencedImageIndices(in: file)

        // Only look for dSYMs of images that (a) are actually referenced by a frame and
        // (b) have at least one unsymbolicated frame — no point locating a dSYM for an
        // image the OS already fully symbolicated, or one that never appears in a stack.
        // Build the image -> "has an unsymbolicated frame" map in ONE pass.
        //
        // `payload.threads` and `thread.frames` are computed properties that re-wrap every
        // underlying dictionary on each access, so reading them inside the per-image loop
        // made this O(referenced images x total frames) — a crafted 6 MB report (1,000
        // images x 100,000 frames) took over three minutes, with no flag to avoid it.
        var hasUnsymbolicatedFrame: [Int: Bool] = [:]
        for thread in file.payload.threads {
            for frame in thread.frames {
                guard let idx = frame.imageIndex else { continue }
                if frame.symbol == nil { hasUnsymbolicatedFrame[idx] = true }
                else if hasUnsymbolicatedFrame[idx] == nil { hasUnsymbolicatedFrame[idx] = false }
            }
        }
        for frame in file.payload.lastExceptionBacktrace ?? [] {
            guard let idx = frame.imageIndex else { continue }
            if frame.symbol == nil { hasUnsymbolicatedFrame[idx] = true }
            else if hasUnsymbolicatedFrame[idx] == nil { hasUnsymbolicatedFrame[idx] = false }
        }

        var needsSymbols: [(uuid: String, name: String)] = []
        for idx in referencedIndices {
            guard images.indices.contains(idx), let uuid = images[idx].uuid else { continue }
            let name = images[idx].name ?? images[idx].path ?? "image[\(idx)]"
            // An image with no frames at all is treated as fully symbolicated, matching
            // the previous `allSatisfy` over an empty list.
            guard hasUnsymbolicatedFrame[idx] == true else { continue }
            needsSymbols.append((uuid, name))
        }

        guard !needsSymbols.isEmpty else { return nil }

        let locator = DSYMLocator(options: .init(
            extraSearchPaths: dsymPaths,
            useSpotlight: useSpotlight,
            searchDefaultArchives: searchArchives
        ))

        var dsyms: [String: URL] = [:]
        var mismatched: [String: [URL]] = [:]
        for entry in needsSymbols {
            switch locator.locate(uuid: entry.uuid, binaryName: entry.name) {
            case .found(let dsymURL, _):
                dsyms[entry.uuid.lowercased()] = dsymURL
            case .uuidMismatch(let candidates):
                // A stale dSYM is never used, but it IS reported: "wrong build" and
                // "no dSYM at all" have different remedies.
                mismatched[entry.uuid.lowercased()] = candidates
            case .missing:
                continue
            }
        }

        // Still symbolicate when the only thing found was a wrong-build dSYM: that run
        // produces no symbols but DOES carry the uuid_mismatch status out to the report.
        guard !dsyms.isEmpty || !mismatched.isEmpty else { return nil }
        return try? Symbolicator(mismatchedUUIDs: mismatched).symbolicate(ipsData: ipsData, dsyms: dsyms)
    }

    /// Locates a dSYM for every image referenced by any frame (regardless of whether that
    /// image already carries symbols) — `symbolicate`'s dSYM step.
    static func locateDSYMs(
        file: IPSFile, dsymPaths: [URL], useSpotlight: Bool, searchArchives: Bool
    ) -> (dsyms: [String: URL], mismatched: [String: [URL]]) {
        let images = file.payload.usedImages
        let referencedIndices = referencedImageIndices(in: file)

        let locator = DSYMLocator(options: .init(
            extraSearchPaths: dsymPaths,
            useSpotlight: useSpotlight,
            searchDefaultArchives: searchArchives
        ))

        var dsyms: [String: URL] = [:]
        var mismatched: [String: [URL]] = [:]
        for idx in referencedIndices {
            guard images.indices.contains(idx), let uuid = images[idx].uuid else { continue }
            let name = images[idx].name ?? images[idx].path ?? "image[\(idx)]"
            switch locator.locate(uuid: uuid, binaryName: name) {
            case .found(let dsymURL, _):
                dsyms[uuid.lowercased()] = dsymURL
            case .uuidMismatch(let candidates):
                mismatched[uuid.lowercased()] = candidates
            case .missing:
                continue
            }
        }
        return (dsyms, mismatched)
    }
}
