# Test Corpus

The `fixtures/` directories below are tracked in git: each is a small purpose-built crash
program with known ground truth, its dSYM, and the report harvested from an actual crash
of it. Their documented findings are the empirical basis for several parsing and diagnosis
decisions. Read them before "correcting" behavior that looks wrong.

> **"Synthetic" describes the crash scenario, not the file's provenance.** These reports
> were produced by real crashes on a real machine, so they arrived carrying the full
> device envelope (`crashReporterKey`, boot/sleep-wake UUIDs, model code, responsible
> process, local timezone), and the dSYMs carried the build directory path in their DWARF.
> All of it has been scrubbed: identifying fields are replaced with fixed placeholders,
> and no dSYM records a real home directory. `nullderef.dSYM` was patched in place with an
> equal-length replacement (unequal lengths shift Mach-O section offsets and corrupt the
> file); `crashspike.dSYM` and `nsexcrash.dSYM` were built in a scratch directory, so
> their `DW_AT_comp_dir` records that build path rather than a user's home. Either way
> every `LC_UUID` still matches the `.ips` that references it.
>
> **Any new fixture must be scrubbed the same way before being committed.** See
> CONTRIBUTING.md.

## raw/ (local-only, never committed)

**`raw/` is gitignored and must stay that way.** Real `.ips` files contain
`crashReporterKey`, device model codes, usernames in paths, responsible-process names, and
`instructionByteStream` blobs. Scrub or regenerate before publishing any real report.

To populate it locally for exploratory work, copy reports out of
`~/Library/Logs/DiagnosticReports/` (they appear there within ~2–4 seconds of a crash).
Reports observed there are `bug_type` **309**, including `ExcUserFault_*` files
(user-fault, non-fatal), empirical confirmation that 309 covers more than hard crashes.

Sections below cite individual `corpus/raw/*.ips` filenames as the provenance for
parsing decisions. Those files are not distributed: the citations record where a finding
came from, they are not reproducible artifacts.

**Fixtures wanted:** jetsam, hang (stackshot), spindump, watchdog, and iOS-device
reports. On iOS these come from Settings → Privacy & Security → Analytics &
Improvements → Analytics Data. Those families are currently exercised only by synthetic
payload-injection fixtures (see `Tests/CrashDXCoreTests/Fixtures/synthetic/`).

## fixtures/crashspike/ (purpose-built ground-truth fixture)

A deliberate Swift force-unwrap crash (`EXC_BREAKPOINT`/`SIGTRAP`) with full known ground
truth for symbolication testing:

- `main.swift`: source; the crash is the force-unwrap at **line 10** in
  `applyDiscount(_:)`, called from `processOrder(_:)` (line 14) ← `run()` (line 19).
- `crashspike.dSYM`: UUID `657A6675-2D2C-32CA-8C31-3A8C948DF5FE` (arm64).
- `unstripped.ips`: crash of the binary before stripping.
- `stripped.ips`: crash of the stripped binary. Note it still arrives fully
  symbolicated: ReportCrash resolves it locally via Spotlight (finding 2 below). The
  genuinely unsymbolicated fixture used by the symbolication tests is
  `Tests/CrashDXCoreTests/Fixtures/crashspike-unsymbolicated.ips`, derived from this file
  by stripping the symbol fields from every frame.

### Verified pipeline findings

1. **Build recipe matters.** A single-step `swiftc -g` deletes the temporary objects
   before `dsymutil` reads them, yielding a hollow 8KB dSYM with no DWARF. Use:

   ```sh
   swiftc -g -c main.swift -o main.o && swiftc -g main.o -o app && dsymutil app
   ```
2. **ReportCrash auto-symbolicates locally**, even for stripped binaries, because
   CoreSymbolication finds the dSYM via Spotlight on the same machine. Implication: the
   tool's value concentrates on *foreign* reports (user-submitted, TestFlight, CI) where
   the dSYM isn't on the crashing machine, and on adding file:line + diagnosis, which
   ReportCrash never includes.
3. **CrashSymbolicator.py works as the primary engine.** It outputs a header line plus
   enriched JSON carrying `symbol`, `sourceFile`, `sourceLine` per frame:

   ```sh
   python3 "$(xcode-select -p)/../SharedFrameworks/CoreSymbolicationDT.framework/Versions/A/Resources/CrashSymbolicator.py" \
       -d app.dSYM report.ips
   ```

   Caveats: it is not directly executable (`permission denied`; invoke via `python3`),
   and it prints a "Symbolicating thread N" status line to **stdout** before the JSON, so
   parsers must skip it. `-p` pretty-prints.
