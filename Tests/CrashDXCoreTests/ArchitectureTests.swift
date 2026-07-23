import Foundation
import Testing
@testable import CrashDXCore

// Every fixture in this repo is arm64, which let two architecture assumptions live in the
// engine unnoticed: a hardcoded 16 KB page size, and register lookups by the ARM names
// far/pc/lr/sp. On an x86_64 report the ARM register names simply don't exist, so all
// register corroboration vanished — and a genuine stack overflow came back as "wild
// pointer or use-after-free", which is a WRONG answer rather than an honest silence.

@Suite struct ArchitectureTests {
    private func fixture(_ mutate: (inout [String: Any]) -> Void) throws -> IPSFile {
        let url = try #require(Bundle.module.url(
            forResource: "nullderef", withExtension: "ips", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let newline = try #require(data.firstIndex(of: UInt8(ascii: "\n")))
        let header = data[data.startIndex...newline]
        var payload = try #require(
            try JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any]
        )
        mutate(&payload)
        return try IPSFile.parse(data: header + (try JSONSerialization.data(withJSONObject: payload)))
    }

    /// An x86_64 report where the fault is just below the stack pointer and there is no
    /// `vmregioninfo` — the shape where the ARM-only register lookup used to lose the
    /// stack-overflow hypothesis entirely.
    private func intelStackOverflow() throws -> IPSFile {
        let sp = 140_732_920_755_712
        return try fixture { payload in
            payload["cpuType"] = "X86-64"
            payload["usedImages"] = [["name": "app", "arch": "x86_64",
                                      "uuid": "00000000-0000-0000-0000-000000000000"]]
            payload.removeValue(forKey: "vmregioninfo")
            payload["exception"] = [
                "type": "EXC_BAD_ACCESS", "signal": "SIGSEGV",
                "codes": "0x1, 0x0", "rawCodes": [1, sp - 16],
                "subtype": "KERN_INVALID_ADDRESS at 0x\(String(sp - 16, radix: 16))",
            ]
            payload["faultingThread"] = 0
            payload["threads"] = [[
                "triggered": true,
                "threadState": ["flavor": "x86_THREAD_STATE",
                                "rsp": ["value": sp], "rip": ["value": 4_295_000_000],
                                "rbp": ["value": sp + 64]],
                "frames": (0..<40).map { ["imageIndex": 0, "imageOffset": 100 + $0,
                                          "symbol": "Node.walk(_:)"] as [String: Any] },
            ]]
        }
    }

    @Test func detectsArchitectureFromCPUTypeFlavorAndImages() throws {
        #expect(Architecture.detect(in: try fixture { $0["cpuType"] = "X86-64" }.payload) == .x86_64)
        #expect(Architecture.detect(in: try fixture { $0["cpuType"] = "ARM-64" }.payload) == .arm64)

        // Falls back to the thread-state flavor when cpuType is absent.
        let byFlavor = try fixture { payload in
            payload.removeValue(forKey: "cpuType")
            payload["faultingThread"] = 0
            payload["threads"] = [["triggered": true,
                                   "threadState": ["flavor": "x86_THREAD_STATE"], "frames": []]]
        }
        #expect(Architecture.detect(in: byFlavor.payload) == .x86_64)
    }

    @Test func pageSizeMatchesTheArchitecture() {
        #expect(Architecture.arm64.pageSize == 16384)
        #expect(Architecture.x86_64.pageSize == 4096)
        // Undetermined stays conservative: a too-small window declines to claim a null
        // dereference, which is a missed answer rather than a wrong one.
        #expect(Architecture.unknown.pageSize == 4096)
    }

    /// The wrong-answer window: 0x1000–0x3FFF is inside arm64's null page but NOT inside
    /// x86_64's, so a hardcoded 16 KB cutoff claimed "nil + field offset" for an address
    /// four pages past the null page on Intel.
    @Test func nullPageClassificationRespectsTheArchitecture() throws {
        func nullPageFires(cpuType: String, address: Int) throws -> Bool {
            let file = try fixture { payload in
                payload["cpuType"] = cpuType
                payload["exception"] = [
                    "type": "EXC_BAD_ACCESS", "signal": "SIGSEGV",
                    "codes": "0x1, 0x0", "rawCodes": [1, address],
                    "subtype": "KERN_INVALID_ADDRESS at 0x\(String(address, radix: 16))",
                ]
            }
            return MemoryFactsExtractor().extract(from: file)
                .contains { $0.id == "memory.fault-address-null-page" }
        }

        #expect(try nullPageFires(cpuType: "ARM-64", address: 0x1200))
        #expect(try !nullPageFires(cpuType: "X86-64", address: 0x1200))
        // Genuinely inside the null page on both.
        #expect(try nullPageFires(cpuType: "ARM-64", address: 0x10))
        #expect(try nullPageFires(cpuType: "X86-64", address: 0x10))
    }

    /// The cited evidence must describe the machine the crash came from. A statement
    /// reading "arm64 page size" on an x86_64 report is a checkable claim that is false —
    /// worse than no claim, given the project promises every fact is verifiable.
    @Test func evidenceTextNamesTheReportsOwnArchitecture() throws {
        let file = try fixture { payload in
            payload["cpuType"] = "X86-64"
            payload["exception"] = [
                "type": "EXC_BAD_ACCESS", "signal": "SIGSEGV",
                "codes": "0x1, 0x0", "rawCodes": [1, 0x10],
                "subtype": "KERN_INVALID_ADDRESS at 0x10",
            ]
        }
        let statement = try #require(
            MemoryFactsExtractor().extract(from: file)
                .first { $0.id == "memory.fault-address-null-page" }?.statement
        )
        #expect(statement.contains("x86_64"))
        #expect(!statement.contains("arm64"))
    }

    @Test func x86RegistersAreExtractedAndArmNamesAreNotProbed() throws {
        let facts = RegisterFactsExtractor().extract(from: try intelStackOverflow())
        let ids = Set(facts.map(\.id))
        #expect(ids.contains("registers.pc"))    // rip
        #expect(ids.contains("registers.sp"))    // rsp
        #expect(!ids.contains("registers.far"))  // no such register on x86_64
        #expect(facts.contains { $0.statement.contains("rip") })
    }

    /// The regression that matters: same crash, different architecture. Before this,
    /// x86_64 lost stack-overflow entirely and offered use-after-free advice instead.
    @Test func intelStackOverflowIsNotRelabelledAsUseAfterFree() throws {
        let diagnosis = DiagnosisEngine().diagnose(try intelStackOverflow())
        let ids = diagnosis.hypotheses.map(\.hypothesis.id)
        #expect(ids.contains("stack-overflow"), "stack-overflow missing on x86_64: \(ids)")

        let stack = try #require(diagnosis.hypotheses.first { $0.hypothesis.id == "stack-overflow" })
        if let wild = diagnosis.hypotheses.first(where: { $0.hypothesis.id == "wild-or-uaf-address" }) {
            #expect(stack.score > wild.score,
                    "use-after-free must not outrank a stack overflow with 40 recursive frames")
        }
    }
}
