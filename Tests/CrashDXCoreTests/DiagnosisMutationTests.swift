import Foundation
import Testing
@testable import CrashDXCore

// The cheaper interim `docs/DESIGN.md`'s "Calibration needs data" section names: no held-out
// real reports exist, so this tests against a perturbation that must not change the cause
// rather than against new ground truth.
//
// Every fixture in the corpus is single-threaded (`faultingThread == 0` in all 14), so
// reordering the existing `threads` array is a no-op — there is nothing to reorder. Instead
// this inserts an unrelated decoy thread ahead of the real one and shifts `faultingThread`
// to match, which directly exercises "no rule assumes the faulting thread sits at array
// index 0" against every extractor and rule (all of them key off
// `payload.faultingThreadIndex`, none off a hardcoded `0` — verified by reading
// Architecture.swift, MemoryFactsExtractor.swift, FrameFactsExtractor.swift,
// FrameSentinel.swift and RegisterFactsExtractor.swift before writing this test).
//
// Symbol-stripping and architecture-swapping are deliberately left out of this suite: they
// are not cause-preserving unconditionally (some rules read symbol names, and `far` doesn't
// exist on x86_64 at all per `ArchitectureTests`), so asserting invariance across the whole
// corpus for those would need a per-fixture allowlist, not a blanket check.

private func fixtureURLs() throws -> [(name: String, url: URL)] {
    var found: [(String, URL)] = []
    for subdirectory in ["Fixtures", "Fixtures/synthetic"] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "ips", subdirectory: subdirectory) ?? []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            found.append((url.deletingPathExtension().lastPathComponent, url))
        }
    }
    #expect(found.count >= 14, "fixture discovery found only \(found.count) .ips files")
    return found
}

/// Inserts an unrelated, non-crashing decoy thread ahead of the faulting one and shifts
/// `faultingThread` to match. The decoy carries no sentinel symbols, no `threadState`, and
/// references image 0 (always present) purely to give it a resolvable frame — nothing about
/// it should influence which hypotheses fire or how they score.
private func insertDecoyThreadBeforeFaultingThread(_ url: URL) throws -> IPSFile {
    var data = try Data(contentsOf: url)
    let newline = try #require(data.firstIndex(of: UInt8(ascii: "\n")))
    let headerLine = data[data.startIndex...newline]
    var payload = try #require(
        try JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any]
    )
    guard var threads = payload["threads"] as? [[String: Any]],
          let faultingThread = payload["faultingThread"] as? Int else {
        data = headerLine + (try JSONSerialization.data(withJSONObject: payload))
        return try IPSFile.parse(data: data)
    }
    let decoy: [String: Any] = [
        "triggered": false,
        "queue": "com.example.decoy-thread",
        "frames": [["imageIndex": 0, "imageOffset": 4096, "symbol": "decoyFrame()"]],
    ]
    threads.insert(decoy, at: 0)
    payload["threads"] = threads
    payload["faultingThread"] = faultingThread + 1
    data = headerLine + (try JSONSerialization.data(withJSONObject: payload))
    return try IPSFile.parse(data: data)
}

@Suite struct DiagnosisMutationTests {
    @Test func diagnosisIsInvariantUnderAnUnrelatedDecoyThread() throws {
        for (name, url) in try fixtureURLs() {
            let baseline = DiagnosisEngine().diagnose(try IPSFile.parse(contentsOf: url))
            let mutated = DiagnosisEngine().diagnose(try insertDecoyThreadBeforeFaultingThread(url))

            #expect(baseline.status == mutated.status, "\(name): status changed with a decoy thread inserted")
            #expect(baseline.verdict?.id == mutated.verdict?.id, "\(name): verdict changed with a decoy thread inserted")

            let baselineIDs = baseline.hypotheses.map(\.hypothesis.id)
            let mutatedIDs = mutated.hypotheses.map(\.hypothesis.id)
            #expect(baselineIDs == mutatedIDs, "\(name): ranking order changed with a decoy thread inserted")

            let baselineScores = baseline.hypotheses.map(\.score)
            let mutatedScores = mutated.hypotheses.map(\.score)
            #expect(baselineScores == mutatedScores, "\(name): scores changed with a decoy thread inserted")
        }
    }
}
