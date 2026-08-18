# agrout-bridge

AgentRouter bridge for OpenCode, Claude Desktop, Cursor, and any
OpenAI-/Anthropic-compatible client.

<img width="1897" height="925" alt="image" src="https://github.com/user-attachments/assets/aefd6b03-ae1f-47eb-925c-85839e27eb87" />

Local HTTP proxy that forwards client requests to `https://agentrouter.org`
while adding the Claude Code client fingerprint the upstream gate expects.
Manages the WAF session cookie (`acw_tc`) per profile and survives restarts.
TUI dashboard (nocterm) shows live model health, request usage, profile
state, and proxy diagnostics. Headless mode runs the same proxy without a
TUI for daemon / Docker usage.

## Features

- OpenAI + Anthropic compatible local proxy (`/v1/messages`, `/v1/chat/completions`)
- WAF spoof: Claude Code client headers + `acw_tc` cookie warmup + per-profile persistence
- SSE streaming pass-through with format-aware terminator (`message_stop` / `data: [DONE]`)
- Single-key profile: API key stored via `profile add` (CLI) or `login` (web page), one active
- TUI dashboard: profile, usage/cost, models, proxy config, log side panel
- Headless `--server` mode for daemon / Docker
- Self-update via `latest.json` (CDN-served) + GitHub Release `.tgz`
- Optional inbound `PROXY_AUTH_TOKEN` for remote bind
- 429/QPS-aware retry with exponential backoff
- Content-blocked mitigation: strips base64 data URIs / `kix.` element IDs
  from text before forwarding so large OpenCode/Claude Code sessions pass the
  upstream filter (preserves real uploaded images)

## Install

Download the latest `.tgz` from
[GitHub Releases](https://github.com/Khip01/agrout-bridge/releases/latest),
then:

```bash
npm install -g ./agrout-bridge-vX.Y.Z.tgz
agrout-bridge run
```

Update when a new release is available (latest version is discovered from a
CDN-served `latest.json`, checked in the background):

```bash
agrout-bridge update
```

## Quick start

Two ways to add your API key; pick whichever fits your setup:

```bash
# CLI: paste your key directly (no browser)
agrout-bridge profile add my-key sk-...     # <key-name> <api-key>

# Web: open the local sign-in page and paste your key there
agrout-bridge login
```

Then run the bridge:

```bash
agrout-bridge run                          # TUI mode
agrout-bridge run --server                 # headless
```

In the TUI:

- Press `[l]` to open the login URL (paste an API key)
- On the Profile page, `up`/`down` select a profile, `Enter` switches it,
  `Shift+D` deletes it
- Press `[p]` to configure the proxy port
- Press `[1] [2] [3] [4]` to switch pages
- Press `[Ctrl+L]` to toggle the log side panel

## Client configuration (OpenCode)

Point any OpenAI-/Anthropic-compatible client at `http://127.0.0.1:8318/v1`
and use a placeholder `apiKey`. The bridge injects the active profile's
real key. The `context` / `input` limits shown below are
**research-recommended** (a ~5-10% margin below the measured
agentrouter.org ceiling, so the client auto-compacts before the gateway
returns `504`). Other clients (Claude Code, Cursor, Continue, ...) and the
full per-model probe data are in
[`docs/INSTALL.md`](docs/INSTALL.md) and
[`docs/CONTENT-FILTER.md`](docs/CONTENT-FILTER.md).

```jsonc
// opencode.jsonc: the "provider" entry
"AgentRouter": {
  "npm": "@ai-sdk/openai-compatible",
  "name": "AgentRouter",
  "options": {
    "baseURL": "http://127.0.0.1:8318/v1",
    "apiKey": "anything"
  },
  "models": {
    "gpt-5.6-sol": {
      "name": "gpt-5.6-sol",
      "limit": { "context": 420000, "input": 420000, "output": 8192 }
    },
    "claude-opus-5": {
      "name": "claude-opus-5",
      "limit": { "context": 900000, "input": 900000, "output": 8192 }
    }
  }
}
```

For the Anthropic-compatible path use `"npm": "@ai-sdk/anthropic"` with
the same `baseURL` and limits (see `docs/INSTALL.md`).

## Documentation

- [Install](docs/INSTALL.md): install options, platform support
- [API reference](docs/API-REFERENCE.md): proxy endpoints, client configs
- [TUI](docs/TUI.md): pages, key bindings
- [Architecture](docs/ARCHITECTURE.md): file structure, proxy flow

## License

MIT. See [LICENSE](LICENSE).
