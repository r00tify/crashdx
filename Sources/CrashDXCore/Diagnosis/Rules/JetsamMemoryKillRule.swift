import Foundation

/// `jetsam-memory-kill`: the kernel's Jetsam mechanism killed this process for memory use,
/// either `EXC_RESOURCE`/`MEMORY` subtype or a termination reason/indicator carrying
/// `per-process-limit`, `vm-pageshortage`, or `highwater`. Per `docs/DESIGN.md`, the
/// explanation distinguishes "this app exceeded ITS OWN limit" (per-process-limit) from
/// "system-wide pressure picked this app as a kill candidate" (vm-pageshortage/highwater)
/// — those are mutually distinguishing pieces of *evidence*, so a fixture carrying only one
/// produces a hypothesis whose explanation speaks to that one cause; a fixture carrying
/// both (unusual) gets a combined, still-honest explanation rather than two hypotheses
/// under the rule catalog's single `jetsam-memory-kill` id.
struct JetsamMemoryKillRule: DiagnosisRule {
    init() {}

    func evaluate(facts: [Fact], file: IPSFile) -> [Hypothesis] {
        let payload = file.payload

        // Apple documents `exception.note == "NON-FATAL CONDITION"` as meaning the OS
        // generated a report WITHOUT terminating the process. Claiming a jetsam kill for
        // one is simply false — the app is still running.
        if let note = payload.exception?["note"] as? String,
           note.localizedCaseInsensitiveContains("NON-FATAL") {
            return []
        }

        let subtypeFact = facts.first { $0.id == "exception.subtype" }
        let subtypeIsMemory = (payload.exception?["subtype"] as? String)?.uppercased().contains("MEMORY") ?? false
        let excResourceMemory = payload.exceptionType == "EXC_RESOURCE" && subtypeIsMemory

        let perProcessFact = facts.first { $0.id == "termination.jetsam-per-process-limit" }
        let systemPressureFact = facts.first { $0.id == "termination.jetsam-system-pressure" }

        guard excResourceMemory || perProcessFact != nil || systemPressureFact != nil else { return [] }

        var supporting: [WeightedFact] = []
        if excResourceMemory, let subtypeFact { supporting.append(WeightedFact(factID: subtypeFact.id, weight: 3)) }
        if let perProcessFact { supporting.append(WeightedFact(factID: perProcessFact.id, weight: 2)) }
        if let systemPressureFact { supporting.append(WeightedFact(factID: systemPressureFact.id, weight: 2)) }

        let explanation: String
        switch (perProcessFact != nil, systemPressureFact != nil) {
        case (true, false):
            explanation = """
            The kernel's Jetsam mechanism killed this process for exceeding its OWN per-process \
            memory limit (indicator: per-process-limit). This app's own memory footprint grew past \
            what the system allows for it specifically, independent of overall system memory \
            pressure — the fix is reducing this app's memory use.
            """
        case (false, true):
            explanation = """
            The kernel's Jetsam mechanism killed this process due to SYSTEM-WIDE memory pressure \
            (indicator: vm-pageshortage/highwater) — overall device memory ran low and this process \
            was chosen as a kill candidate, not because it individually exceeded a per-process limit. \
            This app may be entirely healthy; investigate what else was consuming memory system-wide.
            """
        case (true, true):
            explanation = """
            Jetsam evidence cites BOTH this app's own per-process limit and system-wide memory \
            pressure — this app was both large and killed under broader pressure. Treat the \
            per-process-limit number as the more actionable lead; check system-wide pressure only if \
            reducing this app's footprint alone doesn't resolve it.
            """
        case (false, false):
            explanation = """
            An EXC_RESOURCE exception with a MEMORY subtype indicates the process was sampled and \
            killed by Jetsam for high memory usage. No per-process-limit/system-wide-pressure text \
            was available to further distinguish the cause — see the cited exception subtype evidence.
            """
        }

        var inspect: [InspectionPoint] = []
        if let p = inspectionPointForDeepestAppFrame(in: payload, leb: false) { inspect.append(p) }

        return [Hypothesis(
            id: "jetsam-memory-kill",
            title: "Jetsam memory kill",
            explanation: explanation,
            category: "memory",
            supporting: supporting,
            contradicting: [],
            inspect: inspect,
            confirmFurtherBy: [
                "Profile with Instruments' Allocations/VM Tracker around the time of the kill",
                "Check MetricKit/os_log for memory footprint history leading up to the kill",
            ]
        )]
    }
}
