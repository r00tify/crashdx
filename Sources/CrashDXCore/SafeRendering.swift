import Foundation

// MARK: - Untrusted-text rendering

/// Renders a string from the crash report safe to print on its own line.
///
/// Every string below — process name, image name, symbol, exception type, hypothesis
/// title — comes from a file the user did not write. crashdx's stated job is reading
/// reports that strangers emailed you, so those strings are attacker-controlled.
///
/// Printed raw, a newline inside any of them injects arbitrary lines into crashdx's own
/// output, including a forged `DIAGNOSIS:` block that renders above the real verdict and
/// is byte-identical in form. `\r` overwrites the current line, and an ANSI escape can
/// clear the screen or recolor text to hide what came before. The tool's credibility
/// rests on its output being its own, so control characters are escaped rather than
/// emitted: C0, DEL, and the bidi overrides that let text render out of order.
public func sanitized(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x00...0x1F, 0x7F:                      // C0 controls incl. \n \r ESC, and DEL
            out += String(format: "\\x%02X", scalar.value)
        case 0x202A...0x202E, 0x2066...0x2069:       // bidi embedding/override/isolate
            out += String(format: "\\u{%04X}", scalar.value)
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}

/// `sanitized` for an optional, falling back to `placeholder` when absent.
public func sanitized(_ text: String?, or placeholder: String = "?") -> String {
    text.map(sanitized) ?? placeholder
}
