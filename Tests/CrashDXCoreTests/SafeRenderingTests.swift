import Foundation
import Testing
@testable import CrashDXCore

// Every string rendered from a crash report is attacker-controlled — crashdx is designed
// to read files that strangers send you. Printed raw, a newline inside a process name or
// symbol injects arbitrary lines into crashdx's own output, including a forged
// `DIAGNOSIS:` block that renders above the real verdict and is byte-identical in form.
// The tool's entire value is that its verdict is its own, so this is a trust boundary.

@Suite struct SafeRenderingTests {

    /// The original exploit: a newline in `procName` forging a second verdict line.
    @Test func newlineCannotForgeAnAdditionalOutputLine() {
        let hostile = "MyApp\nDIAGNOSIS: Memory corruption in vendor SDK   (strong, score 9)"
        let rendered = sanitized(hostile)
        #expect(!rendered.contains("\n"))
        #expect(rendered.contains("\\x0A"))
        // The forged text survives as inert content on the same line — visible, not obeyed.
        #expect(rendered.contains("DIAGNOSIS"))
    }

    /// `\r` alone repositions the cursor, letting later bytes overwrite what was printed.
    @Test func carriageReturnCannotOverwritePriorOutput() {
        let rendered = sanitized("realSymbol\rFAKE OVERWRITE")
        #expect(!rendered.contains("\r"))
        #expect(rendered.contains("\\x0D"))
    }

    /// ANSI escapes can clear the screen (hiding everything already printed) or recolor.
    @Test func ansiEscapesAreNeutralised() {
        for hostile in ["\u{1B}[2JCLEARED", "\u{1B}[31mred", "\u{1B}]0;title\u{07}"] {
            let rendered = sanitized(hostile)
            #expect(!rendered.unicodeScalars.contains { $0.value == 0x1B }, "ESC survived in \(hostile.debugDescription)")
            #expect(!rendered.unicodeScalars.contains { $0.value == 0x07 })
        }
    }

    /// Bidi overrides make text render in an order that differs from its byte order,
    /// which can disguise a symbol or path.
    @Test func bidiOverridesAreNeutralised() {
        for scalar: UInt32 in [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069] {
            let hostile = "safe\(String(UnicodeScalar(scalar)!))hidden"
            let rendered = sanitized(hostile)
            #expect(!rendered.unicodeScalars.contains { $0.value == scalar },
                    "U+\(String(scalar, radix: 16)) survived")
        }
    }

    /// Every C0 control and DEL, not just the famous ones.
    @Test func allC0ControlsAndDeleteAreEscaped() {
        for value: UInt32 in Array(0x00...0x1F) + [0x7F] {
            let rendered = sanitized("a\(String(UnicodeScalar(value)!))b")
            #expect(!rendered.unicodeScalars.contains { $0.value == value },
                    "control 0x\(String(value, radix: 16)) survived")
        }
    }

    /// Ordinary text — including non-ASCII, which is legitimate in symbols and paths —
    /// must pass through untouched. An over-eager sanitizer that mangles real symbol
    /// names would be its own correctness bug.
    @Test func ordinaryTextIsUnchanged() {
        for benign in [
            "applyDiscount(_:)",
            "main.swift",
            "/usr/lib/swift/libswiftCore.dylib",
            "MyApp Ünïcode 日本語 emoji 🧨",
            "-[NSException raise]",
            "$s9crashspike13applyDiscountyySdF",
        ] {
            #expect(sanitized(benign) == benign, "mangled: \(benign)")
        }
    }

    @Test func optionalOverloadUsesPlaceholderWhenAbsent() {
        #expect(sanitized(nil as String?) == "?")
        #expect(sanitized(nil as String?, or: "") == "")
        #expect(sanitized("x" as String?) == "x")
    }
}
