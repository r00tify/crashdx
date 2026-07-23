#!/usr/bin/env python3
"""Shared definitions for scrubbing and verifying `.ips` fixtures.

`scrub-fixture.py` (writer) and `check-fixtures-scrubbed.sh` (verifier) both import this
module, so the two can never disagree about which fields are identifying or what a
scrubbed value looks like. Previously each kept its own table and they silently drifted.

Everything here operates on PARSED JSON, never on raw text. Grepping JSON is
unsound — a value is reachable through tab separators, newlines between key and colon,
`\\u0063` escapes in key names, and nesting, all of which a regex over the file text
misses while `json.loads` sees straight through them.
"""
import re

ZERO_UUID = '00000000-0000-0000-0000-000000000000'
BOOT_UUID = '11111111-1111-1111-1111-111111111111'
WAKE_UUID = '22222222-2222-2222-2222-222222222222'

# Identifying field -> the value it must hold once scrubbed. Matched at ANY depth: some
# reports nest these (e.g. storeInfo.deviceIdentifierForVendor, legacyInfo.modelCode).
REPLACE = {
    'crashReporterKey': ZERO_UUID,   # stable per-device/per-install identifier
    'bootSessionUUID': BOOT_UUID,
    'sleepWakeUUID': WAKE_UUID,
    'modelCode': 'Mac00,0',          # pins exact hardware
    'coalitionName': 'com.example.terminal',
    'responsibleProc': 'terminal',
    'logWritingSignature': '0' * 40,
    # A globally-resolvable pointer to a named Apple Developer account — arguably more
    # identifying than crashReporterKey, which is at least opaque.
    'codeSigningTeamID': '0000000000',
    'deviceIdentifierForVendor': ZERO_UUID,   # IDFV: stable per-device
    'userID': 501,
}

# Fields with no diagnostic value that are identifying if present: Apple A/B rollout
# blobs, feature-status blobs, and the App Store search-referrer trail.
DROP = ('trialInfo', 'appleIntelligenceStatus', 'storeCohortMetadata')

# Timestamp fields whose UTC offset reveals the author's timezone. Matched at any depth.
TIMESTAMP_FIELDS = ('captureTime', 'procLaunch', 'timestamp')

# Absolute paths that name a person or machine. Ordered longest-prefix-first so the
# replacement of a more specific form wins.
#
# `[^/]+` rather than a character class: usernames may contain spaces, unicode, and
# punctuation, and a narrower class silently truncates the match — leaving the surname of
# "John Doe" behind while the checker sees a clean "/Users/USER".
PATH_PATTERNS = [
    # /Users//name and /Users/name both normalise to /Users/USER. The lookahead also
    # spares `builder`, the placeholder CONTRIBUTING.md tells contributors to patch dSYM
    # build paths to, so an already-scrubbed path is a fixed point.
    (re.compile(r'/Users/+(?!(?:USER|builder)(?:/|$))[^/]+'), '/Users/USER'),
    # Build systems flatten paths into directory names: .../-Users-alice-Developer-...
    (re.compile(r'-Users-(?!builder-|USER-)[^-/]+'), '-Users-builder'),
    (re.compile(r'/private/var/folders/[^/]+/[^/]+'), '/private/var/folders/AA/BBBB'),
    (re.compile(r'/var/root'), '/var/USER'),
    (re.compile(r'/Volumes/(?!VOLUME(?:/|$))[^/]+'), '/Volumes/VOLUME'),
]

# Any offset other than +0000, either sign, any magnitude, with or without the ISO colon.
#
# Deliberately NO negative lookbehind: an ISO-8601 timestamp puts the offset flush against
# a digit (`…17.2410+04:00`), so requiring a non-digit before it silently skipped every
# ISO-formatted report. The date portion (`2026-07-15`) cannot match, because after
# `-07` the next two characters are `-1`, not two digits.
UTC_OFFSET_RE = re.compile(r'[+-][0-9]{2}:?[0-9]{2}(?![0-9])')


def redact_paths(text):
    """Rewrite every identifying absolute path form in `text`."""
    for pattern, replacement in PATH_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


def strip_offset(text):
    return UTC_OFFSET_RE.sub('+0000', text)


def path_leaks(text):
    """Identifying path fragments in `text`.

    Defined as "what `redact_paths` would rewrite", using the very same patterns — not a
    second regex describing the same shapes. Keeping two independent descriptions is what
    previously let the verifier reject the scrubber's OWN output: the rewriter produced
    `/private/var/folders/AA/BBBB` while the detector matched only one path component and
    reported `/private/var/folders/AA` as a leak, an error no amount of re-scrubbing could
    clear.
    """
    leaks = []
    for pattern, replacement in PATH_PATTERNS:
        for match in pattern.finditer(text):
            if match.group(0) != replacement:
                leaks.append(match.group(0))
    return leaks


def walk(node, on_str=None, on_pair=None, path='$'):
    """Rebuild a JSON tree, applying `on_pair(key, value, path)` to every mapping entry
    and `on_str(text, path)` to every string — including dict KEYS, which an earlier
    version skipped, letting a `/Users/<name>` path survive as a key at any depth."""
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if on_pair is not None:
                handled, k, v = on_pair(k, v, path)
                if handled == 'drop':
                    continue
                if handled == 'replaced':
                    out[k] = v
                    continue
            new_k = on_str(k, f'{path}.{k}') if (on_str and isinstance(k, str)) else k
            # Two distinct keys can redact to the SAME string (`/Users/alice/x` and
            # `/Users/bob/x` both become `/Users/USER/x`). Writing blind would silently
            # drop one sibling, so disambiguate instead of losing data.
            if new_k in out:
                suffix = 2
                while f'{new_k}#{suffix}' in out:
                    suffix += 1
                new_k = f'{new_k}#{suffix}'
            out[new_k] = walk(v, on_str, on_pair, f'{path}.{k}')
        return out
    if isinstance(node, list):
        return [walk(v, on_str, on_pair, f'{path}[{i}]') for i, v in enumerate(node)]
    if isinstance(node, str) and on_str is not None:
        return on_str(node, path)
    return node
