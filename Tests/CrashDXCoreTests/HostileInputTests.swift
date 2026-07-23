import Foundation
import Testing
@testable import CrashDXCore

// crashdx's stated job is reading crash reports that strangers emailed you, so every
// string in a report is attacker-controlled and every size in one is attacker-chosen.
// These tests cover that threat model: the engine must not be steerable into producing
// wrong output, and must not be stallable by a file of ordinary size.
//
// The rendering defence (escaping control characters before printing) lives in
// `CrashDXCore/SafeRendering.swift` and is exercised by `SafeRenderingTests.swift`.

@Suite struct HostileInputTests {
    private func payloadFixture(_ mutate: (inout [String: Any]) -> Void) throws -> IPSFile {
        let url = try #require(
            Bundle.module.url(forResource: "nullderef", withExtension: "ips", subdirectory: "Fixtures")
        )
        let data = try Data(contentsOf: url)
        let newline = try #require(data.firstIndex(of: UInt8(ascii: "\n")))
        let headerLine = data[data.startIndex...newline]
        var payload = try #require(
            try JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any]
        )
        mutate(&payload)
        return try IPSFile.parse(data: headerLine + (try JSONSerialization.data(withJSONObject: payload)))
    }

    // MARK: - Structural hostility

    /// Out-of-range, negative, and wrong-typed indices must not trap. Swift array
    /// subscripting on an attacker-supplied index is a crash, not an error.
    @Test func outOfRangeIndicesDoNotTrap() throws {
        for faulting in [99, -1, Int.max] {
            let file = try payloadFixture { $0["faultingThread"] = faulting }
            let diagnosis = DiagnosisEngine().diagnose(file)
            _ = AnalysisReport.build(from: file, symbolication: nil, tier: .full, diagnosis: diagnosis)
        }
    }

    @Test func frameImageIndexPastUsedImagesDoesNotTrap() throws {
        let file = try payloadFixture { payload in
            var threads = payload["threads"] as! [[String: Any]]
            threads[0]["frames"] = [["imageIndex": 9_999, "imageOffset": 16]]
            payload["threads"] = threads
        }
        let diagnosis = DiagnosisEngine().diagnose(file)
        let report = AnalysisReport.build(from: file, symbolication: nil, tier: .full, diagnosis: diagnosis)
        #expect(report.faultingThread?.frames.count == 1)
    }

    /// Type confusion: a field the code reads as an array arriving as an object, and
    /// vice versa. These must degrade to "absent", never crash.
    @Test func typeConfusedFieldsDegradeGracefully() throws {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("threads as object", { $0["threads"] = ["a": 1] }),
            ("threads as scalars", { $0["threads"] = [1, 2, 3] }),
            ("usedImages as strings", { $0["usedImages"] = ["a", "b"] }),
            ("exception as string", { $0["exception"] = "boom" }),
            ("leb as object", { $0["lastExceptionBacktrace"] = ["a": 1] }),
            ("asi as string", { $0["asi"] = "text" }),
            ("vmregioninfo as int", { $0["vmregioninfo"] = 5 }),
            ("empty threads", { $0["threads"] = [] }),
            ("empty usedImages", { $0["usedImages"] = [] }),
        ]
        for (label, mutate) in mutations {
            let file = try payloadFixture(mutate)
            let diagnosis = DiagnosisEngine().diagnose(file)
            let report = AnalysisReport.build(from: file, symbolication: nil, tier: .full, diagnosis: diagnosis)
            #expect(report.schemaVersion == AnalysisReport.currentSchemaVersion, "\(label)")
        }
    }

    /// A hostile report must never make the engine assert facts it has no basis for.
    @Test func emptyPayloadYieldsNoInventedDiagnosis() throws {
        let file = try payloadFixture { payload in
            for key in ["exception", "termination", "threads", "usedImages",
                        "asi", "vmregioninfo", "lastExceptionBacktrace"] {
                payload.removeValue(forKey: key)
            }
        }
        let diagnosis = DiagnosisEngine().diagnose(file)
        #expect(diagnosis.status == .inconclusive)
        #expect(diagnosis.verdict == nil)
        #expect(diagnosis.hypotheses.isEmpty)
    }

    // MARK: - Resource exhaustion

    /// Regression: analysis cost must stay linear in total frames, not
    /// O(images x frames). A crafted report of ordinary size (1,000 images x 40,000
    /// frames) used to take minutes because the per-image scan re-wrapped every backing
    /// dictionary on each access, and no flag could avoid it.
    ///
    /// The bound is deliberately loose — this asserts "not quadratic", not a benchmark.
    /// The sibling of `manyImagesTimesManyFramesStaysLinear`, guarding the OTHER
    /// quadratic scan — the one in `AnalyzePipeline`'s dSYM-need detection.
    ///
    /// That fix had no coverage at all: reverting it left the whole suite green while a
    /// crafted report took 38s instead of 0.1s, because the other perf test only
    /// exercises `DiagnosisEngine` + `AnalysisReport.build` and never enters the pipeline.
    /// Runs with Spotlight and archive search off so this measures crashdx's own work,
    /// not the filesystem's.
    @Test func analyzePipelineStaysLinearOnManyImages() throws {
        let imageCount = 1_000
        let frameCount = 40_000
        let file = try payloadFixture { payload in
            payload["usedImages"] = (0..<imageCount).map { i -> [String: Any] in
                ["name": "img\(i)", "arch": "arm64",
                 "uuid": String(format: "%08x-0000-0000-0000-000000000000", i)]
            }
            payload["threads"] = [[
                "triggered": true,
                "frames": (0..<frameCount).map { j -> [String: Any] in
                    ["imageIndex": j % imageCount, "imageOffset": 100 + j]
                },
            ]]
            payload["faultingThread"] = 0
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-linear-\(UUID().uuidString).ips")
        let headerData = try JSONSerialization.data(withJSONObject: file.header.raw)
        let payloadData = try JSONSerialization.data(withJSONObject: file.payload.raw)
        try (headerData + Data("\n".utf8) + payloadData).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let started = Date()
        _ = try AnalyzePipeline.analyze(
            path: url.path, tier: .summary, dsymPaths: [],
            useSpotlight: false, searchArchives: false
        )
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 20, "AnalyzePipeline took \(elapsed)s — the quadratic scan is back")
    }

    @Test func manyImagesTimesManyFramesStaysLinear() throws {
        let imageCount = 1_000
        let frameCount = 40_000
        let file = try payloadFixture { payload in
            payload["usedImages"] = (0..<imageCount).map { i -> [String: Any] in
                ["name": "img\(i)", "arch": "arm64",
                 "uuid": String(format: "%08x-0000-0000-0000-000000000000", i)]
            }
            payload["threads"] = [[
                "triggered": true,
                "frames": (0..<frameCount).map { j -> [String: Any] in
                    ["imageIndex": j % imageCount, "imageOffset": 100 + j]
                },
            ]]
            payload["faultingThread"] = 0
        }

        let started = Date()
        let diagnosis = DiagnosisEngine().diagnose(file)
        _ = AnalysisReport.build(from: file, symbolication: nil, tier: .full, diagnosis: diagnosis)
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 20, "report building took \(elapsed)s — the quadratic scan is back")
    }
}
