# crashdx

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
git clone https://github.com/<owner>/crashdx.git
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

Add `https://github.com/<owner>/crashdx.git` to your `Package.swift`, depend on the
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
