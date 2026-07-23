import CrashDXCore
import Foundation

// crashdx CLI: hand-rolled subcommand + flag parsing, zero external deps.
//
//   crashdx analyze <report.ips> [--json] [--tier summary|standard|full] [--dsym <path>]... [--no-spotlight] [--no-archives]
//   crashdx symbolicate <report.ips> [--dsym <path>]... [--no-spotlight] [--no-archives]
//   crashdx --version
//   crashdx --help

let cliVersion = "crashdx 0.1.0"

// MARK: - Exit codes (BSD sysexits.h subset)

enum ExitCode {
    static let success: Int32 = 0
    static let usage: Int32 = 64      // EX_USAGE: bad flags/arguments
    static let dataErr: Int32 = 65    // EX_DATAERR: input file failed to parse
    static let noInput: Int32 = 66    // EX_NOINPUT: file not found
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("crashdx: \(message)\n".utf8))
    exit(code)
}

// MARK: - Top-level dispatch

let allArgs = Array(CommandLine.arguments.dropFirst())

func printTopLevelHelp() {
    print(
        """
        \(cliVersion)

        usage: crashdx <subcommand> [options]

        subcommands:
          analyze <report.ips>       Parse, optionally symbolicate, and summarize a crash report.
          symbolicate <report.ips>   Symbolicate a crash report; prints the enriched .ips JSON to stdout.

        options:
          --version    Print the crashdx version and exit.
          --help       Print this message and exit.

        Run `crashdx <subcommand> --help` for subcommand-specific options.
        """
    )
}

func printAnalyzeHelp() {
    print(
        """
        usage: crashdx analyze <report.ips> [options]

        Parses an .ips crash report, locates and applies dSYMs for images that need them,
        and prints either a human-readable summary or a structured JSON report.

        options:
          --json                       Print the structured AnalysisReport JSON instead of
                                       the human-readable summary.
          --tier <summary|standard|full>
                                       Report detail level (default: summary).
                                         summary   faulting thread + diagnosis
                                         standard  + images, app threads, evidence
                                         full      + every thread
          --dsym <path>                A .dSYM bundle, an .xcarchive, or a directory to
                                       search recursively. May be repeated.
          --no-spotlight               Skip the Spotlight (mdfind) dSYM search.
          --no-archives                Skip ~/Library/Developer/Xcode/Archives. Use with
                                       --no-spotlight to search only paths you name, so
                                       no other project's path can appear in the output.
          --help                       Print this message and exit.
        """
    )
}

func printSymbolicateHelp() {
    print(
        """
        usage: crashdx symbolicate <report.ips> [options]

        Symbolicates an .ips crash report and prints the enriched report as JSON to stdout.

        options:
          --dsym <path>       A .dSYM bundle, an .xcarchive, or a directory to search
                              recursively. May be repeated.
          --no-spotlight      Skip the Spotlight (mdfind) dSYM search.
          --no-archives       Skip ~/Library/Developer/Xcode/Archives.
          --help              Print this message and exit.
        """
    )
}

guard let first = allArgs.first else {
    printTopLevelHelp()
    exit(ExitCode.usage)
}

switch first {
case "--version", "-v":
    print(cliVersion)
    exit(ExitCode.success)
case "--help", "-h":
    printTopLevelHelp()
    exit(ExitCode.success)
case "analyze":
    runAnalyze(Array(allArgs.dropFirst()))
case "symbolicate":
    runSymbolicate(Array(allArgs.dropFirst()))
default:
    fail("unknown subcommand '\(first)' (expected 'analyze' or 'symbolicate'; see --help)", code: ExitCode.usage)
}

// MARK: - Shared option parsing

struct ParsedOptions {
    var positional: String?
    var dsymPaths: [URL] = []
    var useSpotlight = true
    var searchArchives = true
    var json = false
    var tier: AnalysisReport.Tier = .summary
    var wantsHelp = false
}

