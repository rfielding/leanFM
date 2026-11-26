# Hosting LeanFM's MCP endpoint

`leanfm-mcp` serves LeanFM's MCP tools, resources, prompts and logic view, and nothing
else: no chat UI, no `/api/llm`, no sessions, no project files. It is the executable to expose
to remote clients. The full `leanfm-server` on port 8080 stays on loopback.

## Run it locally

```sh
lake build leanfm-mcp
LEANFM_MCP_PORT=8090 .lake/build/bin/leanfm-mcp
curl -s http://127.0.0.1:8090/healthz
```

## Run it inside Claude Desktop, with no server

Claude Desktop can start `leanfm-mcp` itself and talk to it over standard input and output. No
port is opened and no API key is involved: LeanFM's tools never call a model, and Claude's own
turns come out of the Claude subscription.

```sh
lake build leanfm-mcp
python3 scripts/claude_desktop_config.py --root "$PWD" --install   # on the machine running Claude Desktop
```

If Claude Desktop runs on another computer (a Mac) and LeanFM is built on this one, run the script
there with `--ssh`, so Claude Desktop starts LeanFM through ssh (which must log in without a
prompt):

```sh
ssh LINUXHOST cat code/leanFM/scripts/claude_desktop_config.py | \
  python3 - --ssh LINUXHOST --root /home/ME/code/leanFM --install
```

Quit and reopen Claude Desktop. The session tools then draw LeanFM's explorer inline: the whole
protocol, each role's view with its OpenAPI and protobuf, walk-throughs, animations and datasets.
By hand, the entry is `{"mcpServers": {"leanfm": {"command": ".../leanfm-mcp", "args": ["--stdio",
"--root", "/path/to/leanFM"]}}}` in `claude_desktop_config.json`.

To share one running server between Claude Desktop, Codex and Claude Code, start `make serve` and
let Desktop (or Codex) launch the relay, which computes nothing and forwards every message to it:

```sh
python3 scripts/claude_desktop_config.py --root "$PWD" --forward http://127.0.0.1:8080/mcp --install
```

For Codex, the same command in `~/.codex/config.toml`:

```toml
[mcp_servers.leanfm]
command = "/path/to/leanFM/.lake/build/bin/leanfm-mcp"
args = ["--stdio", "--forward", "http://127.0.0.1:8080/mcp"]
```

After a rebuild, restart only `make serve`; the clients keep running, and all of them share its
model cache. If the server is not running, each request is answered with an error saying so.

## Run it on a public host (EC2 or any VM)

Claude (claude.ai, the desktop and mobile apps) reaches a connector added by URL from Anthropic's
servers, so the host must be public and speak HTTPS; Streamable HTTP is the transport Claude uses,
and `leanfm-mcp` already serves it at `/mcp` (no WebSocket is needed). On a small instance:

```sh
lake build leanfm-mcp
LEANFM_MCP_BIND=127.0.0.1 LEANFM_MCP_PORT=8090 .lake/build/bin/leanfm-mcp &
caddy reverse-proxy --from leanfm.example.com --to 127.0.0.1:8090    # TLS from Let's Encrypt
```

Or, with nothing but the Go toolchain (`make go-toolchain`), the one-page proxy in
`deploy/mcp/proxy` in place of Caddy:

```sh
(cd deploy/mcp/proxy && ../../../.toolchains/go/bin/go build -o leanfm-proxy .)
LEANFM_MCP_TRUST_PROXY=1 LEANFM_MCP_PORT=8090 .lake/build/bin/leanfm-mcp &
LEANFM_PROXY_CERT=cert.pem LEANFM_PROXY_KEY=key.pem LEANFM_PROXY_LISTEN=:443 deploy/mcp/proxy/leanfm-proxy
```

It forwards only `/mcp` and `/healthz`, replaces the client's `X-Forwarded-For` with the real peer
(so `LEANFM_MCP_TRUST_PROXY=1` is safe behind it), caps bodies at 256 KiB and requests in flight at
32, and closes slow or idle connections (`LEANFM_PROXY_*` variables, checked at startup; without a
certificate it serves plain HTTP, for use behind a load balancer).

