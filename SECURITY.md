# Security

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
(the **Security** tab → *Report a vulnerability*) rather than opening a public issue.

## What crashdx does with your data

crashdx makes **no network calls**: neither `CrashDXCore` nor either executable opens a
socket, and `crashdx-mcp` speaks only over stdio. Crash reports, dSYMs, and everything
derived from them are read and written locally and never transmitted anywhere. There is no
telemetry, no crash upload, and no LLM call anywhere in the engine. The diagnosis is
produced by deterministic rules.

Subprocesses it invokes, all shipped with macOS or Xcode: `/usr/bin/python3` (to run
Apple's `CrashSymbolicator.py`), `atos` as a symbolication fallback, `/usr/bin/dwarfdump`
(to read dSYM UUIDs, falling back to `xcrun dwarfdump`), `mdfind` (Spotlight dSYM
discovery, disable with `--no-spotlight`), and `xcode-select`.

## Handling crash reports safely

`.ips` files are **not** anonymous. A crash report contains `crashReporterKey` (a stable
per-device/per-install identifier), boot and sleep-wake session UUIDs, the device model,
the responsible process name, filesystem paths, timestamps revealing the local timezone,
and raw memory in `instructionByteStream`.

Treat crash reports from your users as personal data:

- Scrub before sharing one in a bug report or attaching it to an issue.
  `Scripts/scrub-fixture.py` replaces the stable identifiers wherever they appear, at any
  nesting depth: `crashReporterKey`, boot and sleep-wake UUIDs, device model,
  coalition/responsible process, log-writing signature, `codeSigningTeamID` (your Apple
  Developer Team ID), `deviceIdentifierForVendor` (the IDFV), and `userID`. It drops
  Apple's rollout and feature-status blobs and the App Store referrer trail (`trialInfo`,
  `appleIntelligenceStatus`, `storeCohortMetadata`), neutralises the timestamps' UTC
  offset, replaces the incident UUID with one derived from the report's own content, and
  rewrites identifying absolute paths (`/Users/<name>`, `/Volumes/<name>`, `/var/root`,
  `/private/var/folders/…`). It does **not** remove `instructionByteStream` (raw memory)
  or `vmSummary`, and it cannot know which application-specific strings are sensitive;
  review those by hand.
- `crashdx analyze --json` output inherits these fields from its input; don't paste it
  into a public issue unscrubbed.
- crashdx also *adds* one thing the input didn't have: on a `uuid_mismatch`, the `reason`
  string names the rejected dSYM by absolute path, which will typically sit under
  `/Users/<you>/Library/Developer/Xcode/Archives/…` and can name your other projects.
  Strip it before sharing, or re-run with `--no-spotlight --no-archives` and an
  explicit `--dsym`, which restricts the search to paths you name.
- The `full` tier includes every thread in the process. Prefer `summary` when sharing.
- Report strings are escaped before crashdx prints its human-readable summary (C0
  controls, DEL, and bidi overrides render as `\x0A` / `\u{202E}`), so a crafted report
  cannot inject a forged verdict line or ANSI escapes into crashdx's own output.
  `--json` and `symbolicate` emit those strings verbatim; treat that output as untrusted
  data rather than as text to print to a terminal.
