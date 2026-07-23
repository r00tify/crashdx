#!/usr/bin/env python3
"""Verify that every tracked fixture and dSYM is scrubbed. Run by CI.

Checks PARSED JSON, not file text. An earlier grep-based version was bypassable by a tab
between key and colon, a newline before the value, a `\\u0063` escape in a key name, a
nested copy of a covered field, and an ISO-8601 `+04:00` offset — all of which are
invisible to a regex over the raw bytes and completely visible to `json.loads`.

Field definitions come from `ips_scrub.py`, shared with `scrub-fixture.py`.
"""
import json
import os
import sys

import ips_scrub as S

# Text fixtures worth checking, by extension. `.crash` is the legacy report format;
# goldens are generated from fixtures and inherit whatever those carried.
TEXT_SUFFIXES = ('.ips', '.crash', '-golden.json')
SKIP_DIRS = {'.build', '.git', 'raw'}

errors = []


def err(path, message):
    errors.append(f'::error file={path}::{message}')


def check_json_tree(path, node):
    """Walk the parsed tree; flag identifying values wherever they appear, at any depth."""
    def on_pair(key, value, where):
        if key in S.DROP:
            err(path, f'{where}.{key} should be dropped — run Scripts/scrub-fixture.py')
        elif key in S.REPLACE and value != S.REPLACE[key]:
            err(path, f'unscrubbed {key} at {where} — run Scripts/scrub-fixture.py')
        elif key in S.TIMESTAMP_FIELDS and isinstance(value, str):
            # Compare each matched offset, not a substring of the whole value: an ISO
            # timestamp that is legitimately UTC renders as `+00:00`, which a naive
            # `'+0000' in value` test would flag as a leak.
            bad = [o for o in S.UTC_OFFSET_RE.findall(value)
                   if o.replace(':', '') != '+0000']
            if bad:
                err(path, f'{where}.{key} keeps a local UTC offset {bad[0]!r} '
                          f'— run Scripts/scrub-fixture.py')
        return None, key, value

    def on_str(text, where):
        for leak in S.path_leaks(text):
            err(path, f'identifying path {leak!r} at {where} — run Scripts/scrub-fixture.py')
        return text

    S.walk(node, on_str=on_str, on_pair=on_pair)


def check_text_file(path):
    raw = open(path, encoding='utf-8', errors='replace').read()
    docs = []
    if '\n' in raw.strip():
        head, rest = raw.split('\n', 1)
        for chunk in (head, rest):
            try:
                docs.append(json.loads(chunk))
            except json.JSONDecodeError:
                pass
    if not docs:
        try:
            docs = [json.loads(raw)]
        except json.JSONDecodeError:
            # Not JSON we can parse — fall back to a raw scan so it is never skipped.
            for leak in S.path_leaks(raw):
                err(path, f'identifying path {leak!r} (file is not parseable JSON)')
            return
    for doc in docs:
        check_json_tree(path, doc)


def check_binary_file(path):
    """dSYM members: scan as UTF-8 and as UTF-16LE.

    dsymutil writes the absolute build directory into the DWARF and into
    Contents/Resources/Relocations/**/*.yml, and a binary Info.plist can hold UTF-16
    strings that a byte-oriented scan reads as interleaved NULs.
    """
    data = open(path, 'rb').read()
    seen = set()
    for decoded in (data.decode('utf-8', errors='ignore'),
                    data.decode('utf-16-le', errors='ignore')):
        for leak in S.path_leaks(decoded):
            if leak in seen:
                continue
            seen.add(leak)
            err(path, f'dSYM embeds {leak!r} — see CONTRIBUTING.md')


def main():
    root = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(root)          # repo root, whatever the caller's cwd is
    os.chdir(root)

    text_seen = binary_seen = 0
    for dirpath, dirnames, filenames in os.walk('.'):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        in_dsym = '.dSYM' in dirpath
        for name in filenames:                      # os.walk handles every filename,
            full = os.path.join(dirpath, name)      # including spaces and newlines
            lower = name.lower()
            if in_dsym:
                check_binary_file(full)
                binary_seen += 1
            elif any(lower.endswith(s) for s in TEXT_SUFFIXES):
                check_text_file(full)
                text_seen += 1

    for line in errors:
        print(line)
    if errors:
        print(f'\n{len(errors)} problem(s) found across {text_seen} report(s) '
              f'and {binary_seen} dSYM file(s).', file=sys.stderr)
        return 1
    print(f'OK: {text_seen} report(s) and {binary_seen} dSYM file(s) are scrubbed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
