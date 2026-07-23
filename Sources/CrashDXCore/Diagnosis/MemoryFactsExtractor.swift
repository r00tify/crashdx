import Foundation

/// Faulting-address facts for memory-access crashes: `exception.subtype`/`exception.codes`
/// (the address itself), page/zero classification, `vmregioninfo` containment, and
/// stack-proximity. Per `docs/DESIGN.md`'s MemoryFacts bullet.
///
/// GROUND TRUTH (verified against real `EXC_BAD_ACCESS` reports —
/// corpus/raw/axassetsd-2026-07-19-180319.ips, corpus/raw/contactsd-2026-07-16-140424.ips,
/// corpus/fixtures/nullderef/nullderef.ips):
/// - `exception.subtype` is `"KERN_INVALID_ADDRESS at 0x0000000000000008"` — the address is
///   ALWAYS rendered with a `0x` prefix here, even for address 0
///   (`"KERN_INVALID_ADDRESS at 0x0000000000000000"`), so a single `at (0x[0-9A-Fa-f]+)`
///   regex covers every observed case; `exception.codes`' second decimal-rendered-as-hex
///   value (`rawCodes[1]`) is the same address and is used only as a fallback when subtype
///   is absent or unparseable.
/// - `vmregioninfo` is a free-text string. Its FIRST clause states whether the address
///   falls inside a known region at all — observed verbatim forms: `"0x8 is not in any
///   region.  Bytes before following region: N\n ..."` (both real corpus files) and,
///   distinctly, `"0 is not in any region. ..."` for address exactly 0 (no `0x` prefix in
///   THIS string, unlike `exception.subtype` — nullderef fixture). Neither real sample had
///   an address actually contained in a region, so the `"... is in a NNN region. ..."` /
///   containing-region phrasing is Apple-documented but was NOT independently observed;
///   the synthetic fixtures below exercise it. A `memory.fault-address-in-vmregion-<type>`
///   fact is deliberately emitted ONLY for the containing case — "not in any region" means
///   there is no region to name, so no such fact fires (its nearest-boundary region, e.g.
///   `__TEXT` in both real samples, is not where the fault occurred and would be
///   misleading to report as "the" region).
/// - The region-detail table row format (present in every real sample regardless of
///   containment) is fixed-width: `"      <TYPE...>          <STARTHEX>-<ENDHEX>    [
///   VSIZE] PRT/MAX SHRMOD  DETAIL"`, e.g. `"      __TEXT                      104810000-
///   104828000    [   96K] r-x/r-x SM=COW  /path"`.
struct MemoryFactsExtractor: EvidenceExtractor {
    init() {}

    /// Exception types whose `codes`/`subtype` second value is actually a memory address.
    /// Gating on this matters: e.g. `EXC_BREAKPOINT`'s `codes[1]` is a trap PC, not a
    /// faulting address — extracting it as one would be misleading (verified against
    /// corpus/fixtures/crashspike, an `EXC_BREAKPOINT` fixture, during development).
    /// ONLY `EXC_BAD_ACCESS`. For `EXC_GUARD`, `codes[1]` is a guard identifier — a file
    /// descriptor number, Mach port name, or vnode guard token — NOT an address. Mining it
    /// as a fault address manufactured facts like "Faulting address is exactly 0 (a true
    /// nil-pointer dereference)" for reports with no memory access at all, which then
    /// shipped in `factsConsidered` for a consumer to read as evidence. `EXC_BREAKPOINT`
    /// was excluded earlier for exactly this reason (its `codes[1]` is a trap PC).
    static let memoryRelevantExceptionTypes: Set<String> = ["EXC_BAD_ACCESS"]

