import Foundation

/// `background-task-overrun`: RunningBoard killed the process for holding a file
/// lock/database handle past being told to suspend (termination code `0xdead10cc`).
struct BackgroundTaskOverrunRule: DiagnosisRule {
    init() {}

    /// `Int("dead10cc", radix: 16)` — verified.
    static let code = 3_735_883_980
    static let namespaces: Set<String> = ["RUNNINGBOARD", "SPRINGBOARD"]

    func evaluate(facts: [Fact], file: IPSFile) -> [Hypothesis] {
        let payload = file.payload
        guard let termination = payload.termination,
              diagnosisIntValue(termination["code"]) == Self.code else { return [] }

        var supporting: [WeightedFact] = []
        if let f = facts.first(where: { $0.id == "termination.code" }) {
            supporting.append(WeightedFact(factID: f.id, weight: 3))
        }
        if let namespace = (termination["namespace"] as? String)?.uppercased(), Self.namespaces.contains(namespace),
           let f = facts.first(where: { $0.id == "termination.namespace" }) {
            supporting.append(WeightedFact(factID: f.id, weight: 1))
        }
        if let f = facts.first(where: { $0.id == "termination.reason-text" }) {
            supporting.append(WeightedFact(factID: f.id, weight: 1))
        }

        var inspect: [InspectionPoint] = []
        if let p = inspectionPointForDeepestAppFrame(in: payload, leb: false) { inspect.append(p) }

        let explanation = """
        RunningBoard killed this process (termination code 0xdead10cc) because it held on to a file \
        lock, sqlite/database handle, or other suspend-sensitive resource after being told to \
        suspend in the background. The OS requires these resources be released before suspension; \
        an unfinished background task (or a lock acquired just before backgrounding) is the usual cause.
        """

        return [Hypothesis(
            id: "background-task-overrun",
            title: "Background task overrun (held a lock/file past suspension)",
            explanation: explanation,
            category: "background-task",
            supporting: supporting,
            contradicting: [],
            inspect: inspect,
            confirmFurtherBy: [
                "Audit background-task code paths for unclosed NSFileCoordinator/sqlite/CoreData handles",
                "Ensure beginBackgroundTask/endBackgroundTask pairs bracket every held lock",
            ]
        )]
    }
}
