# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
swift build                                   # debug build (crashdx, crashdx-mcp, CrashDXCore)
swift build -c release
swift test                                    # full test suite (Swift Testing, not XCTest)
swift test --filter DiagnosisEngineTests      # one suite (regex match on the suite name)
swift test --filter watchdogTimeoutFiresOnSyntheticFixture  # one @Test function

swift run crashdx analyze <report.ips> [--json --tier full] [--dsym <path>] [--no-spotlight] [--no-archives]
swift run crashdx symbolicate <report.ips> [--dsym <path>] [--no-spotlight] [--no-archives]
swift run crashdx-mcp                         # stdio MCP server

python3 Tests/mcp-smoke.py [.build/debug/crashdx-mcp]  # manual MCP protocol smoke test;
                                                        # NOT part of `swift test` — run after `swift build`
```

## Architecture

Three targets share one core:

- **`CrashDXCore`** — the library: `.ips` parsing (`IPSFile`), dSYM discovery
  (`DSYMLocator`), symbolication (`Symbolicator`), the diagnosis engine (`Diagnosis/`),
  and untrusted-text rendering (`SafeRendering`) — every report-derived string a front
  end prints must go through `sanitized(_:)`. Imports only Foundation.
- **`crashdx`** — CLI. `analyze`/`symbolicate` subcommands.
- **`crashdx-mcp`** — MCP server (stdio, newline-delimited JSON-RPC). The only target
  importing an external package (`modelcontextprotocol/swift-sdk`). Note SwiftPM resolves
  per package, so library consumers still pull that graph.

**`AnalyzePipeline`** (`Sources/CrashDXCore/AnalyzePipeline.swift`) is the single shared
parse → locate dSYMs → symbolicate → diagnose → build-report sequence. Both the CLI and
the MCP server call it — never duplicate this flow in either front end; add new steps
there so the two can't drift.

### Diagnosis engine

Three deterministic stages, no LLM calls (full spec in `docs/DESIGN.md`):

1. **Evidence extraction** — pulls typed `Fact`s (stable id, human-readable statement,
   `sourcePath` JSON pointer) from a parsed/symbolicated `IPSFile`. Six extractors: three
   in `Diagnosis/EvidenceExtractor.swift` (exception, termination, ASI) and three in their
   own files (`FrameFactsExtractor`, `MemoryFactsExtractor`, `RegisterFactsExtractor`).
2. **Hypothesis generation** (`Diagnosis/Rules/*.swift`, `DiagnosisRule` protocol) — every
   applicable rule fires (no first-match-wins), each producing a `Hypothesis` with
   supporting/contradicting facts, inspect points, and follow-up suggestions.
3. **Ranking** (`DiagnosisEngine.rank`) — additive score (Σ supporting weight − Σ
   contradicting weight) → confidence band (strong ≥4, moderate 2–3, weak ≤1). A verdict
   requires the top hypothesis to be `strong` AND lead the runner-up by ≥2 (a lone
   hypothesis that fired satisfies the margin trivially); otherwise the result is
   `inconclusive` with the full ranked list. An honest `inconclusive` beats a confidently
   wrong label — don't weaken this to always emit a verdict.

   Rules may cite `contradicting` facts, which subtract. Use this when one fact is a
   *direct observation* that undercuts another rule's *inference* — e.g. `vmregioninfo`
   naming a STACK GUARD region contradicts `null-dereference`, which only inferred the
   cause from the address value. See `NullDereferenceRule`.

Add a new crash pattern by adding an extractor (if new raw evidence is needed) and/or a
rule in `Diagnosis/Rules/`, registered in `DiagnosisEngine.defaultExtractors`/
`defaultRules` — the engine itself shouldn't need to change.

### Non-obvious data constraints

Verified empirically. Read the fixture ground truth in `corpus/README.md` and the doc
comments on the extractors themselves before "fixing" any of these:

- `asi` never carries the uncaught-NSException message for plain CLI/Foundation
  processes (only AppKit/UIKit-installed handlers write it there) — its absence is not
  evidence against an NSException crash. Detection keys off `lastExceptionBacktrace`
  presence + `objc_exception_throw` frames instead.
- `ReportCrash` sometimes mis-symbolicates `lastExceptionBacktrace` frames independently
  of the matching faulting-thread frame (same offset, different symbol, LEB's
  `symbolLocation == 0`). When they disagree, prefer the thread-frame symbol and mark the
  LEB one low-trust.
- `CrashSymbolicator.py` (invoked via `python3`, not directly executable) is the primary
  symbolication engine, not `atos` — `atos` is the fallback and needs decimal→hex offset
  conversion; it has produced worse results (`<compiler-generated>:0`) than
  CrashSymbolicator.py on identical input.

### Test fixtures & corpus

`Tests/CrashDXCoreTests/Fixtures/` holds crash reports harvested from real crashes of
purpose-built programs (`crashspike`, `nsexcrash`, `nullderef`), one real third-party
crash (`swift-frontend`), nine synthetic payload-injection fixtures under `synthetic/`,
one hand-edited derivative (`crashspike-unsymbolicated.ips`, symbol fields stripped), and
two golden snapshots.

**Every tracked fixture is scrubbed, and must stay that way.** They came off a real
machine, so they arrived carrying `crashReporterKey`, boot/sleep-wake UUIDs, device model
and usernames in paths; "synthetic" describes the crash scenario, not the provenance. Run
`Scripts/scrub-fixture.py` on any new `.ips` and `Scripts/check-fixtures-scrubbed.sh` to
verify — CI runs the latter. `corpus/raw/` is gitignored and must never be committed.
