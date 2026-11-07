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
