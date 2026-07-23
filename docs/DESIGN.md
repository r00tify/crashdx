# crashdx Diagnosis Engine Design

The design goal: given a crash report, produce *evidence-cited, ranked, competing
hypotheses*, with every claim traceable to a fact with a pointer into the raw report and
an honest "inconclusive" whenever the evidence doesn't separate the candidates. A single
confident label with no citation is the outcome this design exists to avoid.

## Architecture: three stages, all deterministic

```
IPSFile ──▶ 1. Evidence extraction ──▶ 2. Hypothesis generation ──▶ 3. Ranking & verdict
              (typed facts)              (rules; many may fire)       (scored, honest)
```

No LLM calls anywhere in the engine. The engine's job is to hand an agent (or human)
verifiable facts and ranked interpretations; narrative belongs to the consumer.

## Stage 1: Evidence extraction

Each extractor pulls typed `Fact`s from the parsed report. Every Fact has a stable `id`
(e.g. `termination.watchdog-event`, `frames.sentinel.assertion-failure`), a
human-readable statement, and a `sourcePath` pointer into the raw payload (JSON path) so
any consumer can verify it. The six extractors:

- **ExceptionFacts**: Mach exception type, signal, codes (decimal→hex render), subtype.
- **TerminationFacts**: namespace/code/indicator; `reasons` array text mined for the
  watchdog event kind (scene-create/scene-update) and its allowance in seconds, plus
  jetsam-adjacent strings (`per-process-limit`, `vm-pageshortage`, `highwater`).
