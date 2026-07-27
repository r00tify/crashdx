import Foundation

/// `far`/`pc`/`lr` from the faulting thread's `threadState` (ARM64/`ARM_THREAD_STATE64`).
/// `far` is cited only by `NullDereferenceRule`, and only at weight 0: `far.value` was
/// observed to equal `exception.subtype`'s parsed address exactly in both real
/// `EXC_BAD_ACCESS` samples examined, so it is a re-read of the same number, not an
/// independent observation. It stays in `supporting` for evidence-citation visibility but
/// earns no score — see `NullDereferenceRule`'s doc comment and `docs/DESIGN.md`'s "Known
/// limits of the additive model". `pc`/`lr` are extracted but not currently cited by any
/// rule; no rule should guard on a `registers.*` fact alone regardless.
///
/// GROUND TRUTH (verified against real corpus/raw/contactsd + corpus/fixtures/
/// nullderef `threadState`): `far`/`pc`/`lr`/`sp`/`fp` are each `{"value": N}` with N a
/// DECIMAL integer (not a hex string).
struct RegisterFactsExtractor: EvidenceExtractor {
    init() {}

    func extract(from file: IPSFile) -> [Fact] {
        var facts: [Fact] = []
        let payload = file.payload
        guard let faultingIdx = payload.faultingThreadIndex, payload.threads.indices.contains(faultingIdx),
              let threadState = payload.threads[faultingIdx].threadState else { return facts }

        let base = "threads[\(faultingIdx)].threadState"
        // Register names are architecture-specific: an x86_64 thread state has
        // rip/rsp/rbp and no `far` at all, so probing the ARM names produced nothing and
        // silently dropped every register corroboration on Intel reports.
        for (id, key, label) in Architecture.detect(in: payload).citedRegisters {
            guard let value = Self.registerValue(threadState, key) else { continue }
            let hex = "0x" + String(UInt64(bitPattern: Int64(value)), radix: 16)
            facts.append(Fact(id: id, statement: "\(label): \(hex)", sourcePath: "\(base).\(key)"))
        }
        return facts
    }

    /// Reads `threadState[key].value` as an `Int`, tolerating the usual JSON-number decode
    /// shapes (`Int`/`NSNumber`/numeric `String`) via `diagnosisIntValue`.
    static func registerValue(_ threadState: [String: Any], _ key: String) -> Int? {
        guard let register = threadState[key] as? [String: Any] else { return nil }
        return diagnosisIntValue(register["value"])
    }
}
