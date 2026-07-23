import Foundation

/// Locates a dSYM bundle for a crashed binary given its build UUID, searching
/// caller-supplied paths, Spotlight's dSYM index, and Xcode's default archive location.
///
/// Every candidate is UUID-verified via `dwarfdump --uuid` before being returned as
/// `.found` — a name match with a mismatched UUID is reported as `.uuidMismatch`, never
/// silently accepted, since a stale dSYM produces confidently wrong symbolication.
public struct DSYMLocator: Sendable {
    public struct Options: Sendable {
        /// Searched recursively (for `*.dSYM` and `*.xcarchive/dSYMs/*.dSYM`) before Spotlight.
        public var extraSearchPaths: [URL]
        /// Shells out to `mdfind`; tests must set this to `false`.
        public var useSpotlight: Bool
        /// Scans `~/Library/Developer/Xcode/Archives`; tests must set this to `false`.
        public var searchDefaultArchives: Bool

        public init(
            extraSearchPaths: [URL] = [],
            useSpotlight: Bool = true,
            searchDefaultArchives: Bool = true
        ) {
            self.extraSearchPaths = extraSearchPaths
            self.useSpotlight = useSpotlight
            self.searchDefaultArchives = searchDefaultArchives
        }
    }

    public enum Result: Sendable {
        case found(dsymURL: URL, dwarfURL: URL)
        /// A dSYM matching `binaryName` was found but its UUID didn't match.
        case uuidMismatch(candidates: [URL])
        /// Nothing matched; `searched` lists every location checked, for diagnostics.
        case missing(searched: [String])
    }

    private let options: Options

    public init(options: Options) {
        self.options = options
    }

    /// `uuid` is case-insensitive; `binaryName` is the image's `name` from the crash report.
    public func locate(uuid: String, binaryName: String) -> Result {
        let normalizedUUID = uuid.uppercased()
        var searched: [String] = []
        var mismatches: [URL] = []

        /// A UUID mismatch is only *interesting* for a dSYM that actually belongs to this
        /// image — i.e. one whose DWARF binary carries the same name. Without this filter
        /// every unrelated dSYM under a search root (a whole `~/Library/Developer/Xcode/
        /// Archives` tree, say) is recorded as a "mismatch", which is both useless as a
        /// diagnostic and a privacy problem: those paths name the user's other projects
        /// and get surfaced in report output.
        func isForThisBinary(_ candidate: URL) -> Bool {
            guard let dwarf = Self.dwarfURL(inDSYM: candidate) else { return false }
            // `binaryName` is documented as the image's `name`, but callers legitimately
            // fall back to the image's full `path` when `name` is absent — so compare
            // basenames, or every mismatch for such an image is silently discarded.
            let wanted = (binaryName as NSString).lastPathComponent
            return dwarf.lastPathComponent.compare(wanted, options: .caseInsensitive) == .orderedSame
        }

        func noteMismatch(_ candidate: URL) {
            if isForThisBinary(candidate) { mismatches.append(candidate) }
        }

        // 1. Extra search paths (recursive).
        for base in options.extraSearchPaths {
            searched.append(base.path)
            for candidate in Self.findDSYMBundles(under: base) {
                switch verify(candidate, uuid: normalizedUUID) {
                case .match:
                    return found(dsymURL: candidate)
                case .mismatch:
                    noteMismatch(candidate)
                case .unreadable:
                    continue
                }
            }
        }

        // 2. Spotlight.
        if options.useSpotlight {
            searched.append("Spotlight (mdfind com_apple_xcode_dsym_uuids)")
            for hit in Self.mdfindDSYMs(uuid: normalizedUUID) {
                for candidate in Self.dsymBundles(fromMDFindHit: hit) {
                    switch verify(candidate, uuid: normalizedUUID) {
                    case .match:
                        return found(dsymURL: candidate)
                    case .mismatch:
                        noteMismatch(candidate)
                    case .unreadable:
                        continue
                    }
                }
            }
        }

        // 3. Default Xcode archives location.
        if options.searchDefaultArchives {
            let archivesDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/Archives")
            searched.append(archivesDir.path)
            for candidate in Self.findDSYMBundles(under: archivesDir) {
                switch verify(candidate, uuid: normalizedUUID) {
                case .match:
                    return found(dsymURL: candidate)
                case .mismatch:
                    noteMismatch(candidate)
                case .unreadable:
                    continue
                }
            }
        }

        if !mismatches.isEmpty {
            return .uuidMismatch(candidates: mismatches)
        }
        return .missing(searched: searched)
    }

    private func found(dsymURL: URL) -> Result {
        .found(dsymURL: dsymURL, dwarfURL: Self.dwarfURL(inDSYM: dsymURL) ?? dsymURL)
    }

    // MARK: - UUID verification

    private enum Verification {
        case match
        case mismatch
        case unreadable
    }

    private func verify(_ dsymURL: URL, uuid: String) -> Verification {
        guard let uuids = Self.dwarfdumpUUIDs(dsymURL: dsymURL) else { return .unreadable }
        return uuids.contains(uuid) ? .match : .mismatch
    }

