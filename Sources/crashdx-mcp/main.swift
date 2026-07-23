import CrashDXCore
import Foundation
import MCP

// crashdx-mcp: an MCP server (stdio transport) exposing crashdx's analyze/symbolicate
// pipeline to agents. Both tools call `CrashDXCore.AnalyzePipeline` — the exact same code
// path the `crashdx` CLI's `analyze`/`symbolicate` subcommands use (see main.swift there)
// — so behavior never drifts between the two front ends.
//
//   swift run crashdx-mcp
//
// speaks newline-delimited JSON-RPC 2.0 over stdin/stdout per the MCP stdio transport
// spec; see Tests/mcp-smoke.py for a manual verification script (not part of `swift test`).

let mcpServerVersion = "0.1.0"

// MARK: - Tool schemas

private let tierDescription: String =
    "Report detail level. \"summary\" (default) is token-lean and omits other "
    + "threads/images/facts; \"standard\" adds app threads, referenced images, and "
    + "diagnosis facts; \"full\" includes every thread unconditionally."

private let noArchivesDescription: String =
    "Skip ~/Library/Developer/Xcode/Archives. Combine with noSpotlight to search only "
    + "the paths given in dsymPaths, so no unrelated project's filesystem path can "
    + "appear in the output. Defaults to false."

private let dsymPathsDescription: String =
    "Extra dSYM locations to search, in addition to Spotlight and Xcode's default "
    + "archive location. Each entry may be a .dSYM bundle, an .xcarchive, or a "
    + "directory to search recursively."

private let analyzeInputSchema: Value = [
    "type": "object",
    "properties": [
        "path": [
            "type": "string",
            "description": "Absolute path to the .ips crash report file to analyze.",
        ],
        "tier": [
            "type": "string",
            "enum": ["summary", "standard", "full"],
            "description": .string(tierDescription),
        ],
        "dsymPaths": [
            "type": "array",
            "items": ["type": "string"],
            "description": .string(dsymPathsDescription),
        ],
        "noSpotlight": [
            "type": "boolean",
            "description": "Skip the Spotlight (mdfind) dSYM search. Defaults to false.",
        ],
        "noArchives": [
            "type": "boolean",
            "description": .string(noArchivesDescription),
        ],
    ],
    "required": ["path"],
]

private let symbolicateInputSchema: Value = [
    "type": "object",
    "properties": [
        "path": [
            "type": "string",
            "description": "Absolute path to the .ips crash report file to symbolicate.",
        ],
        "dsymPaths": [
            "type": "array",
            "items": ["type": "string"],
            "description": .string(dsymPathsDescription),
        ],
        "noSpotlight": [
            "type": "boolean",
            "description": "Skip the Spotlight (mdfind) dSYM search. Defaults to false.",
        ],
        "noArchives": [
            "type": "boolean",
            "description": .string(noArchivesDescription),
        ],
    ],
    "required": ["path"],
]

private let analyzeDescription: String =
    "Symbolicates an .ips crash report against local dSYMs and produces an "
    + "evidence-cited diagnosis with ranked, competing hypotheses — not just a raw "
    + "stack trace. Supports three detail tiers (summary/standard/full); summary is "
    + "the default and is token-lean, usually all that's needed to triage a crash."

private let symbolicateDescription: String =
    "Symbolicates an .ips crash report against local dSYMs and returns the full "
    + "enriched .ips JSON verbatim, with no diagnosis or tier truncation. Use this "
    + "instead of crashdx_analyze when the raw symbolicated report itself is needed."

private let tools: [Tool] = [
    Tool(
        name: "crashdx_analyze",
        description: analyzeDescription,
        inputSchema: analyzeInputSchema
    ),
    Tool(
        name: "crashdx_symbolicate",
        description: symbolicateDescription,
        inputSchema: symbolicateInputSchema
    ),
]

// MARK: - Argument parsing

private func stringArgument(_ arguments: [String: Value]?, _ key: String) -> String? {
    arguments?[key]?.stringValue
}

private func stringArrayArgument(_ arguments: [String: Value]?, _ key: String) -> [String] {
    (arguments?[key]?.arrayValue ?? []).compactMap(\.stringValue)
}

private func boolArgument(_ arguments: [String: Value]?, _ key: String, default defaultValue: Bool) -> Bool {
    arguments?[key]?.boolValue ?? defaultValue
}

/// Wraps `message` as an `isError: true` tool result — an honest MCP tool error (missing
/// file, parse failure, bad argument), never a thrown protocol-level failure.
private func toolError(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
}

private func toolText(_ text: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
}

// MARK: - Tool implementations

private func runAnalyze(_ arguments: [String: Value]?) async -> CallTool.Result {
    guard let path = stringArgument(arguments, "path") else {
        return toolError("missing required argument: path")
    }
    let tierRaw = stringArgument(arguments, "tier") ?? "summary"
    guard let tier = AnalysisReport.Tier(rawValue: tierRaw) else {
        return toolError("invalid tier '\(tierRaw)' (expected summary|standard|full)")
    }
    let dsymPaths = stringArrayArgument(arguments, "dsymPaths").map { URL(fileURLWithPath: $0) }
    let useSpotlight = !boolArgument(arguments, "noSpotlight", default: false)
    let searchArchives = !boolArgument(arguments, "noArchives", default: false)

    do {
        let result = try AnalyzePipeline.analyze(
            path: path, tier: tier, dsymPaths: dsymPaths, useSpotlight: useSpotlight, searchArchives: searchArchives
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result.report)
        guard let json = String(data: data, encoding: .utf8) else {
            return toolError("failed to encode report as UTF-8 JSON")
        }
        return toolText(json)
    } catch let error as AnalyzePipeline.PipelineError {
        return toolError(error.description)
    } catch {
        return toolError("\(error)")
    }
}

private func runSymbolicate(_ arguments: [String: Value]?) async -> CallTool.Result {
    guard let path = stringArgument(arguments, "path") else {
        return toolError("missing required argument: path")
    }
    let dsymPaths = stringArrayArgument(arguments, "dsymPaths").map { URL(fileURLWithPath: $0) }
    let useSpotlight = !boolArgument(arguments, "noSpotlight", default: false)
    let searchArchives = !boolArgument(arguments, "noArchives", default: false)

    do {
        let data = try AnalyzePipeline.symbolicateToIPSData(
            path: path, dsymPaths: dsymPaths, useSpotlight: useSpotlight, searchArchives: searchArchives
        )
        guard let text = String(data: data, encoding: .utf8) else {
            return toolError("failed to encode symbolicated .ips as UTF-8")
        }
        return toolText(text)
    } catch let error as AnalyzePipeline.PipelineError {
        return toolError(error.description)
    } catch {
        return toolError("symbolication failed: \(error)")
    }
}

// MARK: - Server

let server = Server(
    name: "crashdx",
    version: mcpServerVersion,
    capabilities: .init(tools: .init(listChanged: false))
)

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: tools)
}

await server.withMethodHandler(CallTool.self) { params in
    switch params.name {
    case "crashdx_analyze":
        return await runAnalyze(params.arguments)
    case "crashdx_symbolicate":
        return await runSymbolicate(params.arguments)
    default:
        return toolError("unknown tool: \(params.name)")
    }
}

let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
