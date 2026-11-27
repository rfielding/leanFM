import Lean.Data.Json

/-! Every environment variable LeanFM reads, in one list (clause selfhost.env.registry).

A variable read anywhere in the source must be here, and everything here must be read somewhere:
`scripts/env_registry_check.py` checks both ways in `make check`. A secret's value is never written
anywhere; at startup each server records its variables in its `MainEntered` event, a secret only as
set or not. -/

namespace LeanFM.Env
open Lean

structure Variable where
  name : String
  /-- the executables that read it -/
  readers : List String
  /-- what it accepts -/
  accepts : String
  /-- what holds when it is not set -/
  default : String
  /-- it holds a credential: its value is never written -/
  secret : Bool := false

def server := "leanfm-server"
def mcp := "leanfm-mcp"

def registry : List Variable :=
  [ -- both servers
    { name := "LEANFM_LAUNCHED_NS", readers := [server, mcp], accepts := "the launch time, nanoseconds since the Unix epoch (date +%s%N)", default := "no measurement" }
  , { name := "LEANFM_LIMIT_CEILING", readers := [server, mcp], accepts := "a whole factor of at least 1 by which one call may raise its limits", default := "the built-in ceiling" }
  , { name := "LEANFM_MODEL_CACHE", readers := [server, mcp], accepts := "how many checker models to keep, a whole number", default := "16" }
  , { name := "LEANFM_KEEPALIVE_REQUESTS", readers := [server, mcp], accepts := "requests per connection, a whole number of at least 1", default := "100" }
  , { name := "LEANFM_KEEPALIVE_SECONDS", readers := [server, mcp], accepts := "idle seconds before a connection closes, a whole number", default := "30" }
  , { name := "LEANFM_MAX_CONNECTIONS", readers := [server, mcp], accepts := "open connections at once, a whole number of at least 1", default := "64" }
  , { name := "HOME", readers := [server, mcp], accepts := "the user's home directory, where Claude Desktop's logs are found", default := "Claude Desktop's logs are not read" }
    -- leanfm-server
  , { name := "LEANFM_PORT", readers := [server], accepts := "a TCP port, 1 to 65535", default := "8080" }
  , { name := "LEANFM_CHATUI", readers := [server], accepts := "0, 1, true or false", default := "off: MCP and the views only" }
  , { name := "LEANFM_PASSWORD", readers := [server], accepts := "the chat UI's login password", default := "leanfm", secret := true }
  , { name := "OPENAI_API_KEY", readers := [server], accepts := "an OpenAI API key for the chat UI", default := "no OpenAI provider", secret := true }
  , { name := "LEANFM_WORKSPACE_ROOT", readers := [server], accepts := "the chat UI's workspace directory", default := "the checkout's own" }
  , { name := "LEANFM_DATA_ROOT", readers := [server], accepts := "the chat UI's data directory", default := "the checkout's own" }
  , { name := "LEANFM_SESSION_TOKEN_BUDGET", readers := [server], accepts := "tokens a chat session may spend, a whole number", default := "the built-in budget" }
  , { name := "LEANFM_OPENAI_BASE_URL", readers := [server], accepts := "the OpenAI-compatible API's base URL", default := "OpenAI's" }
  , { name := "LEANFM_ANTHROPIC_BASE_URL", readers := [server], accepts := "the Anthropic API's base URL", default := "Anthropic's" }
  , { name := "LEANFM_PROVIDER_TIMEOUT_SECONDS", readers := [server], accepts := "seconds to wait for a model provider, a whole number", default := "the built-in timeout" }
  , { name := "LEANFM_LLM_MODEL", readers := [server], accepts := "the chat UI's default OpenAI model", default := "the built-in model" }
  , { name := "LEANFM_LLM_MODELS", readers := [server], accepts := "the OpenAI models the chat UI offers, comma separated", default := "the built-in list" }
  , { name := "LEANFM_ANTHROPIC_MODEL", readers := [server], accepts := "the chat UI's default Anthropic model", default := "the built-in model" }
  , { name := "LEANFM_ANTHROPIC_MODELS", readers := [server], accepts := "the Anthropic models the chat UI offers, comma separated", default := "the built-in list" }
  , { name := "LEANFM_BOOK_REPAIR_TIMEOUT_SECONDS", readers := [server], accepts := "seconds a book repair may run, a whole number", default := "the built-in timeout" }
  , { name := "LEANFM_CONTEXT_WINDOW_TOKENS", readers := [server], accepts := "the model's context window in tokens, a whole number", default := "the built-in size" }
  , { name := "LEANFM_PUBLIC_ORIGIN", readers := [server], accepts := "the chat UI's public origin (scheme, host, port)", default := "the request's own" }
    -- leanfm-mcp
  , { name := "LEANFM_MCP_BIND", readers := [mcp], accepts := "an IPv4 address to listen on", default := "127.0.0.1" }
  , { name := "LEANFM_MCP_PORT", readers := [mcp], accepts := "a TCP port, 1 to 65535", default := "8090" }
  , { name := "LEANFM_MCP_ORIGINS", readers := [mcp], accepts := "the browser origins allowed, comma separated", default := "https://claude.ai and https://claude.com" }
  , { name := "LEANFM_MCP_TOKEN", readers := [mcp], accepts := "the bearer token clients must send", default := "no token required", secret := true }
  , { name := "LEANFM_MCP_RATE", readers := [mcp], accepts := "requests per minute per client, a whole number", default := "60" }
  , { name := "LEANFM_MCP_BURST", readers := [mcp], accepts := "requests a client may make at once over its rate, a whole number", default := "20" }
  , { name := "LEANFM_MCP_MAX_INFLIGHT", readers := [mcp], accepts := "tool calls running at once, a whole number", default := "4" }
  , { name := "LEANFM_MCP_TRUST_PROXY", readers := [mcp], accepts := "0, 1, true or false: trust X-Forwarded-For from the proxy in front", default := "off" }
  , { name := "LEANFM_MCP_LOGS", readers := [mcp], accepts := "0, 1, true or false: serve server_logs on a hosted endpoint", default := "off" }
  , { name := "LEANFM_FORWARD_WAIT_SECONDS", readers := [mcp], accepts := "seconds a relayed request waits for the server to listen, 0 to 600", default := "30" } ]

/-- The settings of the variables `exe` reads, for its MainEntered event: name, whether it is set, and
its value cut to 120 characters only when it is set and not secret. -/
def settings (exe : String) : IO Json := do
  let mut out := #[]
  for v in registry.filter (·.readers.contains exe) do
    let raw ← IO.getEnv v.name
    let entry := match raw with
      | none => [("name", Json.str v.name), ("set", Json.bool false)]
      | some x =>
        [("name", Json.str v.name), ("set", Json.bool true)] ++
          (if v.secret then [("secret", Json.bool true)] else [("value", Json.str (x.take 120).toString)])
    out := out.push (Json.mkObj entry)
  return Json.arr out

end LeanFM.Env
