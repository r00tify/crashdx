import Foundation

/// The CPU architecture a crash report came from, and the facts about it that the
/// diagnosis rules depend on.
///
/// Every fixture this project was developed against is arm64, and several assumptions
/// leaked into the engine as constants: a hardcoded 16 KB page size, and register lookups
/// by the ARM names `far`/`pc`/`lr`/`sp`. On an x86_64 report those register names simply
/// do not exist, so the extractor produced nothing and a genuine stack overflow was
/// re-labelled "wild pointer or use-after-free" — a wrong answer, not silence.
///
/// The two must be corrected together: mapping `rsp` to `sp` while keeping a 16 KB
/// stack-proximity window would treat a fault 12,000 bytes from the stack pointer as a
/// stack overflow on a platform whose guard page is 4 KB.
public enum Architecture: Sendable {
    case arm64
    case x86_64
    case unknown

    /// Derived from the payload's own `cpuType` ("ARM-64", "X86-64", …), falling back to
    /// the thread-state `flavor` and then to the referenced images' `arch`.
    public static func detect(in payload: CrashPayload) -> Architecture {
        if let cpuType = payload.raw["cpuType"] as? String {
            let upper = cpuType.uppercased()
            if upper.hasPrefix("ARM") { return .arm64 }
            if upper.hasPrefix("X86") { return .x86_64 }
        }
        if let idx = payload.faultingThreadIndex, payload.threads.indices.contains(idx),
           let flavor = payload.threads[idx].threadState?["flavor"] as? String {
            if flavor.uppercased().contains("ARM") { return .arm64 }
            if flavor.uppercased().contains("X86") { return .x86_64 }
        }
        for image in payload.usedImages {
            guard let arch = image.arch?.lowercased() else { continue }
            if arch.hasPrefix("arm") { return .arm64 }
            if arch.hasPrefix("x86") { return .x86_64 }
        }
        return .unknown
    }

    /// Page size in bytes. arm64 uses 16 KB; x86_64 uses 4 KB. When the architecture is
    /// undetermined, the smaller value is used so the null-page window stays conservative
    /// — claiming "nil + field offset" for an address that isn't in the null page is a
    /// wrong answer, whereas declining to claim it is merely a missed one.
    public var pageSize: UInt64 {
        switch self {
        case .arm64: return 16384
        case .x86_64, .unknown: return 4096
        }
    }

    /// Human-readable name for use in fact statements, so the cited evidence describes the
    /// machine the crash actually came from.
    public var displayName: String {
        switch self {
        case .arm64: return "arm64"
        case .x86_64: return "x86_64"
        case .unknown: return "unknown architecture"
        }
    }

    /// Register name for the fault address, if the architecture exposes one. x86_64 has no
    /// equivalent of ARM's `far` — the faulting address is only available from
    /// `exception.subtype`/`codes` there.
    public var faultAddressRegister: String? {
        switch self {
        case .arm64: return "far"
        case .x86_64, .unknown: return nil
        }
    }

    /// (fact id, register key, human label) for the registers worth citing.
    public var citedRegisters: [(id: String, key: String, label: String)] {
        switch self {
        case .arm64:
            return [
                ("registers.far", "far", "far (fault address register)"),
                ("registers.pc", "pc", "pc (program counter)"),
                ("registers.lr", "lr", "lr (link register)"),
            ]
        case .x86_64:
            return [
                ("registers.pc", "rip", "rip (instruction pointer)"),
                ("registers.sp", "rsp", "rsp (stack pointer)"),
                ("registers.fp", "rbp", "rbp (frame pointer)"),
            ]
        case .unknown:
            return []
        }
    }

    /// Register key holding the stack pointer.
    public var stackPointerRegister: String {
        switch self {
        case .arm64, .unknown: return "sp"
        case .x86_64: return "rsp"
        }
    }
}
