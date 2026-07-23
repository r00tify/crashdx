import Foundation

/// `wild-or-uaf-address`: `EXC_BAD_ACCESS` with a faulting address OUTSIDE the null page,
/// where `vmregioninfo` either says the address is in a freed/deallocated region or gives
/// no containing-region information at all (`MemoryFactsExtractor` only emits an
/// `in-vmregion` fact for a CONFIRMED-containing region — see its doc comment — so "no
/// region fact" covers both "not in any region" and "no vmregioninfo present").
///
/// Deliberately capped below `null-dereference`'s confidence per `docs/DESIGN.md`:
/// absence of region info is weak, ambiguous evidence (it could be a wild pointer, a
/// use-after-free, OR simply an address the OS doesn't annotate) — this rule's supporting
/// weights sum to <= 3 (moderate, never `strong`) UNLESS `vmregioninfo` names a positive
/// freed/deallocated region (`memory.fault-address-in-vmregion-*freed*`), which is
/// deliberately pathognomonic-weighted and pushes the score into `strong`.
///
/// Mutually exclusive with `null-dereference` in practice: `null-dereference` requires the
/// null-page fact, and this rule's guard requires its ABSENCE; a same-thread null-page fact
/// is additionally declared as contradicting evidence here as a defense-in-depth measure
/// (per CONTRIBUTING.md's "prefer a contradicting fact over suppressing a
/// competing rule") even though the guard already prevents it from
/// co-occurring with this rule firing.
struct WildOrUAFAddressRule: DiagnosisRule {
    init() {}

    func evaluate(facts: [Fact], file: IPSFile) -> [Hypothesis] {
        let payload = file.payload
        guard payload.exceptionType == "EXC_BAD_ACCESS" else { return [] }
        guard let addressFact = facts.first(where: { $0.id == "memory.fault-address" }) else { return [] }
        guard facts.first(where: { $0.id == "memory.fault-address-null-page" }) == nil else { return [] }

        let freedRegionFact = facts.first { $0.id.hasPrefix("memory.fault-address-in-vmregion-") && $0.id.contains("freed") }
        let anyRegionFact = facts.first { $0.id.hasPrefix("memory.fault-address-in-vmregion-") }

        var supporting: [WeightedFact] = [WeightedFact(factID: addressFact.id, weight: 1)]
        if let f = facts.first(where: { $0.id == "exception.type" }) {
            supporting.append(WeightedFact(factID: f.id, weight: 2))
        }
        if let freedRegionFact {
            // Positive "freed region" fact — the only way this rule reaches `strong`.
            supporting.append(WeightedFact(factID: freedRegionFact.id, weight: 3))
        }

        var contradicting: [WeightedFact] = []
        if let nullPage = facts.first(where: { $0.id == "memory.fault-address-null-page" }) {
            contradicting.append(WeightedFact(factID: nullPage.id, weight: 2))
        }

        let explanation: String
        if let freedRegionFact {
            explanation = """
            The faulting address is outside the null page, and vmregioninfo reports it falls inside a \
            region marked freed/deallocated — a strong indicator of a USE-AFTER-FREE: something \
            retained a pointer to (or an unretained/unowned reference into) memory after it was \
            released, and later dereferenced it. \(freedRegionFact.statement)
            """
        } else if anyRegionFact != nil {
            explanation = """
            The faulting address is outside the null page and vmregioninfo names a containing region, \
            but nothing marks that region as freed — this looks like a WILD pointer (garbage/
            uninitialized value used as an address) rather than a confirmed use-after-free. Treat this \
            as a lower-confidence hypothesis than null-dereference; the region name alone isn't \
            enough to distinguish "wild" from "UAF into a region that hasn't been reused yet".
            """
        } else {
            explanation = """
            The faulting address is outside the null page, and vmregioninfo reports it is not inside \
            any known VM region at all — consistent with either a WILD pointer (an uninitialized or \
            garbage value used as an address) or a USE-AFTER-FREE into memory the OS has since \
            unmapped. This is deliberately a lower-confidence hypothesis than null-dereference: \
            absence of region information doesn't distinguish between these two causes.
            """
        }

        var inspect: [InspectionPoint] = []
        if let p = inspectionPointForDeepestAppFrame(in: payload, leb: false) { inspect.append(p) }

        return [Hypothesis(
            id: "wild-or-uaf-address",
            title: "Wild pointer or use-after-free",
            explanation: explanation,
            category: "memory",
            supporting: supporting,
            contradicting: contradicting,
            inspect: inspect,
            confirmFurtherBy: [
                "Re-run with Address Sanitizer enabled to catch the use-after-free at the free/access site",
                "Enable NSZombies (Malloc Scribble/Guard Malloc) to turn this into an immediate, informative crash",
                "Profile with Instruments' Allocations tool, recording reference counts",
            ]
        )]
    }
}
