import Foundation
import Testing
@testable import CrashDXCore

// Ground truth: corpus/fixtures/crashspike/crashspike.dSYM, copied into Fixtures/, has
// UUID 657A6675-2D2C-32CA-8C31-3A8C948DF5FE (arm64) with its DWARF file at
// Contents/Resources/DWARF/crashspike. See corpus/README.md.

private let crashspikeUUID = "657A6675-2D2C-32CA-8C31-3A8C948DF5FE"
// Valid UUID format, but not the crashspike fixture's UUID.
private let otherUUID = "00000000-0000-0000-0000-000000000000"

@Suite struct DSYMLocatorTests {
    private func fixtureDSYM() throws -> URL {
        let url = Bundle.module.url(forResource: "crashspike", withExtension: "dSYM", subdirectory: "Fixtures")
        return try #require(url)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSYMLocatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func findsDSYMByUUIDCaseInsensitively() throws {
        let searchDir = try makeTempDir()
        let fixture = try fixtureDSYM()
        let destination = searchDir.appendingPathComponent("crashspike.dSYM")
        try FileManager.default.copyItem(at: fixture, to: destination)

        let locator = DSYMLocator(options: .init(
            extraSearchPaths: [searchDir],
            useSpotlight: false,
            searchDefaultArchives: false
        ))

        let result = locator.locate(uuid: crashspikeUUID.lowercased(), binaryName: "crashspike")

        guard case .found(let dsymURL, let dwarfURL) = result else {
            Issue.record("expected .found, got \(result)")
            return
        }
        #expect(dsymURL.standardizedFileURL == destination.standardizedFileURL)
        #expect(dwarfURL.lastPathComponent == "crashspike")
        #expect(dwarfURL.path.hasSuffix("Contents/Resources/DWARF/crashspike"))
    }

    /// A search path may BE the `.dSYM` bundle rather than a directory containing one —
    /// the most natural thing to pass to `--dsym`. Enumerating inside a `.dSYM` finds no
    /// nested `.dSYM`, so this used to fail silently and produce unsymbolicated output.
    @Test func acceptsSearchPathThatIsItselfADSYMBundle() throws {
        let searchDir = try makeTempDir()
        let fixture = try fixtureDSYM()
        let destination = searchDir.appendingPathComponent("crashspike.dSYM")
        try FileManager.default.copyItem(at: fixture, to: destination)

        // Point directly AT the bundle, not at its parent directory.
        let locator = DSYMLocator(options: .init(
            extraSearchPaths: [destination],
            useSpotlight: false,
            searchDefaultArchives: false
        ))

        let result = locator.locate(uuid: crashspikeUUID, binaryName: "crashspike")

        guard case .found(let dsymURL, let dwarfURL) = result else {
            Issue.record("expected .found when --dsym points at the bundle itself, got \(result)")
            return
        }
        #expect(dsymURL.standardizedFileURL == destination.standardizedFileURL)
        #expect(dwarfURL.path.hasSuffix("Contents/Resources/DWARF/crashspike"))
    }