/// Parses flags common to both subcommands. Returns `nil` (after printing to stderr) on
/// a usage error; the caller is responsible for exiting with `ExitCode.usage`.
func parseOptions(_ args: [String], allowJSONAndTier: Bool) -> ParsedOptions? {
    var opts = ParsedOptions()
    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--help", "-h":
            opts.wantsHelp = true
        case "--json":
            guard allowJSONAndTier else {
                FileHandle.standardError.write(Data("crashdx: --json is not valid here\n".utf8))
                return nil
            }
            opts.json = true
        case "--tier":
            guard allowJSONAndTier else {
                FileHandle.standardError.write(Data("crashdx: --tier is not valid here\n".utf8))
                return nil
            }
            i += 1
            guard i < args.count else {
                FileHandle.standardError.write(Data("crashdx: --tier requires a value (summary|standard|full)\n".utf8))
                return nil
            }
            guard let tier = AnalysisReport.Tier(rawValue: args[i]) else {
                FileHandle.standardError.write(Data("crashdx: invalid --tier '\(args[i])' (expected summary|standard|full)\n".utf8))
                return nil
            }
            opts.tier = tier
        case "--dsym":
            i += 1
            guard i < args.count else {
                FileHandle.standardError.write(Data("crashdx: --dsym requires a path\n".utf8))
                return nil
            }
            opts.dsymPaths.append(URL(fileURLWithPath: args[i]))
        case "--no-spotlight":
            opts.useSpotlight = false
        case "--no-archives":
            opts.searchArchives = false
        default:
            if arg.hasPrefix("-") {
                FileHandle.standardError.write(Data("crashdx: unrecognized option '\(arg)'\n".utf8))
                return nil
            }
            guard opts.positional == nil else {
                FileHandle.standardError.write(Data("crashdx: unexpected extra argument '\(arg)'\n".utf8))
                return nil
            }
            opts.positional = arg
        }
        i += 1
    }
    return opts
}

/// Maps an `AnalyzePipeline.PipelineError` to its stderr message and exit code. Shared by
/// both subcommands so `analyze` and `symbolicate` report file-not-found, unreadable,
/// parse, and symbolication failures identically.
func failForPipelineError(_ error: AnalyzePipeline.PipelineError) -> Never {
    switch error {
    case .fileNotFound, .unreadable:
        fail(error.description, code: ExitCode.noInput)
    case .parseFailed, .symbolicationFailed:
        fail(error.description, code: ExitCode.dataErr)
    }
}

// MARK: - analyze

func runAnalyze(_ args: [String]) -> Never {
    guard let opts = parseOptions(args, allowJSONAndTier: true) else {
        exit(ExitCode.usage)
    }
    if opts.wantsHelp {
        printAnalyzeHelp()
        exit(ExitCode.success)
    }
    guard let path = opts.positional else {
        FileHandle.standardError.write(Data("crashdx: analyze requires a path to an .ips file\n".utf8))
        printAnalyzeHelp()
        exit(ExitCode.usage)
    }

    let result: AnalyzePipeline.AnalyzeResult
    do {
        result = try AnalyzePipeline.analyze(
            path: path, tier: opts.tier, dsymPaths: opts.dsymPaths,
            useSpotlight: opts.useSpotlight, searchArchives: opts.searchArchives
        )
    } catch let error as AnalyzePipeline.PipelineError {
        failForPipelineError(error)
    } catch {
        fail("\(error)", code: ExitCode.dataErr)
    }

    if opts.json {
        printJSON(result.report)
    } else {
        printHumanSummary(result.report)
        printDiagnosisSection(result.diagnosis, file: result.diagnosedFile)
    }
    exit(ExitCode.success)
}

func printJSON(_ report: AnalysisReport) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        fail("failed to encode report as JSON: \(error)", code: ExitCode.dataErr)
    }
    exit(ExitCode.success)
}

func printHumanSummary(_ report: AnalysisReport) {
    print("process:    \(sanitized(report.process.name))")
    print("bug_type:   \(sanitized(report.event.bugType))")
    print("os:         \(sanitized(report.process.osVersion))")
    print("exception:  \(sanitized(report.event.exceptionType)) (\(sanitized(report.event.signal)))")
    print("terminated: \(sanitized(report.event.terminationIndicator))")
    if let name = report.event.uncaughtExceptionName {
        print("uncaught:   \(sanitized(name)): \(sanitized(report.event.uncaughtExceptionReason, or: ""))")
    }

    if let thread = report.faultingThread {
        var header = "faulting thread (\(thread.frames.count) frames"
        if let truncated = thread.truncatedFrameCount {
            header += ", \(truncated) more truncated"
        }
        header += "):"
        print(header)
        for frame in thread.frames {
            printFrameLine(frame)
        }
    }

    if let leb = report.lastExceptionBacktrace {
        print("last exception backtrace (\(leb.count) frames):")
        for frame in leb {
            printFrameLine(frame)
        }
    }

    if let images = report.images, !images.isEmpty {
        print("images:")
        for image in images {
            print("  \(sanitized(image.name))  \(image.status.rawValue)")
        }
    }

    if let symbolication = report.symbolication {
        print("symbolication (engine: \(symbolication.engine.rawValue)):")
        for status in symbolication.images {
            let detail = status.reason.map { " — \(sanitized($0))" } ?? ""
            print("  \(sanitized(status.imageName))  \(status.outcome.rawValue)\(detail)")
        }
    }
}