4. **atos fallback works but is inferior:** requires hex (`.ips` stores decimal; convert),
   `-offset` maps directly to frame `imageOffset`, but it resolved the faulting frame to
   `/<compiler-generated>:0` where CrashSymbolicator.py correctly produced `main.swift:10`.
   Use as fallback only.
5. Crash reports appear in `~/Library/Logs/DiagnosticReports/` within ~2-4 seconds of the
   crash.

## fixtures/nsexcrash/ (purpose-built uncaught-NSException fixture)

A CLI Swift binary that raises an uncaught `NSException` through two named functions,
built and harvested exactly like `crashspike` (same `-g -c` + `-g` two-step recipe, then
`dsymutil`, then `strip`):

- `main.swift`: `doWork()` calls `throwingHelper()`, which raises
  `NSException(name: .rangeException, reason: "crashdx fixture: index 42 beyond bounds")`.
- `nsexcrash.dSYM`: UUID `AF44F940-3B8B-30E8-B88A-0297504B10D2` (arm64).
- `nsexcrash.ips`: the harvested crash report (`bug_type` 309), scrubbed per the note at
  the top of this file. The exception/termination/thread/image/`asi`/`vmregioninfo` data
  the diagnosis engine reasons over is unchanged; `captureTime`, `timestamp` and the
  incident UUIDs were rewritten and the payload re-serialized.

### Ground truth (verified empirically, do not assume otherwise)

- **`lastExceptionBacktrace` IS present** for this CLI process: 7 frames, each carrying
  `imageIndex` + `imageOffset` as documented; the 3 innermost app frames (`nsexcrash`,
  `imageIndex` 0) are unsymbolicated in the raw report (`start()` → `doWork()` →
  `throwingHelper()`, offsets 2596/2620/2756) since the binary was stripped before
  crashing. The primary Swift-NSException recipe produces a `lastExceptionBacktrace` on
  macOS.
- **`exception`**: `{"type": "EXC_CRASH", "signal": "SIGABRT", "codes": "0x0…, 0x0…"}`.
  **`termination`**: `SIGNAL` / code 6 / `"Abort trap: 6"`. This is the *abort*, not the
  original exception. The exception type/signal fields do **not** mention
  `NSRangeException` anywhere; that only shows up in the LEB's resolved symbols
  (`objc_exception_throw`, `-[NSException raise]` in the faulting thread) and in the
  process's own stderr output (not captured in the .ips at all).
- **`asi` is present but contains only `{"libsystem_c.dylib": ["abort() called"]}`.** It
  does **NOT** contain the classic
  `*** Terminating app due to uncaught exception 'NAME', reason: 'REASON'` string. That message *is* printed to stderr by the objc runtime's
  default terminate handler (verified: it's in the process's console output), but it is
  **never written into the crash report's `asi` field** for a plain CLI/Foundation
  process. Installing a custom `NSSetUncaughtExceptionHandler` (mirroring what `NSApplicationMain`/`UIApplicationMain`
  install) did not change this: `asi` stayed `{"libsystem_c.dylib": ["abort() called"]}`.
  This matches five independent real-world files in `corpus/raw/` (four `swift-frontend`
  SIGABRT crashes and the GitHub Xcode extension crash all have the identical
  `{"libsystem_c.dylib": ["abort() called"]}` shape). **Conclusion:** the
  `'*** Terminating app due to uncaught exception'` pattern in `asi` appears to be an
  AppKit/UIKit-installed-handler phenomenon, not a general Foundation/CLI one; crashdx's
  `uncaughtExceptionName`/`uncaughtExceptionReason` parsing is exercised by this fixture
  as a **negative case** (correctly returns `nil`) and by a synthetic-`asi` unit test for
  the **positive** (pattern-present) case.
- `asi`'s shape confirms the assumed structure: `[String: [String]]`, keyed by the
  originating library/dylib name (here `libsystem_c.dylib`; `CoreFoundation` was seen
  keyed similarly in other exploratory runs), values are arrays of message strings.

## fixtures/nullderef/ (purpose-built null-pointer-dereference fixture)

A CLI Swift binary that dereferences a genuine null pointer (`EXC_BAD_ACCESS`/`SIGSEGV`),
built and harvested the same way as `crashspike`/`nsexcrash` (`swiftc -g -c` + `swiftc -g`
two-step, `dsymutil`, `strip -x`, run until it crashes, copy the harvested report):