    func extract(from file: IPSFile) -> [Fact] {
        var facts: [Fact] = []
        let payload = file.payload

        guard let type = payload.exceptionType, Self.memoryRelevantExceptionTypes.contains(type) else { return facts }
        let arch = Architecture.detect(in: payload)
        guard let (address, sourcePath) = Self.faultAddress(in: payload) else { return facts }

        facts.append(Fact(
            id: "memory.fault-address",
            statement: "Faulting address: \(Self.hex(address))",
            sourcePath: sourcePath
        ))

        let isNullPage = address < arch.pageSize
        if isNullPage {
            facts.append(Fact(
                id: "memory.fault-address-null-page",
                statement: "Faulting address \(Self.hex(address)) is within the null page (< \(Self.hex(arch.pageSize)), \(arch.displayName) page size)",
                sourcePath: sourcePath
            ))
            if address == 0 {
                facts.append(Fact(
                    id: "memory.fault-address-exactly-null",
                    statement: "Faulting address is exactly 0 (a true nil-pointer dereference, not an offset field access)",
                    sourcePath: sourcePath
                ))
            }
        }

        var nearStackReasons: [String] = []

        if let vmregioninfo = payload.vmregioninfo {
            if let regionType = Self.containingRegionType(in: vmregioninfo) {
                let slug = Self.slug(regionType)
                facts.append(Fact(
                    id: "memory.fault-address-in-vmregion-\(slug)",
                    statement: "Faulting address \(Self.hex(address)) falls inside a '\(regionType)' VM region",
                    sourcePath: "vmregioninfo"
                ))
            }
            if vmregioninfo.lowercased().contains("stack guard") {
                nearStackReasons.append("vmregioninfo names a STACK GUARD region")
            }
        }

        if let faultingIdx = payload.faultingThreadIndex, payload.threads.indices.contains(faultingIdx),
           let threadState = payload.threads[faultingIdx].threadState,
           let sp = RegisterFactsExtractor.registerValue(threadState, arch.stackPointerRegister) {
            let spU = UInt64(bitPattern: Int64(sp))
            let distance = address > spU ? address - spU : spU - address
            if distance < arch.pageSize {
                nearStackReasons.append("within \(distance) bytes of sp (\(Self.hex(spU)))")
            }
        }

        if !nearStackReasons.isEmpty {
            facts.append(Fact(
                id: "memory.fault-address-near-stack",
                statement: "Faulting address \(Self.hex(address)) is near the stack region: \(nearStackReasons.joined(separator: "; "))",
                sourcePath: "vmregioninfo"
            ))
        }

        return facts
    }

    // Page size now comes from `Architecture` — see Architecture.swift.

    /// The faulting address and the JSON path it was read from, preferring
    /// `exception.subtype`'s `"... at 0xNNNN"` text and falling back to the second value
    /// in `exception.codes`. `nil` when neither field yields a parseable address.
    static func faultAddress(in payload: CrashPayload) -> (address: UInt64, sourcePath: String)? {
        if let subtype = payload.exception?["subtype"] as? String,
           let addr = Self.addressAfter(prefix: "at", in: subtype) {
            return (addr, "exception.subtype")
        }
        if let codes = payload.exception?["codes"] as? String {
            let parts = codes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2, let addr = Self.hexValue(parts[1]) {
                return (addr, "exception.codes")
            }
        }
        return nil
    }

    private static let atHexRegex = try! NSRegularExpression(pattern: #"at\s+(0x[0-9A-Fa-f]+)"#)

    private static func addressAfter(prefix: String, in text: String) -> UInt64? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = atHexRegex.firstMatch(in: text, range: range), match.numberOfRanges == 2,
              let hexRange = Range(match.range(at: 1), in: text) else { return nil }
        return hexValue(String(text[hexRange]))
    }

    private static func hexValue(_ token: String) -> UInt64? {
        var t = token
        if t.hasPrefix("0x") || t.hasPrefix("0X") { t.removeFirst(2) }
        return UInt64(t, radix: 16)
    }

    private static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }

    /// Extracts the region-type name from `vmregioninfo` when its leading clause states the
    /// address IS contained in a region ("... is in a ... region..."), as opposed to "...
    /// is not in any region...". Returns the first region-detail table row's type token
    /// (trimmed), e.g. `"STACK GUARD"`, `"MALLOC_TINY (freed)"`.
    static func containingRegionType(in vmregioninfo: String) -> String? {
        let lowered = vmregioninfo.lowercased()
        guard lowered.contains(" is in a"), !lowered.contains("is not in any region") else { return nil }
        let range = NSRange(vmregioninfo.startIndex..<vmregioninfo.endIndex, in: vmregioninfo)
        guard let match = regionRowRegex.firstMatch(in: vmregioninfo, range: range), match.numberOfRanges == 2,
              let typeRange = Range(match.range(at: 1), in: vmregioninfo) else { return nil }
        return vmregioninfo[typeRange].trimmingCharacters(in: .whitespaces)
    }

    /// Matches one region-detail table row: a type name, 2+ spaces, then a
    /// `STARTHEX-ENDHEX` address range, then the `[ VSIZE]` column.
    private static let regionRowRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*([A-Za-z0-9_ .()\-]+?)[ \t]{2,}[0-9A-Fa-f]+-[0-9A-Fa-f]+[ \t]+\["#,
        options: [.anchorsMatchLines]
    )

    /// Lowercases, then collapses every run of non-alphanumeric characters to a single
    /// `-`, trimming leading/trailing `-`. `"STACK GUARD"` -> `"stack-guard"`;
    /// `"MALLOC_TINY (freed)"` -> `"malloc-tiny-freed"` (so a freed malloc region is
    /// self-evidently distinguishable in the fact id without separate bookkeeping).
    static func slug(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let collapsed = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
