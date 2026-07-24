# crashdx

[![CI](https://github.com/r00tify/crashdx/actions/workflows/ci.yml/badge.svg)](https://github.com/r00tify/crashdx/actions/workflows/ci.yml)

A crash **diagnosis** engine for Apple platforms: parses `.ips` crash reports, symbolicates
them against dSYMs, and produces an evidence-cited, ranked diagnosis, not just a
symbolicated stack trace.

Ships as a dependency-free Swift library (`CrashDXCore` imports only Foundation), a CLI
(`crashdx`), and an MCP server (`crashdx-mcp`), so agents and humans use the same engine.

## Why

A symbolicated stack trace tells you where a process died, not why. crashdx adds a second
stage on top of symbolication: deterministic, rule-based evidence extraction (watchdog
budgets, jetsam tables, register and memory state, `lastExceptionBacktrace`/`asi`) feeding
a ranked set of competing hypotheses, each citing the specific facts that support it and
pointing back into the raw report.

Two properties it holds onto deliberately:

- **Every claim is traceable.** Facts carry a JSON path into the original report, so any
  verdict can be checked rather than trusted.
- **It says "inconclusive" when it is.** A verdict requires the leading hypothesis to be
  strongly supported *and* clearly ahead of the runner-up; otherwise you get the ranked
  candidates and what would settle it.

There are no LLM calls in the engine: it produces verifiable facts and ranked
interpretations, and leaves the narrative to whatever consumes them. See
[docs/DESIGN.md](docs/DESIGN.md) for the full architecture.

## Example output

Everything below is real, unedited output from fixtures in this repo (elisions are marked).
Paths are relative to the repo root, and the `--dsym` flags point at dSYMs the repo ships,
so these reproduce as-is; use `swift run crashdx ...` if you have not installed the binary.

### A verdict

```
$ crashdx analyze Tests/CrashDXCoreTests/Fixtures/nsexcrash.ips \
      --dsym Tests/CrashDXCoreTests/Fixtures/nsexcrash.dSYM

process:    nsexcrash
bug_type:   309
os:         macOS 26.3.1 (25D2128)
exception:  EXC_CRASH (SIGABRT)
terminated: Abort trap: 6
faulting thread (15 frames):
  libsystem_kernel.dylib  __pthread_kill
  libsystem_pthread.dylib  pthread_kill
  libsystem_c.dylib  abort
  libc++abi.dylib  __abort_message
  libc++abi.dylib  demangling_terminate_handler()
  libobjc.A.dylib  _objc_terminate()
  libc++abi.dylib  std::__terminate(void (*)())
  libc++abi.dylib  __cxxabiv1::failed_throw(__cxxabiv1::__cxa_exception*)
  libc++abi.dylib  __cxa_throw
  libobjc.A.dylib  objc_exception_throw
  CoreFoundation  -[NSException raise]
  nsexcrash  throwingHelper() (main.swift:8)
  nsexcrash  doWork() (main.swift:12)
  nsexcrash  main (main.swift:15)
  dyld  start
last exception backtrace (7 frames):
  CoreFoundation  __exceptionPreprocess
  libobjc.A.dylib  objc_exception_throw
  CoreFoundation  -[NSException raise]
  nsexcrash  throwingHelper() (main.swift:8)
  nsexcrash  doWork() (main.swift:12)
  nsexcrash  main (main.swift:15)
  dyld  start
symbolication (engine: crashSymbolicator):
  nsexcrash  symbolicated
  libsystem_kernel.dylib  no_dsym
  libsystem_pthread.dylib  no_dsym
  ...
DIAGNOSIS: Uncaught Objective-C exception (NSException)   (strong, score 5)
  A lastExceptionBacktrace is present and an objc_exception_throw frame appears in it (or on the
  faulting thread) — together these are pathognomonic for an uncaught NSException: `-raise` walked up
  through objc_exception_throw and was never caught, so the runtime called terminate and aborted. The
  asi "Terminating app due to uncaught exception" message is only corroboration when present; plain
  CLI/Foundation processes never write it, so its absence is not evidence against this hypothesis.
  evidence: lastExceptionBacktrace is present with 7 frame(s); lastExceptionBacktrace frame 1 matches
            sentinel 'objc-exception-throw': objc_exception_throw; Faulting thread frame 9 matches
            sentinel 'objc-exception-throw': objc_exception_throw
  inspect:  nsexcrash throwingHelper() (main.swift:8)
  confirm:  Symbolicate the app frames in lastExceptionBacktrace to find the throw site; Check the
            asi/console log for the exception name and reason, if available
  also considered: cxx-terminate (moderate, 2), abort-generic (weak, 1)
```

The `evidence` line cites the supporting facts the rule scored on, up to four, with a
running total when there are more; each fact carries a path back into the original report,
which `--json --tier standard` exposes. `also considered` is the full remainder of the
ranked list, so you can see what the verdict beat and by how much.

### An inconclusive result

When the leading hypothesis is not strongly supported *and* clearly ahead, you get the
candidates instead of a label:

```
$ crashdx analyze Tests/CrashDXCoreTests/Fixtures/synthetic/wild-address.ips \
      --dsym corpus/fixtures/nullderef/nullderef.dSYM

process:    synthetic-wild-address
bug_type:   309
os:         macOS 26.3.1 (25D2128)
exception:  EXC_BAD_ACCESS (SIGSEGV)
terminated: Segmentation fault: 11
faulting thread (4 frames):
  nullderef  readThroughNullPointer() (main.swift:9)
  nullderef  run() (main.swift:13)
  nullderef  main (main.swift:16)
  dyld  start
symbolication (engine: crashSymbolicator):
  nullderef  symbolicated
  dyld  no_dsym
DIAGNOSIS: INCONCLUSIVE — competing hypotheses:
  1. Wild pointer or use-after-free [wild-or-uaf-address]   (moderate, score 3)
     The faulting address is outside the null page, and vmregioninfo reports it is not inside any known
     VM region at all — consistent with either a WILD pointer (an uninitialized or garbage value used as
     an address) or a USE-AFTER-FREE into memory the OS has since unmapped. This is deliberately a
     lower-confidence hypothesis than null-dereference: absence of region information doesn't distinguish
     between these two causes.
     evidence: Faulting address: 0x1deadbeef; Exception type: EXC_BAD_ACCESS
     inspect:  nullderef readThroughNullPointer() (main.swift:9)
     confirm:  Re-run with Address Sanitizer enabled to catch the use-after-free at the free/access site;
               Enable NSZombies (Malloc Scribble/Guard Malloc) to turn this into an immediate,
               informative crash; Profile with Instruments' Allocations tool, recording reference counts
```

### Other crash families

The same shape applies across the rule set. Verdict and evidence lines from four more
fixtures, with the explanation and follow-up steps elided:

```
# synthetic/watchdog-scene-create.ips
DIAGNOSIS: Watchdog timeout (main thread stall)   (strong, score 6)
  evidence: Termination code: 2343432205 (0x8badf00d); Termination namespace: FRONTBOARD; Watchdog
            event: scene-create, allowance 19.97s

# synthetic/jetsam-per-process-limit.ips
DIAGNOSIS: Jetsam memory kill   (strong, score 5)
  evidence: Exception subtype: RESOURCE_TYPE_MEMORY; Jetsam per-process-limit indicator:
            per-process-limit 350808KB exceeds task limit 335872KB

# synthetic/stack-overflow.ips
DIAGNOSIS: Stack overflow   (strong, score 5)
  evidence: Faulting address 0x3000 is near the stack region: vmregioninfo names a STACK GUARD region;
            within 500 bytes of sp (0x31f4); Faulting thread has 5 consecutive frames with identical
            symbol 'recurse(_:)' starting at frame 0 — a recursion signature

# crashspike-unsymbolicated.ips, with --dsym Tests/CrashDXCoreTests/Fixtures/crashspike.dSYM
DIAGNOSIS: Swift runtime fatal trap   (strong, score 6)
  evidence: Exception type: EXC_BREAKPOINT; Signal: SIGTRAP; Faulting thread frame 0 matches sentinel
            'assertion-failure': _assertionFailure(_:_:file:line:flags:)
```

Each of those also prints the full explanation, `inspect` point, and `confirm` steps shown
in the first example.

### JSON

`--json` emits the same analysis as a structured `AnalysisReport`, which is what the MCP
server returns and what you would parse in CI. Below is the same crash as the first
example, abridged (`/* ... */` marks elisions). The real output is a single minified line
with sorted keys, so pipe it through `jq` or `python3 -m json.tool`; it is pretty-printed
and reordered here for readability:

```jsonc
{
  "schemaVersion": "0.2",
  "tier": "summary",
  "diagnosis": {
    "status": "verdict",
    "verdict": {
      "id": "uncaught-objc-exception",
      "title": "Uncaught Objective-C exception (NSException)",
      "category": "objc-exception",
      "explanation": "A lastExceptionBacktrace is present and an objc_exception_throw frame ...",
      "supporting": [
        { "factID": "leb.present", "weight": 1 },
        { "factID": "leb.sentinel.objc-exception-throw", "weight": 3 },
        { "factID": "frames.sentinel.objc-exception-throw", "weight": 1 }
      ],
      "contradicting": [],
      "inspect": [
        { "frameIndex": 3, "leb": true, "symbol": "throwingHelper()",
          "sourceFile": "main.swift", "sourceLine": 8 }
      ],
      "confirmFurtherBy": [ /* ... */ ]
    },
    "hypotheses": [ /* all 3, each with its band + score */ ]
  },
  "event": {
    "bugType": "309", "exceptionType": "EXC_CRASH", "signal": "SIGABRT",
    "terminationIndicator": "Abort trap: 6", "terminationNamespace": "SIGNAL"
  },
  "faultingThread": { "index": 0, "queue": "com.apple.main-thread", "triggered": true,
                      "frames": [ /* ... */ ] },
  "symbolication": { "engine": "crashSymbolicator", "images": [ /* per-image outcome + uuid */ ] },
  "process": { "name": "nsexcrash", "osVersion": "macOS 26.3.1 (25D2128)",
               "captureTime": "2026-07-23 00:22:01.2793 +0000" }
}
```

Note `"leb": true` on the inspect point: the throw site was recovered from
`lastExceptionBacktrace` rather than the faulting thread, and the report says so instead of
flattening the distinction.

`--tier standard` (see [Report tiers](#report-tiers)) adds `diagnosis.factsConsidered`,
which resolves every `factID` to its human-readable statement and its `sourcePath` into the
raw report:

```jsonc
{ "id": "leb.sentinel.objc-exception-throw",
  "statement": "lastExceptionBacktrace frame 1 matches sentinel 'objc-exception-throw': objc_exception_throw",
  "sourcePath": "lastExceptionBacktrace[1]" }
```

`sourcePath` is not optional on a `Fact`, so every fact the diagnosis cites can be walked
back to the part of the report it was read from.

Committed golden snapshots of both
tiers live in `Tests/CrashDXCoreTests/Fixtures/` (`nsexcrash-summary-golden.json`,
`nullderef-standard-golden.json`) if you want the complete, unabridged shape.

## Requirements

- macOS 14+
- **Swift 6.2+** toolchain. The manifest itself is `swift-tools-version:6.0`, but the MCP
  server's pinned dependencies declare up to `6.2`, and SwiftPM resolves the whole
  package graph, so 6.2 is the real floor for every target, including `CrashDXCore`.
- **Xcode** (not just Command Line Tools): symbolication drives Apple's
  `CrashSymbolicator.py` from Xcode's `CoreSymbolicationDT.framework`, located via
  `xcode-select -p`. Without it, crashdx falls back to `atos`, which resolves fewer
  source locations. Parsing and diagnosis work either way.
- `/usr/bin/python3` and `/usr/bin/dwarfdump` (both provided by Xcode's command line
  tools), used to run `CrashSymbolicator.py` and to verify dSYM UUIDs.

### Supported reports

Honest scope, because a crash diagnoser that quietly does worse on your platform is worse
than one that says so:

- **arm64 crash reports are fully supported**: Apple silicon Macs, iOS/iPadOS/watchOS/
  tvOS devices, and Simulators hosted on Apple silicon. This is what the fixture corpus
  covers.
- **x86_64 reports** (Intel Macs, Rosetta-translated processes, Simulators on Intel) parse
  and symbolicate, and the engine reads `x86_THREAD_STATE` registers and the 4 KB page
  size. There is no Intel fixture in the corpus, so this path is reasoned-about rather
  than exercised against a real report.
- **Only crash reports** (`bug_type` 309/109). Jetsam event reports (`JetsamEvent-*.ips`,
  `bug_type` 298) and hang/stackshot reports (`bug_type` 288) use a different payload
  shape with no threads or exception object; crashdx parses them without error but has
  no facts to work from and will report inconclusive.

### Privacy

crashdx runs entirely on your machine and **makes no network calls of any kind**. Crash
reports, dSYMs, and everything derived from them stay local. This matters because `.ips`
files contain identifying data (`crashReporterKey`, boot/sleep-wake UUIDs, device model,
and usernames in paths), so if you attach one to a bug report, scrub it first.

## Install / build

```sh
git clone https://github.com/r00tify/crashdx.git
cd crashdx
swift build -c release
```

The binaries land in `.build/release/`. To put them on your `PATH`:

```sh
sudo mkdir -p /usr/local/bin
sudo cp .build/release/crashdx .build/release/crashdx-mcp /usr/local/bin/
```

(Or copy them somewhere you already own, such as `~/.local/bin`.)

## Usage

Crash reports live in `~/Library/Logs/DiagnosticReports/` on macOS (or Console.app →
Crash Reports); on iOS, Settings → Privacy & Security → Analytics & Improvements →
Analytics Data, and Xcode's Organizer for TestFlight/App Store crashes.

```sh
crashdx analyze report.ips                           # human-readable summary + diagnosis
crashdx analyze report.ips --json                    # structured AnalysisReport JSON
crashdx analyze report.ips --json --tier full        # ...with every thread included
crashdx symbolicate report.ips --dsym path/to.dSYM   # just symbolicate, print enriched .ips
crashdx --version
```

`--dsym` accepts a `.dSYM` bundle, an `.xcarchive`, or a directory to search recursively
(repeatable), and `--no-spotlight` skips Spotlight-based discovery while `--no-archives`
skips Xcode's archive directory. Run `crashdx <subcommand> --help` for the full option
list. Note that `--json` and `--tier` apply to `analyze` only; `symbolicate` always emits
a complete `.ips`.

Both subcommands search Spotlight and Xcode's archives for a matching dSYM automatically.
For foreign reports (user-submitted, TestFlight, CI artifacts) pass the build's dSYM
explicitly with `--dsym`.

Strings taken from the report (process name, symbols, paths, exception text) are escaped
before the human-readable summary prints them: C0 controls, DEL, and bidi overrides
render as `\x0A` / `\u{202E}` instead of being emitted, so a crafted report cannot forge
a `DIAGNOSIS:` line or repaint your terminal. `--json` and `symbolicate` emit the
report's strings verbatim; treat their output as data, not as terminal text.

A dSYM from a *different* build is refused rather than used: a stale dSYM produces
confidently wrong symbols, which is worse than none. That case is reported as
`uuid_mismatch` (with the offending path in `reason`), kept distinct from `no_dsym`
because the fix is different: find the archive matching the report's build UUID, rather
than go looking for a file you may already have.

### Report tiers

`--tier` controls how much of the report is emitted; it never changes the diagnosis,
which is always computed from the full report:

| Tier | Contents |
|---|---|
| `summary` (default) | Faulting thread (capped at 15 frames), `lastExceptionBacktrace`, and the diagnosis verdict + ranked hypotheses |
| `standard` | Lifts the frame cap, and adds the binary images, other threads that contain app frames, and `factsConsidered` (the evidence behind each hypothesis) |
| `full` | Adds every remaining thread, including those with no app frames |

### Exit codes

`0` success · `64` usage error · `65` the input could not be parsed as an `.ips` report,
or symbolication failed · `66` file not found or unreadable.

Diagnostics go to stderr; stdout carries report output (and `--help`/`--version`).

### MCP server

`crashdx-mcp` exposes the same pipeline over stdio (newline-delimited JSON-RPC) as the
`crashdx_analyze` and `crashdx_symbolicate` tools. With Claude Code:

```sh
claude mcp add crashdx /usr/local/bin/crashdx-mcp
```

A matching `crash-triage` Agent Skill ships in `.claude/skills/crash-triage/`, covering
how to read the diagnosis and the interpretation pitfalls specific to each crash family.

### As a library

Add `https://github.com/r00tify/crashdx.git` to your `Package.swift`, depend on the
`CrashDXCore` product, and call
`AnalyzePipeline.analyze(path:tier:dsymPaths:useSpotlight:searchArchives:)`, the same
entry point both binaries use.

`CrashDXCore` imports nothing but `Foundation`, but two limitations are worth knowing
before you depend on it:

- **It is macOS-only.** Symbolication shells out to `atos`/`dwarfdump`/`mdfind` through
  `Foundation.Process`, which does not exist on iOS. Adding this package to an iOS target
  fails during dependency resolution, before anything compiles.
- SwiftPM resolves the whole package graph rather than a single product, so depending on
  this package pins the MCP server's dependencies (swift-sdk and its transitive NIO/
  collections/log packages) in your `Package.resolved` even if you never import them.

`AnalysisReport` and the diagnosis model are `Sendable`, so analysing a directory of
reports concurrently works as you would expect.

## Project layout

```
Sources/CrashDXCore/   Parsing, symbolication, and the diagnosis engine (imports only Foundation)
Sources/crashdx/       CLI
Sources/crashdx-mcp/   MCP server (depends on swift-sdk)
Tests/                 Unit + integration tests, golden snapshots, crash fixtures
corpus/                Ground-truth crash fixtures and their verified findings
docs/DESIGN.md         Diagnosis engine architecture
Scripts/               Fixture scrubbing and the CI privacy guard
```

## Testing

```sh
swift test
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). One rule matters more than the rest: **crash
reports and dSYMs must be scrubbed before they are committed**. They carry device
identifiers and your username. `Scripts/scrub-fixture.py` handles `.ips` files and
`Scripts/check-fixtures-scrubbed.sh` (also run in CI) will tell you if anything slipped
through.

## Security and privacy

crashdx makes no network calls; nothing leaves your machine. See [SECURITY.md](SECURITY.md)
for vulnerability reporting and for what a `.ips` file actually contains before you share
one.

## License

MIT. See [LICENSE](LICENSE).
