#!/usr/bin/env python3
"""
Manual smoke test for crashdx-mcp, driven over raw stdio JSON-RPC.

Not part of `swift test` — the official Swift MCP SDK (modelcontextprotocol/swift-sdk)
has no non-interactive way to register with `claude mcp add`, so this script exercises
the protocol directly instead: it spawns `crashdx-mcp`, performs the `initialize` /
`notifications/initialized` handshake, lists tools, and calls `crashdx_analyze` on the
nsexcrash fixture.

Framing: crashdx-mcp's StdioTransport (from swift-sdk 0.12.1,
Sources/MCP/Base/Transports/StdioTransport.swift) uses NEWLINE-DELIMITED JSON — one JSON
object per line, no Content-Length/LSP-style header framing. Verified by reading the SDK
source before writing this script, not assumed.

Usage (from the repo root, after `swift build`):

    python3 Tests/mcp-smoke.py [path-to-crashdx-mcp-binary]

Defaults to .build/debug/crashdx-mcp. Exits non-zero and prints a diagnostic on any
protocol or assertion failure. Prints the tools/list response and a truncated
tools/call result on success.
"""

import json
import os
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_BINARY = os.path.join(REPO_ROOT, ".build", "debug", "crashdx-mcp")
FIXTURES_DIR = os.path.join(REPO_ROOT, "Tests", "CrashDXCoreTests", "Fixtures")
NSEXCRASH_IPS = os.path.join(FIXTURES_DIR, "nsexcrash.ips")

PROTOCOL_VERSION = "2025-11-25"  # Version.latest in swift-sdk 0.12.1's Versioning.swift


class MCPClient:
    def __init__(self, binary_path):
        self.proc = subprocess.Popen(
            [binary_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,  # line-buffered
        )
        self._next_id = 1

    def send(self, obj):
        line = json.dumps(obj)
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def send_request(self, method, params=None):
        req_id = self._next_id
        self._next_id += 1
        obj = {"jsonrpc": "2.0", "id": req_id, "method": method}
        if params is not None:
            obj["params"] = params
        self.send(obj)
        return req_id

    def send_notification(self, method, params=None):
        obj = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            obj["params"] = params
        self.send(obj)

    def read_response(self, expected_id, timeout_lines=200):
        """Reads newline-delimited JSON-RPC messages until one with `id == expected_id`
        is found (skipping any notifications the server may interleave)."""
        for _ in range(timeout_lines):
            line = self.proc.stdout.readline()
            if line == "":
                stderr = self.proc.stderr.read()
                raise RuntimeError(
                    f"crashdx-mcp closed stdout before responding to id={expected_id}. "
                    f"stderr:\n{stderr}"
                )
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            if msg.get("id") == expected_id:
                return msg
        raise RuntimeError(f"no response with id={expected_id} within {timeout_lines} lines")

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def main():
    binary_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BINARY
    if not os.path.isfile(binary_path):
        print(f"FAIL: crashdx-mcp binary not found at {binary_path} (run `swift build` first)")
        return 1
    if not os.path.isfile(NSEXCRASH_IPS):
        print(f"FAIL: fixture not found at {NSEXCRASH_IPS}")
        return 1

    client = MCPClient(binary_path)
    try:
        # 1. initialize
        init_id = client.send_request(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "mcp-smoke.py", "version": "0.1.0"},
            },
        )
        init_response = client.read_response(init_id)
        if "error" in init_response:
            print(f"FAIL: initialize returned an error: {init_response['error']}")
            return 1
        print("=== initialize response ===")
        print(json.dumps(init_response, indent=2))

        # 2. notifications/initialized (no response expected)
        client.send_notification("notifications/initialized")

        # 3. tools/list
        list_id = client.send_request("tools/list")
        list_response = client.read_response(list_id)
        if "error" in list_response:
            print(f"FAIL: tools/list returned an error: {list_response['error']}")
            return 1
        tool_names = {t["name"] for t in list_response["result"]["tools"]}
        print("\n=== tools/list response ===")
        print(json.dumps(list_response, indent=2))
        assert "crashdx_analyze" in tool_names, f"crashdx_analyze missing from {tool_names}"
        assert "crashdx_symbolicate" in tool_names, f"crashdx_symbolicate missing from {tool_names}"

        # 4. tools/call crashdx_analyze on the nsexcrash fixture
        call_id = client.send_request(
            "tools/call",
            {
                "name": "crashdx_analyze",
                "arguments": {
                    "path": NSEXCRASH_IPS,
                    "tier": "standard",
                    "dsymPaths": [FIXTURES_DIR],
                    "noSpotlight": True,
                },
            },
        )
        call_response = client.read_response(call_id)
        print("\n=== tools/call (crashdx_analyze) response (truncated) ===")
        text = json.dumps(call_response, indent=2)
        print(text[:2000] + ("... [truncated]" if len(text) > 2000 else ""))

        if "error" in call_response:
            print(f"FAIL: tools/call returned a protocol-level error: {call_response['error']}")
            return 1
        result = call_response["result"]
        if result.get("isError"):
            print(f"FAIL: crashdx_analyze tool returned isError=true: {result}")
            return 1

        content_text = "".join(
            c.get("text", "") for c in result.get("content", []) if c.get("type") == "text"
        )
        assert "uncaught-objc-exception" in content_text, (
            "expected 'uncaught-objc-exception' in tool result text, got:\n" + content_text
        )

        print("\nPASS: initialize, tools/list, and tools/call(crashdx_analyze) all succeeded; "
              "'uncaught-objc-exception' verdict confirmed.")
    finally:
        client.close()

    # Runs after the handshake client is closed: it opens its own sessions.
    return 0 if check_cli_mcp_equivalence(binary_path) else 1