    /// `dwarfURL` must pick the DWARF file named after the bundle, even when the bundle
    /// name contains dots. Bundle-ID-named dSYMs (`com.example.Foo.dSYM`) are the norm for
    /// app extensions — this repo's own corpus contains one. An earlier implementation
    /// stripped every dot-separated component, reducing that to `com`, so it never matched
    /// and silently fell back to whatever the directory listing happened to return first.
    @Test func dwarfURLPicksBundleNamedEntryForDottedBundleNames() throws {
        // (dSYM bundle name, the DWARF file dsymutil puts inside it). For an app bundle
        // the DWARF is named after the EXECUTABLE, so `Foo.app.dSYM` contains `Foo`;
        // for a bundle-ID-named binary or a versioned dylib it keeps every dot.
        let cases = [
            ("com.example.crashspike.dSYM", "com.example.crashspike"),
            ("Foo.app.dSYM", "Foo"),
            ("libFoo.1.2.dylib.dSYM", "libFoo.1.2.dylib"),
            ("Plain.dSYM", "Plain"),
        ]
        for (bundle, dwarfName) in cases {
            let dir = try makeTempDir()
            let dsym = dir.appendingPathComponent(bundle)
            let dwarfDir = dsym.appendingPathComponent("Contents/Resources/DWARF")
            try FileManager.default.createDirectory(at: dwarfDir, withIntermediateDirectories: true)
            // A stray file that sorts BEFORE the real one, so `contents.first` is wrong.
            try Data("stray".utf8).write(to: dwarfDir.appendingPathComponent("AAA_stray"))
            try Data("real".utf8).write(to: dwarfDir.appendingPathComponent(dwarfName))

            let picked = DSYMLocator.dwarfURL(inDSYM: dsym)
            #expect(
                picked?.lastPathComponent == dwarfName,
                "\(bundle) picked \(picked?.lastPathComponent ?? "<nil>"), expected \(dwarfName)"
            )
        }
    }

    /// Extension matching must be case-insensitive on every route, including the Spotlight
    /// one — a case-variant archive used to yield no dSYMs there while `--dsym` found them.
    @Test func xcarchiveExtensionMatchingIsCaseInsensitive() throws {
        let dir = try makeTempDir()
        let archive = dir.appendingPathComponent("Fake.XCARCHIVE")
        let dsymsDir = archive.appendingPathComponent("dSYMs")
        try FileManager.default.createDirectory(at: dsymsDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: try fixtureDSYM(), to: dsymsDir.appendingPathComponent("crashspike.dSYM")
        )

        #expect(!DSYMLocator.dsymBundles(fromMDFindHit: archive).isEmpty)
        #expect(!DSYMLocator.findDSYMBundles(under: archive).isEmpty)
    }

    /// `dwarfdump --uuid <bundle>` recurses into the bundle and aborts on the first
    /// unrecognized file — a `.DS_Store` that Finder creates merely by opening the dSYM is
    /// enough to make it exit 1 with EMPTY stdout. Parsing that into an empty UUID set
    /// made `verify` answer `.mismatch`, i.e. crashdx reported a perfectly good dSYM as
    /// belonging to a different build and sent the user hunting for an archive that does
    /// not exist. "Failed and told us nothing" must be UNREADABLE, not "no match".
    ///
    /// Note the guard cannot be `exitCode != 0` alone: dwarfdump also exits non-zero
    /// AFTER printing good UUIDs when it trips over a stray file later in the walk, and
    /// those UUIDs are valid.
    @Test func failedDwarfdumpIsUnreadableNotAMismatch() throws {
        let searchDir = try makeTempDir()
        let destination = searchDir.appendingPathComponent("crashspike.dSYM")
        try FileManager.default.copyItem(at: try fixtureDSYM(), to: destination)

        // Poison the bundle exactly the way Finder does.
        let dwarfDir = destination.appendingPathComponent("Contents/Resources/DWARF")
        try Data().write(to: dwarfDir.appendingPathComponent(".DS_Store"))

        #expect(DSYMLocator.dwarfdumpUUIDs(dsymURL: destination) == nil,
                "a failed dwarfdump with no output must be nil (unreadable), not an empty set")

        // And end-to-end: the correct UUID must NOT come back as a wrong-build mismatch.
        let locator = DSYMLocator(options: .init(
            extraSearchPaths: [searchDir], useSpotlight: false, searchDefaultArchives: false
        ))
        if case .uuidMismatch = locator.locate(uuid: crashspikeUUID, binaryName: "crashspike") {
            Issue.record("a good dSYM was reported as belonging to a different build")
        }
    }

    @Test func mismatchedUUIDIsNotReportedAsFound() throws {
        let searchDir = try makeTempDir()
        let fixture = try fixtureDSYM()
        let destination = searchDir.appendingPathComponent("crashspike.dSYM")
        try FileManager.default.copyItem(at: fixture, to: destination)

        let locator = DSYMLocator(options: .init(
            extraSearchPaths: [searchDir],
            useSpotlight: false,
            searchDefaultArchives: false
        ))

        let result = locator.locate(uuid: otherUUID, binaryName: "crashspike")

        switch result {
        case .found:
            Issue.record("must never report .found for a mismatched UUID")
        case .uuidMismatch(let candidates):
            #expect(candidates.contains { $0.standardizedFileURL == destination.standardizedFileURL })
        case .missing:
            Issue.record("a same-named dSYM with a wrong UUID must report .uuidMismatch")
        }
    }

    /// A UUID mismatch must be reported ONLY for dSYMs belonging to the image being
    /// looked up. Without this filter, scanning a shared search root (e.g. the whole
    /// Xcode Archives tree) reports every unrelated project's dSYM as a "mismatch" —
    /// useless as a diagnostic, and it leaks the paths of the user's other projects into
    /// report output.
    @Test func uuidMismatchIgnoresDSYMsForOtherBinaries() throws {
        let searchDir = try makeTempDir()
        // A dSYM whose DWARF binary is named "crashspike"...
        try FileManager.default.copyItem(
            at: try fixtureDSYM(), to: searchDir.appendingPathComponent("crashspike.dSYM")
        )

        // ...is irrelevant to a lookup for a DIFFERENT image, even though its UUID
        // also fails to match.
        let locator = DSYMLocator(options: .init(
            extraSearchPaths: [searchDir],
            useSpotlight: false,
            searchDefaultArchives: false
        ))

        let result = locator.locate(uuid: otherUUID, binaryName: "SomeOtherApp")

        guard case .missing = result else {
            Issue.record("expected .missing for an unrelated binary name, got \(result)")
            return
        }
    }

    @Test func descendsIntoXcarchiveDSYMs() throws {
        let searchDir = try makeTempDir()
        let fixture = try fixtureDSYM()
        let dsymsDir = searchDir
            .appendingPathComponent("Fake.xcarchive")
            .appendingPathComponent("dSYMs")
        try FileManager.default.createDirectory(at: dsymsDir, withIntermediateDirectories: true)
        let destination = dsymsDir.appendingPathComponent("crashspike.dSYM")
        try FileManager.default.copyItem(at: fixture, to: destination)

        let locator = DSYMLocator(options: .init(
            extraSearchPaths: [searchDir],
            useSpotlight: false,
            searchDefaultArchives: false
        ))

        let result = locator.locate(uuid: crashspikeUUID, binaryName: "crashspike")

        guard case .found(let dsymURL, let dwarfURL) = result else {
            Issue.record("expected .found, got \(result)")
            return
        }
        #expect(dsymURL.standardizedFileURL == destination.standardizedFileURL)
        #expect(dwarfURL.lastPathComponent == "crashspike")
    }

    @Test func missingReportsSearchedLocations() throws {
        let searchDir = try makeTempDir()

        let locator = DSYMLocator(options: .init(
            extraSearchPaths: [searchDir],
            useSpotlight: false,
            searchDefaultArchives: false
        ))

        let result = locator.locate(uuid: crashspikeUUID, binaryName: "crashspike")

        guard case .missing(let searched) = result else {
            Issue.record("expected .missing, got \(result)")
            return
        }
        #expect(searched.contains(searchDir.path))
    }
}