- **FrameFacts**: sentinel frames on the faulting thread and LEB, by symbol match:
  `_assertionFailure` (Swift runtime), `swift_runtime_report`, `objc_exception_throw` /
  `__exceptionPreprocess`, `__cxa_throw` / `std::__terminate`, `abort` / `pthread_kill`
  chain, `__stack_chk_fail`, dispatch/main-queue markers. Also: deepest app-image frame
  (the "your code starts here" pointer) for both faulting thread and LEB, plus the LEB
  facts below. Also emits `frames.recursion-pattern` when three or more consecutive
  faulting-thread frames share a symbol (stack-overflow's corroboration).
- **MemoryFacts**: emits nothing unless the exception is `EXC_BAD_ACCESS` or `EXC_GUARD`.
  For `EXC_BREAKPOINT`, `codes[1]` is a trap PC rather than an address, and reading it as
  one would manufacture a fault address that never existed. Otherwise: faulting address
  from exception codes / `vmregioninfo`; classification inputs: address==0, address < page
  size (null + field offset), address in a named VM region, address near the stack pointer
  (overflow).
- **RegisterFacts** (from `threadState`): pc/lr/far where present; used to corroborate,
  never as sole evidence.
- **ASIFacts**: messages, parsed uncaught-exception name/reason. GROUND TRUTH CONSTRAINT:
  CLI/Foundation processes never carry the uncaught-exception message in asi; absence of
  it is NOT evidence against an NSException crash. Uncaught-NSException detection must
  key off LEB presence + objc_exception_throw frames.

**LEB facts** (presence, frame count, app frames within it, and symbol-trust marking) are
emitted by `FrameFactsExtractor` rather than a separate extractor. GROUND TRUTH
CONSTRAINT: ReportCrash itself mis-symbolicates LEB frames (observed: same image offset
resolved differently in thread vs LEB, with the LEB variant at `symbolLocation == 0`).
Rule: when a LEB frame's offset matches a faulting-thread frame with a different symbol,
prefer the thread symbol and mark the LEB symbol low-trust; a `symbolLocation == 0` symbol
on a LEB frame is suspect. Low trust is currently surfaced as prose appended to the fact
statement, not as a structured field; consumers cannot read it programmatically.

## Stage 2: Hypothesis generation

A rule consumes Facts and emits zero or more `Hypothesis` values. **No first-match-wins;
every applicable rule fires.** Shape:

```
Hypothesis {
  id: String                 // stable, e.g. "watchdog-timeout"
  title: String              // one line
  explanation: String        // 2-5 sentences, mechanism not narrative
  category: String           // watchdog | memory | swift-runtime | objc-exception | …
  supporting: [WeightedFact]    // evidence FOR:  each is (factID, weight)
  contradicting: [WeightedFact] // evidence AGAINST that the rule itself acknowledges
  inspect: [InspectionPoint] // frame refs (thread idx + frame idx) and file:line when known
  confirmFurtherBy: [String] // what would settle it (e.g. "check for synchronous network
                             //  call at SyncManager.swift:84"; "reproduce with Zombies")
}
```

Rule catalog (termination/exception families, plus memory & Swift runtime):

| Rule | Key evidence | Notes |
|---|---|---|
| watchdog-timeout | 0x8badf00d ns=SPRINGBOARD/FRONTBOARD; budget numbers from reason text | Explanation MUST state: backtrace shows where the main thread was STUCK, not the bug site |
| background-task-overrun | 0xdead10cc | holding file lock/db past suspension |
| jetsam-memory-kill | EXC_RESOURCE MEMORY or jetsam sentinel strings | distinguishes per-process-limit from system pressure; presence-only, no numeric footprint is extracted yet |
| uncaught-objc-exception | LEB present + objc_exception_throw frame | asi text is corroboration only (see the ASIFacts constraint); inspect = deepest app frame IN THE LEB |
| swift-fatal-trap | EXC_BREAKPOINT + _assertionFailure sentinel | subclassify force-unwrap vs precondition vs fatalError when asi/"Fatal error:" text exists |
| null-dereference | EXC_BAD_ACCESS + fault addr < pageSize | addr==0 exact vs small-offset (field access through nil pointer); a STACK GUARD region at the same address contradicts it at weight 3 |
| wild-or-uaf-address | EXC_BAD_ACCESS + addr in freed/unmapped region per vmregioninfo | explicitly lower confidence than null-deref; confirmFurtherBy: ASan/Zombies |
| stack-overflow | fault addr within guard page of stack region; recursive frame pattern | corroborate with repeated symbols |
| cxx-terminate | __cxa_throw/std::__terminate chain | distinguish from objc path |
| code-signing-kill | 0xc51bad01/02/03 family | per-code explanation |
| abort-generic | SIGABRT + abort chain | the honest fallback; fires unconditionally on that evidence and is demoted purely by its weight-1 support, never by inspecting other rules |

## Stage 3: Scoring, ranking, verdict

A deliberately simple, inspectable additive model:

- Each supporting Fact contributes its rule-declared weight (1 = weak corroboration,
  2 = strong indicator, 3 = pathognomonic, e.g. 0x8badf00d for watchdog).
- Each contradicting Fact subtracts its weight.
- `score = Σ support − Σ contradiction`; confidence bands: ≥4 strong, 2–3 moderate,
  ≤1 weak. Raw score is kept in the JSON so consumers can re-rank.
- Verdict: highest-scoring hypothesis if it is `strong` AND leads the runner-up by ≥2
  (a lone hypothesis satisfies the margin trivially); otherwise `inconclusive` with the
  ranked list. An honest `inconclusive` with good hypotheses beats a confident wrong
  label. That trade is the whole point of the scoring model, not a fallback.
- Ties/near-ties are presented as competing explanations, deliberately.

## Output contract

`AnalysisReport.diagnosis` carries:

```
diagnosis {                      // AnalysisReport.DiagnosisDump, never null
  status: "verdict" | "inconclusive" | "not_applicable"
  verdict: Hypothesis?           // present only when status == "verdict"
  hypotheses: [RankedHypothesis] // every hypothesis that fired, each with score + band
  factsConsidered: [Fact]?       // standard/full tiers only; KEY OMITTED at summary
}
```

`verdict` and `hypotheses` are present at every tier; the `factsConsidered` key is omitted
entirely at the summary tier (not emitted as null) to keep it token-lean.
`RankedHypothesis` wraps a `Hypothesis` with its raw `score` and `band` so consumers can
re-rank. Current `schemaVersion`: `"0.2"`. Bump it (and keep old-version decoders and
fixtures around) for any breaking shape change.

Two shapes worth distinguishing: the engine's own `Diagnosis` type has a **non-optional**
`factsConsidered`; the tier-gated optional lives on the report's `DiagnosisDump`, which is
what the JSON above describes. And `not_applicable` is produced only by the report builder
when the engine wasn't run; no rule ever emits it.

## Testing policy

- Every rule: ≥1 positive fixture-driven test + ≥1 negative (rule must NOT fire) test.
  All 11 rules currently satisfy this.
- Where a real fixture exists, it is the positive case: crashspike → swift-fatal-trap,
  nsexcrash → uncaught-objc-exception, nullderef → null-dereference, swift-frontend →
  abort-generic. cxx-terminate is the exception: its positive case is the synthetic
  `cxx-terminate-only.ips`, and its negative is `crashspike-stripped`.
- Nine synthetic payload-injection fixtures under
  `Tests/CrashDXCoreTests/Fixtures/synthetic/` cover report types that cannot be generated
  on a development Mac (watchdog, jetsam ×2, 0xdead10cc, code-signing, cxx-terminate, and
  three memory-address cases). Each starts from a real 309 payload with the relevant
  blocks replaced by Apple's documented example values: `exception` + `termination` for
  the five termination-family cases, `exception`/`vmregioninfo`/`threadState` for the
  three memory cases. `cxx-terminate-only.ips` is built differently: it takes the real
  `nsexcrash` report and removes `lastExceptionBacktrace` plus the `objc_exception_throw`
  frames, leaving a bare `__cxa_throw`/`std::__terminate` chain.
- Where a rule's *ranking* against a competing rule is the behavior under test, assert on
  the resulting verdict, not merely that the rule fired; a hypothesis can fire and still
  lose to a wrong one (see `stackGuardRegionPreventsConfidentNullDereferenceVerdict`).
- Two whole-`AnalysisReport` golden snapshots are byte-compared: `nsexcrash` at summary
  tier and `nullderef` at standard.
- The CLI is covered end-to-end by `CLIIntegrationTests`, which runs the real binary:
  the documented exit codes, diagnostics-on-stderr, tier gating, and flag handling.
- `HostileInputTests` and `SafeRenderingTests` cover the untrusted-input threat model:
  malformed and type-confused payloads, out-of-range indices, resource exhaustion, and
  the rendering trust boundary that stops a report forging crashdx's own output.
