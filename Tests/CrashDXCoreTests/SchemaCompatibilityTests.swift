import Foundation
import Testing
@testable import CrashDXCore

// A consumer decodes `AnalysisReport` from another process's output, so the schema is a
// shipped contract. Every published enum used to be a bare String-raw-value enum, which
// meant ONE unrecognised value threw `dataCorrupted` and destroyed the entire report —
// the consumer lost the verdict, the hypotheses, everything, over a field they may never
// read. It also meant crashdx could never add a symbolication outcome or a tier without
// breaking every deployed consumer. Only fixable before 1.0, hence these tests.

@Suite struct SchemaCompatibilityTests {
    private func report(tier: AnalysisReport.Tier = .standard) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "nullderef", withExtension: "ips", subdirectory: "Fixtures"))
        let file = try IPSFile.parse(contentsOf: url)
        let diagnosis = DiagnosisEngine().diagnose(file)
        let built = AnalysisReport.build(from: file, symbolication: nil, tier: tier, diagnosis: diagnosis)
        return try JSONEncoder().encode(built)
    }

    private func mutated(_ transform: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(
            try JSONSerialization.jsonObject(with: try report()) as? [String: Any])
        transform(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func unknownTierStillDecodesTheWholeReport() throws {
        let data = try mutated { $0["tier"] = "verbose" }
        let decoded = try JSONDecoder().decode(AnalysisReport.self, from: data)
        #expect(decoded.tier == .unrecognised)
        // The point: everything else survives.
        #expect(decoded.diagnosis.verdict?.id == "null-dereference")
        #expect(decoded.process.name == "nullderef")
    }

    @Test func unknownImageStatusStillDecodesTheWholeReport() throws {
        let data = try mutated { object in
            var images = (object["images"] as? [[String: Any]]) ?? []
            guard !images.isEmpty else { return }
            images[0]["status"] = "partially_symbolicated"
            object["images"] = images
        }
        let decoded = try JSONDecoder().decode(AnalysisReport.self, from: data)
        #expect(decoded.diagnosis.verdict?.id == "null-dereference")
        #expect(decoded.images?.first?.status == .unrecognised)
    }

    @Test func unknownSymbolicationOutcomeStillDecodesTheWholeReport() throws {
        // Hand-built rather than mutated: `symbolication` is nil for these fixtures, and
        // this is the exact field a future crashdx is most likely to widen.
        let json = """
        {"schemaVersion":"0.2","tier":"standard",
         "process":{},"event":{},
         "symbolication":{"engine":"atos","images":[
             {"imageName":"app","outcome":"dsym_stripped","reason":"from a newer crashdx"}]},
         "diagnosis":{"status":"inconclusive","hypotheses":[]}}
        """
        let decoded = try JSONDecoder().decode(AnalysisReport.self, from: Data(json.utf8))
        #expect(decoded.symbolication?.images.first?.outcome == .unrecognised)
        #expect(decoded.symbolication?.images.first?.reason == "from a newer crashdx")
        #expect(decoded.tier == .standard)
    }

    /// Known values must keep decoding exactly as before — lenience must not blur them.
    @Test func knownValuesAreUnaffected() throws {
        let decoded = try JSONDecoder().decode(AnalysisReport.self, from: try report())
        #expect(decoded.tier == .standard)
        #expect(decoded.images?.allSatisfy { $0.status != .unrecognised } == true)
    }
}