Then add `https://leanfm.example.com/mcp` as a custom connector. Without `LEANFM_MCP_TOKEN` it needs
no authentication. Every tool is read-only and deterministic, and holds no user data. Each client
is still held to the rate and in-flight limits below, so an open endpoint can be slowed but not made
to do unbounded work. A static host such as GitHub Pages cannot serve it, because every answer is
computed by the Lean checker.

Connections are kept alive (HTTP/1.1), so a client asking question after question pays for one
connection; behind Caddy, Caddy keeps the client's connection and its own to `leanfm-mcp`. A kept
connection closes after its request quota, after it sits idle, or after any request that is not one
complete frame, and open connections are capped; framing stays strict (one `Content-Length`, no
`Transfer-Encoding`), so a proxy and `leanfm-mcp` cannot disagree about where a request ends. Keep
`leanfm-mcp` on loopback behind the proxy: the connection cap protects the process, but on an open
port one client could fill it. `session_ctl` answers carry a `model` token; sending it back with the
same protocol text skips rebuilding the state graph. The tokens are random, the cache is memory only
and least-recently-used, and every request still carries its text, so a token grants nothing.

## Run it in a container

```sh
docker build -f deploy/mcp/Dockerfile -t leanfm-mcp .
docker run --rm -p 8090:8090 leanfm-mcp
```

The container listens on plain HTTP. Terminate TLS in front of it: a cloud load balancer,
Caddy (`caddy reverse-proxy --from leanfm.example.com --to 127.0.0.1:8090`) or nginx. The
endpoint clients add as a connector is `https://<your host>/mcp`.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `LEANFM_MCP_BIND` | `127.0.0.1` (`0.0.0.0` in the container) | IPv4 address to listen on |
| `LEANFM_MCP_PORT` | `8090` | port |
| `LEANFM_MCP_ORIGINS` | `https://claude.ai,https://claude.com` | browser origins allowed; `*` is refused |
| `LEANFM_MCP_TOKEN` | unset | when set, every request needs `Authorization: Bearer <token>` |
| `LEANFM_MCP_RATE` | `60` | requests per minute per client |
| `LEANFM_MCP_BURST` | `20` | requests a client may make at once |
| `LEANFM_MCP_MAX_INFLIGHT` | `4` | tool calls running at the same time |
| `LEANFM_MCP_TRUST_PROXY` | off | `1` to take the client from the first `X-Forwarded-For` address; set it only behind a proxy you control |
| `LEANFM_KEEPALIVE_REQUESTS` | `100` | requests one connection serves before it closes |
| `LEANFM_KEEPALIVE_SECONDS` | `30` | seconds a kept connection may wait for its next request |
| `LEANFM_MAX_CONNECTIONS` | `64` | connections open at once; one more is answered 503 |
| `LEANFM_MODEL_CACHE` | `16` | state graphs `session_ctl` keeps for model tokens, least recently used dropped first |

## What the server enforces

- CORS for the listed origins only: preflight on `OPTIONS /mcp`, the MCP headers allowed,
  `Mcp-Session-Id` exposed, never `*`, never credentials. A request from another origin is 403;
  a request with no `Origin` (a server-side client such as Claude's connector service) is served.
- Streamable HTTP: `POST /mcp` answers `application/json`; notifications get `202`; `GET /mcp`
  is `405` because the server sends no event stream.
- `415` for a non-JSON body, `406` for an `Accept` without JSON, `400` for an unsupported
  `Mcp-Protocol-Version`, `413` over 256 KiB, `429` with `Retry-After` over the rate, `503` with
  `Retry-After` over the in-flight limit.
- Tool results over 100,000 characters (the directory's 25,000-token limit) are compacted, with a
  note saying what was left out, or replaced by an error.
- One log line per request: method, path, JSON-RPC method, tool, status, milliseconds. Never a
  body, an argument, a token or a client address.

## Listing in the Claude Connectors Directory

The directory asks for HTTPS, accurate tool annotations (every LeanFM tool is read-only), at least
three working examples, documentation, a privacy policy at a stable URL, a support contact and a
non-beta service; see https://support.claude.com/en/articles/12922490. OAuth is required if the
server uses authentication at all. `LEANFM_MCP_TOKEN` is a bearer token for private deployments,
not OAuth; OAuth is not implemented yet, so a public listing would run without authentication,
protected by the rate and concurrency limits.
