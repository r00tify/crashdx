# Contributing to crashdx

## Build and test

```sh
swift build
swift test                                  # Swift Testing, not XCTest
swift test --filter DiagnosisEngineTests    # one suite (regex match on the name)
```

You need **Xcode installed, not just the Command Line Tools** — symbolication runs Apple's
`CrashSymbolicator.py` out of Xcode's `CoreSymbolicationDT.framework`, found via
`xcode-select -p`. Without it the symbolication tests exercise only the inferior `atos`
fallback. Swift 6.2+ is required (see the README's Requirements).

There is also a manual MCP protocol check, not part of `swift test`:

```sh
python3 Tests/mcp-smoke.py .build/debug/crashdx-mcp
```

## Scrubbing fixtures — required, no exceptions

**Never commit an `.ips` file or a `.dSYM` without scrubbing it first.** Crash reports
harvested from a real machine carry `crashReporterKey` (Apple's stable per-device
identifier), boot and sleep-wake UUIDs, your exact hardware model, the responsible process
name, and your timezone. dSYMs additionally embed the build directory — and therefore your
username — in DWARF `DW_AT_comp_dir` and in `Contents/Resources/Relocations/**/*.yml`,
inside binary files that reviewing the diff will never show you.

This applies to files you consider "synthetic" too: a synthetic *crash scenario* built by
editing a real report's payload still carries the original machine's envelope.

For `.ips` files:

```sh
Scripts/scrub-fixture.py path/to/new-fixture.ips
```

It rewrites matching fields at any depth and is idempotent — the placeholder incident
UUID is derived from the crash's own content, so re-running never produces a diff. To
cover a new identifying field, add it to `Scripts/ips_scrub.py`: the scrubber and the
checker both import that table, so they cannot disagree about what "scrubbed" means.

dSYMs need separate treatment. `dsymutil` records the absolute build directory in the
DWARF (`DW_AT_comp_dir`) and again in `Contents/Resources/Relocations/**/*.yml`.

**Keep your username out of the dSYM in the first place** — pass `-debug-prefix-map` to
*both* compile steps. This is the only approach that works regardless of how long your
username is:

```sh
swiftc -g -debug-prefix-map "$PWD=/Users/builder/fixture" -c main.swift -o main.o
swiftc -g -debug-prefix-map "$PWD=/Users/builder/fixture" main.o -o myfixture
dsymutil myfixture
dwarfdump --debug-info myfixture.dSYM | grep DW_AT_comp_dir   # -> /Users/builder/fixture
```

Patching an existing dSYM after the fact only works if the replacement is **byte-for-byte
the same length** — unequal lengths shift section offsets and corrupt the Mach-O, after
which `dwarfdump` can no longer read the UUID the `.ips` refers to. Since the checker
accepts only the literal placeholders `USER` and `builder` (see `PATH_PATTERNS` in `Scripts/ips_scrub.py`), in-place patching only works when your username is exactly 4 or
7 bytes. Prefer `-debug-prefix-map` and rebuild.

Verify before opening a PR — this is the exact check CI runs:

```sh
./Scripts/check-fixtures-scrubbed.sh
grep -ril "$(whoami)" --exclude-dir=.build .             # belt and braces
```

## Adding a diagnosis rule

Rules live in `Sources/CrashDXCore/Diagnosis/Rules/` and are registered in
`DiagnosisEngine.defaultRules`. The engine itself should not need to change. Read
[docs/DESIGN.md](docs/DESIGN.md) first — the scoring model and the honest-inconclusive
stance are deliberate, and `CLAUDE.md` summarizes the architecture.

Every rule needs **both** a positive fixture-driven test and a negative one (the rule must
not fire on an unrelated crash). If your rule can co-fire with an existing one, also assert
on the resulting **verdict**, not merely that your rule fired — a hypothesis can fire and
still lose to a wrong one. See `stackGuardRegionPreventsConfidentNullDereferenceVerdict`.

Prefer citing a `contradicting` fact over suppressing a competing rule. A direct
observation (e.g. `vmregioninfo` naming a STACK GUARD region) should outweigh another
rule's inference, but both hypotheses should stay visible with their evidence.

## Building a new crash fixture

The two-step compile matters — a single-step `swiftc -g` deletes the temporary object
files before `dsymutil` can read them, producing a hollow dSYM with no DWARF:

```sh
# -debug-prefix-map keeps your username out of the dSYM (see the scrubbing section).
swiftc -g -debug-prefix-map "$PWD=/Users/builder/fixture" -c main.swift -o main.o
swiftc -g -debug-prefix-map "$PWD=/Users/builder/fixture" main.o -o myfixture
dsymutil myfixture
strip -x myfixture
./myfixture                                  # let it crash
cp ~/Library/Logs/DiagnosticReports/myfixture-*.ips .
Scripts/scrub-fixture.py myfixture-*.ips     # ← required
```

Document the ground truth: the dSYM UUID, the exact source line of the crash, and
anything empirically surprising. Fixtures under `corpus/fixtures/` are documented in
`corpus/README.md`; fixtures added only to `Tests/CrashDXCoreTests/Fixtures/` belong in
the header comment of the test file that uses them. Those notes are load-bearing —
several parsing decisions cite them.