- `main.swift`: `readThroughNullPointer()` does
  `unsafeBitCast(0 as Int, to: UnsafeMutablePointer<Int>.self).pointee`.
  This specific construction matters: a plain
  `UnsafePointer<Int>(bitPattern: 0)` is `nil` as an *Optional* pointer, and force-unwrapping
  that nil optional (`ptr!.pointee`) traps via the Swift runtime's own nil-check
  (`EXC_BREAKPOINT`/`SIGTRAP`, the crashspike family), NOT a real kernel memory fault.
  `unsafeBitCast` constructs a *non-optional* pointer value whose address is literally 0,
  bypassing that check entirely, so dereferencing it reaches the kernel and produces a
  genuine `KERN_INVALID_ADDRESS` SIGSEGV. The crash is the `.pointee` read at **line 9**,
  called from `run()` at **line 13**.
- `nullderef.dSYM`: UUID `16F8AE74-C36B-39AF-B0D8-DA69B83EC96B` (arm64).
- `nullderef.ips`: the harvested crash report (`bug_type` 309), scrubbed per the note at
  the top of this file. The exception/termination/thread/image/`asi`/`vmregioninfo` data
  the diagnosis engine reasons over is unchanged; `captureTime`, `timestamp` and the
  incident UUIDs were rewritten and the payload re-serialized.

### Ground truth

Verified empirically; do not assume otherwise. `MemoryFactsExtractor.swift` and
`RegisterFactsExtractor.swift` carry the same facts as doc comments where they're relied on
in code.

- **`exception`**:

  ```json
  {"type": "EXC_BAD_ACCESS", "signal": "SIGSEGV",
   "codes": "0x0000000000000001, 0x0000000000000000", "rawCodes": [1, 0],
   "subtype": "KERN_INVALID_ADDRESS at 0x0000000000000000"}
  ```

  The address is **always** rendered with a `0x` prefix in `subtype`, including for
  address 0. A single `at (0x[0-9A-Fa-f]+)` regex covers every case observed (this
  fixture, and the three real `EXC_BAD_ACCESS` corpus samples: one `axassetsd`, two
  `contactsd`).
- **`termination`**: `SIGNAL` / code `11` / `"Segmentation fault: 11"`.
- **`vmregioninfo`** IS present (rendered here with its embedded newlines expanded):

  ```
  0 is not in any region.  Bytes before following region: 4309172224
        REGION TYPE                    START - END         [ VSIZE] PRT/MAX SHRMOD  REGION DETAIL
        UNUSED SPACE AT START
  --->
        __TEXT                 100d8c000-100d90000    [   16K] r-x/r-x SM=COW  nullderef
  ```

  Note: the leading clause drops the `0x` prefix for address **exactly 0** specifically
  (`"0 is not in any region"`, not `"0x0 is not in any region"`), the ONLY field where
  that happens; `exception.subtype` keeps `0x` even for 0. All three real
  `EXC_BAD_ACCESS` corpus files show the general `"0xNNNN is not in any region. ..."`
  form for their (nonzero) addresses. No real sample had an address actually *contained*
  in a named region; the `"... is in a NNN region. ..."` phrasing is Apple-documented
  but unobserved in the wild. `MemoryFactsExtractor` emits a
  `memory.fault-address-in-vmregion-<type>` fact only for that containing phrasing, which
  is exercised by the synthetic `stack-overflow.ips` fixture (STACK GUARD) and by an
  in-test payload mutation for a freed `MALLOC_TINY` region. `wild-address.ips` uses the
  *non*-containing form deliberately, so that no region fact fires.
- **`threads[faultingThread].threadState`** shape (ARM64/`ARM_THREAD_STATE64`, verified
  against this fixture and `corpus/raw/contactsd-2026-07-16-140424.ips`):

  ```
  {"x": [{"value": N, "symbol"?: ..., "symbolLocation"?: ...}, ...],
   "flavor": "ARM_THREAD_STATE64",
   "lr"/"fp"/"sp"/"pc"/"far": {"value": N, "matchesCrashFrame"?: N},
   "cpsr": {"value": N},
   "esr": {"value": N, "description"?: ...}}
  ```

  Every register value is a **decimal** integer
  (unlike `exception.codes`/`subtype`'s hex-string rendering). `far.value == 0` here,
  exactly matching the parsed `exception.subtype` address — this equality is exactly why
  `NullDereferenceRule` cites `registers.far` at weight 0, not as corroboration: its value
  is a re-read of the same number `exception.subtype` already supplied, not an independent
  observation (see the rule's doc comment and `docs/DESIGN.md`'s "Known limits of the
  additive model").
- `asi` is absent entirely on this fixture (no `asiRaw`).
