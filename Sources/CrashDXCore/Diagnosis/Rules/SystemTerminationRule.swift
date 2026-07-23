import Foundation

/// `system-termination`: the OS killed the process for a documented resource or policy
/// reason, identified by the `SIGKILL` termination code. Covers the watchOS background-task
/// budgets (`0xc51bad01`/`02`/`03`) plus the other codes Apple documents in
/// "EXC_CRASH (SIGKILL)".
///
/// GROUND TRUTH — these codes are documented in Apple's "EXC_CRASH (SIGKILL)" article and
/// are watchOS **background-task** budgets. They have nothing to do with code signing;
/// an earlier version of this rule read them as `CS_KILLED` and told developers to run
/// `codesign --verify`, which sends them to audit provisioning profiles for what is
/// actually a slow background task. Nothing about the codes themselves was wrong — the
/// constants were verified — but their meaning was.
///
/// `0xc51bad03` in particular must not be reported as the app's fault: Apple states
/// plainly that it "doesn't indicate that the app did anything wrong", only that the
/// system was too busy to give the task enough CPU.
struct SystemTerminationRule: DiagnosisRule {
    init() {}

    /// Keyed by the DECIMAL termination code, because `.ips` stores it that way.
    ///
    /// Deliberately does NOT include `0xdead10cc` — `BackgroundTaskOverrunRule` already
    /// owns that code with a better explanation and an inspection point. Two rules firing
    /// on one condition is double-counting, which is what makes a score look like
    /// corroboration when it is really one observation stated twice.
    /// Recompute rather than copying a decimal figure out of prose — these are easy to
    /// typo and a wrong constant silently stops the rule firing:
    /// `python3 -c 'print(0xc51bad01)'` -> 3306925313, `0xc51bad02` -> 3306925314,
    /// `0xc51bad03` -> 3306925315.
    static let codeMeanings: [Int: (label: String, explanation: String, appAtFault: Bool)] = [
        3_306_925_313: (
            "CPU budget exceeded",
            "watchOS terminated the app (0xc51bad01) because it used too much CPU time while "
                + "performing a background task. The backtrace shows where the task happened to be "
                + "when the budget ran out, which is not necessarily the expensive part — look for "
                + "the work the task performs overall, and make it cheaper or do less of it.",
            true
        ),
        3_306_925_314: (
            "background task ran out of time",
            "watchOS terminated the app (0xc51bad02) because a background task did not finish "
                + "within its allocated wall-clock time. Reduce the work performed in the task, or "
                + "move it to a more appropriate scheduling mechanism.",
            true
        ),
        // 0xc00010ff
        3_221_229_311: (
            "thermal pressure",
            "The OS terminated the app because the device was too hot. This is usually "
                + "driven by sustained CPU/GPU load; profile for busy loops, unthrottled "
                + "background work, or continuous high-power rendering.",
            true
        ),
        // 0xbaddd15c
        3_135_290_716: (
            "disk space exhausted",
            "The OS terminated the app because the device ran out of disk space. Not "
                + "necessarily this app's fault, but check for unbounded caches or logs.",
            false
        ),
        // 0xbad22222
        3_134_260_770: (
            "VoIP app resumed too frequently",
            "The OS terminated a VoIP app for resuming too often. Reduce how frequently "
                + "the app wakes.",
            true
        ),
        3_306_925_315: (
            "background task ran out of time under system load",
            "watchOS terminated the app (0xc51bad03) because a background task did not finish in "
                + "its allocated time — but the system was busy enough that the app may not have "
                + "received much CPU to work with. Apple documents this code as NOT indicating the "
                + "app did anything wrong. Reducing background work may still avoid it, but treat "
                + "this as environmental before treating it as a bug.",
            false
        ),
    ]

    func evaluate(facts: [Fact], file: IPSFile) -> [Hypothesis] {
        let payload = file.payload
        guard let termination = payload.termination,
              let code = diagnosisIntValue(termination["code"]),
              let meaning = Self.codeMeanings[code] else { return [] }

        // The code itself is pathognomonic — it maps to exactly one documented condition.
        var supporting: [WeightedFact] = []
        if let f = facts.first(where: { $0.id == "termination.code" }) {
            supporting.append(WeightedFact(factID: f.id, weight: 3))
        }
        // Only credit the namespace when it actually corroborates. Counting it
        // unconditionally previously handed this rule the point that lifted a wrong
        // verdict to the `strong` floor.
        if let namespace = termination["namespace"] as? String,
           namespace == "WATCHDOG" || namespace == "SPRINGBOARD" || namespace == "FRONTBOARD",
           let f = facts.first(where: { $0.id == "termination.namespace" }) {
            supporting.append(WeightedFact(factID: f.id, weight: 1))
        }

        var confirm = [
            "Profile the background task's work — reduce CPU or total wall-clock time",
            "Check whether the task can be split, deferred, or scheduled differently",
        ]
        if !meaning.appAtFault {
            confirm.insert(
                "Before changing anything: 0xc51bad03 can occur on a busy system without the app "
                    + "being at fault — check whether it reproduces under normal load",
                at: 0
            )
        }

        return [Hypothesis(
            id: "system-termination",
            title: "System termination: \(meaning.label)",
            explanation: meaning.explanation,
            category: "resource",
            supporting: supporting,
            contradicting: [],
            inspect: inspectionPointForDeepestAppFrame(in: payload, leb: false).map { [$0] } ?? [],
            confirmFurtherBy: confirm
        )]
    }
}