    /// Runs `dwarfdump --uuid <dSYM>` and parses lines of the form
    /// `UUID: 657A6675-2D2C-32CA-8C31-3A8C948DF5FE (arm64) <path>`.
    static func dwarfdumpUUIDs(dsymURL: URL) -> Set<String>? {
        let dwarfdumpPath = "/usr/bin/dwarfdump"
        let executableURL: URL
        let arguments: [String]
        if FileManager.default.isExecutableFile(atPath: dwarfdumpPath) {
            executableURL = URL(fileURLWithPath: dwarfdumpPath)
            arguments = ["--uuid", dsymURL.path]
        } else {
            executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            arguments = ["dwarfdump", "--uuid", dsymURL.path]
        }

        guard let run = Subprocess.run(executable: executableURL, arguments: arguments) else {
            return nil
        }
        guard let output = String(data: run.stdout, encoding: .utf8) else { return nil }

        var uuids = Set<String>()
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("UUID:") else { continue }
            let rest = line.dropFirst("UUID:".count).trimmingCharacters(in: .whitespaces)
            guard let firstSpace = rest.firstIndex(of: " ") else { continue }
            let token = String(rest[rest.startIndex..<firstSpace])
            if Self.looksLikeUUID(token) {
                uuids.insert(token.uppercased())
            }
        }

        // "dwarfdump failed AND told us nothing" is UNREADABLE, not "no UUIDs" — and the
        // difference matters enormously: an empty set makes `verify` answer `.mismatch`,
        // which reports a perfectly good dSYM as belonging to a different build and sends
        // the user hunting for an archive that doesn't exist.
        //
        // This is reachable in practice: `dwarfdump --uuid <bundle>` recurses into the
        // bundle and aborts on the first unrecognized file, so a `.DS_Store` that Finder
        // creates merely by opening the dSYM is enough to produce exit 1 with empty
        // stdout. Exit status alone isn't the test — dwarfdump also exits non-zero after
        // successfully printing UUIDs when it trips over a stray file later in the walk,
        // and those UUIDs are good.
        if uuids.isEmpty && run.exitCode != 0 {
            return nil
        }
        return uuids
    }

    private static func looksLikeUUID(_ s: String) -> Bool {
        UUID(uuidString: s) != nil
    }

    // MARK: - Filesystem search

    /// Recursively finds `*.dSYM` bundles under `base`, including those nested inside
    /// `*.xcarchive/dSYMs/`.
    ///
    /// `base` may also BE the artifact rather than a directory to search: pointing at a
    /// `.dSYM` bundle (or an `.xcarchive`) directly is what a user naturally does with
    /// `--dsym`, and enumerating *inside* a `.dSYM` finds nothing, so that used to fail
    /// silently and yield unsymbolicated output. Both forms are accepted.
    static func findDSYMBundles(under base: URL) -> [URL] {
        if base.pathExtension.caseInsensitiveCompare("dSYM") == .orderedSame {
            return [base]
        }
        if base.pathExtension.caseInsensitiveCompare("xcarchive") == .orderedSame {
            return dsymBundles(inDSYMsDir: base.appendingPathComponent("dSYMs"))
        }

        var results: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            if url.pathExtension.caseInsensitiveCompare("dSYM") == .orderedSame {
                results.append(url)
                enumerator.skipDescendants()
            } else if url.pathExtension.caseInsensitiveCompare("xcarchive") == .orderedSame {
                let dsymsDir = url.appendingPathComponent("dSYMs")
                results.append(contentsOf: dsymBundles(inDSYMsDir: dsymsDir))
                enumerator.skipDescendants()
            }
        }
        return results
    }

    private static func dsymBundles(inDSYMsDir dsymsDir: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dsymsDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents.filter { $0.pathExtension.caseInsensitiveCompare("dSYM") == .orderedSame }
    }

    /// Turns an mdfind hit (which may itself be a `.dSYM`, or an `.xcarchive` whose
    /// `dSYMs/` subdirectory holds the real bundle) into candidate dSYM bundle URLs.
    static func dsymBundles(fromMDFindHit hit: URL) -> [URL] {
        if hit.pathExtension.caseInsensitiveCompare("dSYM") == .orderedSame {
            return [hit]
        }
        if hit.pathExtension.caseInsensitiveCompare("xcarchive") == .orderedSame {
            return dsymBundles(inDSYMsDir: hit.appendingPathComponent("dSYMs"))
        }
        return []
    }

    /// The DWARF binary inside a dSYM bundle's `Contents/Resources/DWARF/` directory.
    ///
    /// Skips hidden files and prefers the entry named after the bundle: the directory
    /// listing is unordered, and a stray `.DS_Store` (which Finder creates just by opening
    /// the bundle) would otherwise be returned as "the" DWARF file — feeding a junk path
    /// to `dwarfdump`/`atos` and making UUID verification fail for a perfectly good dSYM.
    static func dwarfURL(inDSYM dsymURL: URL) -> URL? {
        let dwarfDir = dsymURL.appendingPathComponent("Contents/Resources/DWARF")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dwarfDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }

        // `Foo.dSYM` -> `Foo`; `Foo.app.dSYM` -> `Foo`; `com.example.Foo.dSYM` ->
        // `com.example.Foo`. Strip only the `.dSYM` suffix and, if what remains ends in a
        // known bundle extension, that too. A previous version looped until no dots
        // remained, which reduced every bundle-ID-named dSYM (the norm for app
        // extensions) to `com` and so never matched its own DWARF file.
        var expected = (dsymURL.lastPathComponent as NSString).deletingPathExtension
        for bundleExt in [".app", ".framework", ".appex", ".xctest", ".bundle"]
        where expected.hasSuffix(bundleExt) {
            expected = String(expected.dropLast(bundleExt.count))
            break
        }
        return contents.first { $0.lastPathComponent == expected } ?? contents.first
    }

    // MARK: - Spotlight

    /// Runs `mdfind "com_apple_xcode_dsym_uuids == <UUID>"`. UUID must be uppercase
    /// 8-4-4-4-12.
    static func mdfindDSYMs(uuid: String) -> [URL] {
        guard let run = Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/mdfind"),
            arguments: ["com_apple_xcode_dsym_uuids == \(uuid)"]
        ), let output = String(data: run.stdout, encoding: .utf8) else { return [] }

        return output.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}
