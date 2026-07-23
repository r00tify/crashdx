#!/usr/bin/env python3
"""Scrub machine-identifying data out of an .ips crash report before committing it.

Real .ips files carry a full device envelope. Every fixture in this repo MUST be run
through this script before it is committed — see CONTRIBUTING.md.

    Scripts/scrub-fixture.py path/to/report.ips [more.ips ...]

Rewrites in place, preserving the canonical two-JSON-document .ips shape (header line,
newline, payload). The exception/termination/thread/image/asi/vmregioninfo data the
diagnosis engine reasons over is left alone; identifying metadata around it is replaced.

The field tables live in `Scripts/ips_scrub.py`, shared with
`Scripts/check-fixtures-scrubbed.sh` so the writer and the verifier cannot drift.

Idempotent: the placeholder incident UUID is derived from the crash's own content, so
re-running never produces a diff, and moving or renaming a fixture doesn't change it.

This does NOT touch dSYMs — those embed the build directory in DWARF and in
Contents/Resources/Relocations/**/*.yml. See CONTRIBUTING.md for that procedure.
"""
import hashlib
import json
import sys

import ips_scrub as S


class NotATwoDocumentIPS(Exception):
    pass


def scrub_tree(node):
    """Apply the field table and path/timestamp redaction at EVERY depth.

    Depth matters: an earlier version only rewrote top-level keys while the verifier
    grepped the whole file, so a nested `legacyInfo.modelCode` produced a CI failure the
    scrubber could not fix — the tool told contributors to run something that provably
    would not help.
    """
    def on_pair(key, value, _path):
        if key in S.DROP:
            return 'drop', key, value
        if key in S.REPLACE:
            return 'replaced', key, S.REPLACE[key]
        if key in S.TIMESTAMP_FIELDS and isinstance(value, str):
            return 'replaced', key, S.strip_offset(value)
        return None, key, value

    def on_str(text, _path):
        return S.redact_paths(text)

    return S.walk(node, on_str=on_str, on_pair=on_pair)


def content_seeded_uuid(payload):
    """Stable synthetic UUID derived from the crash's own content.

    Excludes the incident fields themselves, so the result does not depend on what was
    there before — that is what makes re-running this script a no-op.
    """
    skeleton = {k: v for k, v in payload.items() if k != 'incident'}
    digest = hashlib.sha256(
        json.dumps(skeleton, sort_keys=True, ensure_ascii=False).encode('utf-8')
    ).hexdigest()
    # Force the RFC-4122 version (4) and variant (8) nibbles so the result is a
    # well-formed UUID a strict consumer will accept.
    return (f'{digest[0:8]}-{digest[8:12]}-4{digest[13:16]}-'
            f'8{digest[17:20]}-{digest[20:32]}').upper()


def scrub(path):
    raw = open(path, encoding='utf-8').read()
    if '\n' not in raw.strip():
        raise NotATwoDocumentIPS(path)
    head_line, payload_text = raw.split('\n', 1)
    try:
        header, payload = json.loads(head_line), json.loads(payload_text)
    except json.JSONDecodeError as exc:
        raise NotATwoDocumentIPS(f'{path}: {exc}') from exc

    pretty = '\n' in payload_text.strip()
    header, payload = scrub_tree(header), scrub_tree(payload)

    # Derived last, from the fully scrubbed payload, so it is stable across re-runs.
    incident = content_seeded_uuid(payload)
    if 'incident' in payload:
        payload['incident'] = incident
    if 'incident_id' in header:
        header['incident_id'] = incident

    out = json.dumps(header, separators=(',', ':'), ensure_ascii=False) + '\n'
    out += (json.dumps(payload, indent=2, ensure_ascii=False) if pretty
            else json.dumps(payload, separators=(',', ':'), ensure_ascii=False))
    if not out.endswith('\n'):
        out += '\n'

    before = raw
    open(path, 'w', encoding='utf-8').write(out)
    return before != out


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    status = 0
    for p in sys.argv[1:]:
        try:
            print(f'{p}: {"rewritten" if scrub(p) else "already clean (no change)"}')
        except NotATwoDocumentIPS as exc:
            print(f'error: not a two-document .ips file: {exc}', file=sys.stderr)
            status = 1
        except OSError as exc:
            print(f'error: {exc}', file=sys.stderr)
            status = 1
    sys.exit(status)
