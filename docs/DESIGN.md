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
- **RegisterFacts** (from `threadState`): pc/lr/far where present. Only `far` is currently
  cited by any rule (`NullDereferenceRule`, at weight 0 — see "Known limits of the additive
  model"); no rule should guard on a `registers.*` fact alone regardless.
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
  ≤1 weak. Raw score is kept in the JSON so consumers can re-rank. The sum is over
  *distinct* fact ids (highest weight wins): `supporting` is an array with no uniqueness
  constraint, and a rule that cited one Fact twice would otherwise inflate its own score
  silently.
- Verdict: highest-scoring hypothesis if it is `strong` AND leads the runner-up by ≥2
  (a lone hypothesis satisfies the margin trivially); otherwise `inconclusive` with the
  ranked list. An honest `inconclusive` with good hypotheses beats a confident wrong
  label. That trade is the whole point of the scoring model, not a fallback.
- Ties/near-ties are presented as competing explanations, deliberately.

### Known limits of the additive model

Recorded because the model's simplicity hides both of these, not because either is fixed.

**Correlated Facts count as independent evidence.** Nothing stops a rule citing several
renderings of one observation. `WatchdogTimeoutRule` cites `termination.code`
(0x8badf00d, 3), `termination.namespace` (1) and `termination.watchdog-event` (2) for a
score of 6, but all three are ReportCrash rendering one watchdog kill three ways into one
`termination` dict. One signal, scored as three. Some rules already compensate by hand
(`UncaughtObjCExceptionRule` downgrades the faulting-thread `objc_exception_throw` to
weight 1 when the LEB one already fired at 3); the engine does not enforce it.

`EvidenceChannel` + `DiagnosisEngine.Scoring.channelCapped` are the measured, opt-in
alternative: Facts pool by source artifact (derived from `Fact.sourcePath`) and only the
highest weight in each pool counts, on both the supporting and contradicting side. The
corpus ships 8 verdicts today, one fewer than before `null-deref-small-offset`'s own
`registers.far` duplicate was fixed (below) — that fixture no longer reaches `strong` even
under the shipped `additive` scoring, so it is not part of this comparison at all. Of the
remaining 8, channel capping demotes 4 — `watchdog-timeout`, `background-task-overrun`,
`cxx-terminate`, and `null-dereference` on the real `nullderef` fixture — and leaves the
rest standing (`uncaught-objc-exception` 5→4, `swift-fatal-trap` 6→5, `jetsam-memory-kill`
and `stack-overflow` unmoved at 5, all still `strong`).

`null-dereference` is demoted for a different reason than the other three: its support
isn't concentrated in one channel, it's that fixing the cross-artifact duplicate below
(`registers.far`, now cited at weight 0) left the `mach-exception` channel — which already
pools `-null-page` and `-exactly-null` to their max of 3 — with nothing outside it to add.
A textbook null-at-address-0 crash, arguably as pathognomonic as 0x8badf00d, caps out one
point short of `strong`. That's the weight-scale gap point 1 below describes, surfaced by
this fix rather than caused by it.

It is **not** the default, and should not be adopted as-is. Capping at the channel maximum
means a channel contributes at most 3, because 3 tops the weight scale — so `≥4 strong`
under capping silently becomes the invariant *no single artifact can ever produce a
verdict*. Nobody argued for that rule; it fell out of composing two independently chosen
numbers, and it is wrong on its face (0x8badf00d alone is sufficient evidence). Three of
the four demotions above (`watchdog-timeout`, `background-task-overrun`, `cxx-terminate`)
are that invariant firing, not the model becoming more honest — the fourth,
`null-dereference`, is the different case explained above. Taking the max is also the most
aggressive possible collapse: the second and third Facts in a channel contribute exactly
zero, which is as wrong as full independence in the other direction.

Channel capping is deliberately limited to same-artifact correlation, because the source
artifact is derivable and "same underlying event" is not. Cross-artifact correlation
mostly survives; the corpus's sharpest former case, `null-deref-small-offset` resting its
verdict on `registers.far` (a weight-1 corroboration whose value duplicated the
`exception.subtype` address the primary weight-3 Fact was parsed from), is fixed:
`NullDereferenceRule` now cites `registers.far` at weight 0, per option 2 below. The
standing example is `jetsam-memory-kill` — see `EvidenceChannel.residualCorrelationNote`.

**The weights and the ≥4 / +2 thresholds are uncalibrated.** They were chosen, not
derived. Every fixture with established ground truth is one the rules were written
against, so the corpus is a training set; held-out real reports with independently
established causes: none. Until that exists, `strong` means "these chosen weights summed
past this chosen threshold" and no claim about precision-at-verdict is supportable.
`DiagnosisAblation` is the stopgap: it withholds one Fact at a time and re-runs Stages 2–3,
which measures what each verdict actually rests on without needing new data. Two things it
found that reading `supporting` lists cannot show — a weight-1 Fact carrying a verdict (the
`null-deref-small-offset` case above, before its fix), and Facts that can be load-bearing
through *another* rule's `contradicting` list, defending the ≥2 margin rather than the
winner's own band. `stack-overflow` used to lose its verdict when the STACK GUARD Fact
(cited by `NullDereferenceRule` as a contradiction) was withheld, with the winning score
unmoved at 5 — fixing `registers.far` closed this too, incidentally: null-dereference's
runner-up score without the guard contradiction is now 3, not 4, so the margin holds
without it. The mechanism is still real; the corpus currently has no live example of it.

### What a real fix looks like

Neither limit above is fixed. What exists today is an instrument (`DiagnosisAblation`), a
measured-but-unadopted remedy (`Scoring.channelCapped`), and this record. The default
scoring path is unchanged, so every over-count described above is still live in
`crashdx analyze` output. Anyone picking this up should start from that.

**1. Redesign the weight scale and the bands together, then adopt capping.** Capping
summation alone is what produced the bogus "two artifacts minimum" invariant. The scale
and the bands have to move with it:

- Add a tier above `3` for Facts that are sufficient alone (0x8badf00d for watchdog,
  0xdead10cc for background-task-overrun, an `EXC_RESOURCE`/`MEMORY` subtype for jetsam).
  Reserve it strictly: pathognomonic means "no other cause produces this", not "strong".
- Re-derive the bands against the new scale so a lone top-tier Fact reaches `strong` on
  its own, and re-check the ≥2 margin, which was chosen against additive totals too.
- Consider softening the collapse from `max` to `max + 1 if ≥2 Facts agree in-channel`, so
  redundant renderings are worth something but not full price. This is a guess and should
  be chosen by measurement, not asserted.
- `DiagnosisAblationTests` pins today's numbers (`demoted`, `singleChannelVerdicts`).
  Those expectations are a **record of the current state, not a specification** — a
  legitimate re-derivation SHOULD fail them. Re-measure and rewrite them deliberately;
  do not edit the arrays to make a build green.

**2. Model cross-artifact correlation, or decide not to.** `EvidenceChannel` groups by
source artifact because that is derivable from `Fact.sourcePath` and stays correct as
extractors are added. It therefore cannot catch correlation that spans artifacts. The
options are to hand-declare an event group per Fact — which reintroduces exactly the drift
hand-tuned weights already suffer from, and should not be done without a test that fails
when a rule forgets — or to leave it and have rules cite the duplicate at weight 0.
`NullDereferenceRule`'s `registers.far` citation (above) took the second option; the
standing case for whoever tackles the first is `jetsam-memory-kill`, see
`EvidenceChannel.residualCorrelationNote`. Prefer the second until there is evidence the
first pays for itself.

Note also that `EvidenceChannel.of` is a string-prefix match on `sourcePath`: an extractor
emitting an unrecognised root lands in `.other` and is scored uncapped. That fails open by
design, and `everyExtractedFactClassifiesToAKnownChannel` guards it, but only for Facts the
fixtures actually produce — several sentinel and x86 register Facts are never exercised.

**3. Calibration needs data, and nothing in this repo substitutes for it.** Ablation
measures internal sensitivity against the same reports the rules were written from; it is
an easier adjacent question, not a partial answer. Required, in order:

- Held-out real reports with causes established independently (a fix commit, a bug report
  resolution), never inspected while tuning. Anonymisation is *not* the blocker —
  `Scripts/scrub-fixture.py` and the CI gate already solve it. Sourcing is.
- Report **precision-at-verdict** (of reports where `status == verdict`, how often the
  verdict is the true cause) and the inconclusive rate separately. Do not report accuracy:
  the design deliberately trades recall for precision, so a low recall number reads as
  failure when it is the intent.
- Cheaper interim, still not calibration: mutation testing. Perturb a fixture in ways that
  must not change the cause (renumber threads, strip symbols, swap architecture) and
  assert the verdict is stable. It at least tests against something other than the
  training set.

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