func printFrameLine(_ frame: AnalysisReport.FrameDump) {
    let name = frame.imageName ?? "?"
    let symbol = frame.symbol ?? frame.imageOffset.map { String(format: "0x%llx", $0) } ?? "?"
    let loc = frame.sourceFile.map { " (\(sanitized($0)):\(frame.sourceLine ?? 0))" } ?? ""
    print("  \(sanitized(name))  \(sanitized(symbol))\(loc)")
}

// MARK: - Diagnosis section

/// Wraps `text` into lines no longer than `width` columns, breaking on whitespace only
/// (never mid-word). Pure text layout — no information is added or removed.
func wordWrap(_ text: String, width: Int) -> [String] {
    var lines: [String] = []
    var current = ""
    for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
        if current.isEmpty {
            current = String(word)
        } else if current.count + 1 + word.count <= width {
            current += " " + word
        } else {
            lines.append(current)
            current = String(word)
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

/// Resolves the binary image name for a `DiagnosisEngine` inspection point by looking up
/// the frame it points at in `file` — `InspectionPoint` itself doesn't carry an image
/// name (only `symbol`/`sourceFile`/`sourceLine`, filled in by the rule from the frame it
/// found), so this cross-references `file` the same way `AnalysisReport.build` does.
func imageName(for point: InspectionPoint, in file: IPSFile) -> String? {
    let images = file.payload.usedImages
    let imageIndex: Int?
    if point.leb {
        imageIndex = point.frameIndex.flatMap { idx -> Int? in
            guard let leb = file.payload.lastExceptionBacktrace, leb.indices.contains(idx) else { return nil }
            return leb[idx].imageIndex
        }
    } else if let threadIndex = point.threadIndex, let frameIndex = point.frameIndex {
        let threads = file.payload.threads
        imageIndex = threads.indices.contains(threadIndex) && threads[threadIndex].frames.indices.contains(frameIndex)
            ? threads[threadIndex].frames[frameIndex].imageIndex
            : nil
    } else {
        imageIndex = nil
    }
    guard let idx = imageIndex, images.indices.contains(idx) else { return nil }
    return images[idx].name
}

/// Prints the evidence/inspect/confirm body of one hypothesis, indented under its
/// headline. Only prints a line when there's something honest to say — an empty
/// `supporting`/`inspect`/`confirmFurtherBy` list produces no line, never a placeholder.
///
/// NOTE: the explanation wrap width is inlined below (not a top-level `let`) because
/// `main.swift` is a script file — top-level statements execute in TEXTUAL order at
/// runtime, so a global declared below `runAnalyze`'s dispatch (near the top of this
/// file) would read as its zero value the first time this function runs, not its
/// initializer's value. Caught via CLI smoke-testing.
func printHypothesisBody(_ hypothesis: Hypothesis, factsByID: [String: Fact], file: IPSFile, indent: String) {
    for line in wordWrap(sanitized(hypothesis.explanation), width: 100) {
        print(indent + line)
    }

    let evidenceStatements = hypothesis.supporting.compactMap { factsByID[$0.factID].map { sanitized($0.statement) } }
    if !evidenceStatements.isEmpty {
        let shown = evidenceStatements.count > 4 ? Array(evidenceStatements.prefix(4)) : evidenceStatements
        var body = shown.joined(separator: "; ")
        if evidenceStatements.count > 4 {
            body += "; … (\(evidenceStatements.count) facts total)"
        }
        printLabelled("evidence:", body, indent: indent)
    }

    for point in hypothesis.inspect {
        let name = imageName(for: point, in: file) ?? "?"
        let symbol = point.symbol ?? "?"
        let loc = point.sourceFile.map { " (\(sanitized($0)):\(point.sourceLine ?? 0))" } ?? ""
        print(indent + "inspect:  \(sanitized(name)) \(sanitized(symbol))\(loc)")
    }

    if !hypothesis.confirmFurtherBy.isEmpty {
        printLabelled("confirm: ", sanitized(hypothesis.confirmFurtherBy.joined(separator: "; ")), indent: indent)
    }
}

/// Prints `label` followed by `body`, wrapped to the same width as the explanation text
/// with a hanging indent so continuation lines align under the body rather than under the
/// label. Evidence lists are the whole point of the output, so they must stay readable
/// instead of running off the terminal as one long line.
func printLabelled(_ label: String, _ body: String, indent: String) {
    let hanging = indent + String(repeating: " ", count: label.count + 1)
    let lines = wordWrap(body, width: 100 - label.count - 1)
    for (i, line) in lines.enumerated() {
        print(i == 0 ? "\(indent)\(label) \(line)" : hanging + line)
    }
}

/// Prints the human-readable diagnosis section: verdict-or-inconclusive prominent,
/// evidence citations visible, competing hypotheses always listed, nothing invented (a
/// hypothesis with no evidence, no inspect points, or no confirmFurtherBy simply omits
/// those lines). `diagnosis` is always run against `file` (the symbolicated report when
/// symbolication happened), never tier-truncated, so this is independent of `--tier`.
func printDiagnosisSection(_ diagnosis: Diagnosis, file: IPSFile) {
    let factsByID = Dictionary(uniqueKeysWithValues: diagnosis.factsConsidered.map { ($0.id, $0) })

    switch diagnosis.status {
    case .verdict:
        guard let verdict = diagnosis.verdict,
              let ranked = diagnosis.hypotheses.first(where: { $0.hypothesis.id == verdict.id }) else {
            print("DIAGNOSIS: INCONCLUSIVE — no rule matched this crash.")
            return
        }
        print("DIAGNOSIS: \(sanitized(verdict.title))   (\(ranked.band.rawValue), score \(ranked.score))")
        printHypothesisBody(verdict, factsByID: factsByID, file: file, indent: "  ")

        let rest = diagnosis.hypotheses.filter { $0.hypothesis.id != verdict.id }
        if !rest.isEmpty {
            let items = rest.map { "\(sanitized($0.hypothesis.id)) (\($0.band.rawValue), \($0.score))" }
            print("  also considered: " + items.joined(separator: ", "))
        }

    case .inconclusive:
        guard !diagnosis.hypotheses.isEmpty else {
            print("DIAGNOSIS: INCONCLUSIVE — no rule matched this crash.")
            return
        }
        print("DIAGNOSIS: INCONCLUSIVE — competing hypotheses:")
        for (i, ranked) in diagnosis.hypotheses.enumerated() {
            print("  \(i + 1). \(sanitized(ranked.hypothesis.title)) [\(sanitized(ranked.hypothesis.id))]   (\(ranked.band.rawValue), score \(ranked.score))")
            printHypothesisBody(ranked.hypothesis, factsByID: factsByID, file: file, indent: "     ")
        }

    case .notApplicable:
        print("DIAGNOSIS: NOT APPLICABLE — the diagnosis engine did not run on this input.")
    }
}

// MARK: - symbolicate

func runSymbolicate(_ args: [String]) -> Never {
    guard let opts = parseOptions(args, allowJSONAndTier: false) else {
        exit(ExitCode.usage)
    }
    if opts.wantsHelp {
        printSymbolicateHelp()
        exit(ExitCode.success)
    }
    guard let path = opts.positional else {
        FileHandle.standardError.write(Data("crashdx: symbolicate requires a path to an .ips file\n".utf8))
        printSymbolicateHelp()
        exit(ExitCode.usage)
    }

    // Reproduces the canonical two-JSON-document .ips shape (header line, newline,
    // payload) so the result can be written straight to a `.ips` file and reopened by
    // crashdx (or Xcode/Console) unchanged, rather than wrapping it in a synthetic
    // envelope — see `AnalyzePipeline.symbolicateToIPSData`.
    do {
        let data = try AnalyzePipeline.symbolicateToIPSData(
            path: path, dsymPaths: opts.dsymPaths, useSpotlight: opts.useSpotlight,
            searchArchives: opts.searchArchives
        )
        FileHandle.standardOutput.write(data)
    } catch let error as AnalyzePipeline.PipelineError {
        failForPipelineError(error)
    } catch {
        fail("symbolication failed: \(error)", code: ExitCode.dataErr)
    }
    exit(ExitCode.success)
}