def check_cli_mcp_equivalence(binary_path):
    """The CLI and the MCP server must produce byte-identical reports.

    Both front ends are documented as driving one shared `AnalyzePipeline` precisely so
    they cannot drift; nothing enforced that until this check. A divergence means an agent
    and a human analysing the same crash would be shown different evidence.

    Uses --no-spotlight/--no-archives so the comparison measures crashdx, not whatever
    dSYMs happen to sit on the machine running it.
    """
    cli = os.path.join(REPO_ROOT, ".build", "debug", "crashdx")
    if not os.access(cli, os.X_OK):
        print("SKIP: crashdx CLI not built; run `swift build` to include this check")
        return True

    checked = 0
    for name in ("nullderef", "nsexcrash"):
        path = os.path.join(FIXTURES_DIR, name + ".ips")
        for tier in ("summary", "standard", "full"):
            cli_out = subprocess.run(
                [cli, "analyze", path, "--json", "--tier", tier,
                 "--no-spotlight", "--no-archives"],
                capture_output=True, text=True, check=True,
            ).stdout.strip()

            client = MCPClient(binary_path)
            try:
                init_id = client.send_request("initialize", {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": "mcp-smoke.py", "version": "0.1.0"},
                })
                client.read_response(init_id)
                client.send_notification("notifications/initialized")
                call_id = client.send_request("tools/call", {
                    "name": "crashdx_analyze",
                    "arguments": {"path": path, "tier": tier,
                                  "noSpotlight": True, "noArchives": True},
                })
                response = client.read_response(call_id)
            finally:
                client.close()

            if "error" in response:
                print(f"FAIL: MCP returned an error for {name}/{tier}: {response['error']}")
                return False
            mcp_out = "".join(
                part.get("text", "") for part in response["result"].get("content", [])
            ).strip()

            if cli_out != mcp_out:
                print(f"FAIL: CLI and MCP disagree for {name} at tier {tier} "
                      f"({len(cli_out)} vs {len(mcp_out)} bytes)")
                return False
            checked += 1

    print(f"PASS: CLI and MCP produced identical reports for {checked} fixture/tier pairs.")
    return True


if __name__ == "__main__":
    sys.exit(main())
