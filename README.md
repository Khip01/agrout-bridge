# agrout-bridge

AgentRouter bridge for OpenCode, Claude Desktop, Cursor, and any
OpenAI-/Anthropic-compatible client.

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
- Multi-profile: API key + optional session token from local sign-in flow
- TUI dashboard: profile, usage/cost, models, proxy config, log side panel
- Headless `--server` mode for daemon / Docker
- Self-update via GitHub Release `.tgz`
- Optional inbound `PROXY_AUTH_TOKEN` for remote bind
- 429/QPS-aware retry with exponential backoff

## Install

Download the latest `.tgz` from
[GitHub Releases](https://github.com/Khip01/agrout-bridge/releases/latest),
then:

```bash
npm install -g ./agrout-bridge-vX.Y.Z.tgz
agrout-bridge run
```

Update when a new release is available:

```bash
agrout-bridge update
```

## Quick start

```bash
agrout-bridge profile add my-key           # prompts for API key
agrout-bridge run                          # TUI mode
agrout-bridge run --server                 # headless
```

In the TUI:

- Press `[l]` to sign in (open the local sign-in link in your browser)
- Press `[p]` to configure the proxy port
- Press `[1] [2] [3] [4]` to switch pages
- Press `[Ctrl+L]` to toggle the log side panel

## Documentation

- [Install](docs/INSTALL.md) — install options, platform support
- [API reference](docs/API-REFERENCE.md) — proxy endpoints, client configs
- [TUI](docs/TUI.md) — pages, key bindings
- [Architecture](docs/ARCHITECTURE.md) — file structure, proxy flow

## License

MIT. See [LICENSE](LICENSE).
