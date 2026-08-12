# Changelog

All notable changes to this project will be documented in this file.

## v0.1.0 (2026-08-12)

Initial release.

### Features

- Dart 3.10+ scaffold mirroring `commandcode-bridge`'s layout: bin entry,
  npm Node launcher, nocterm TUI, `dart:io` HttpServer.
- Multi-profile store at `~/.config/agrout-bridge/` (port, active profile,
  API key + optional session token per profile, WAF cookie jar, account
  info). Profile + AppConfig stores write JSON with `0600` file mode,
  atomic via `temp + chmod + rename`.
- Spoof header constants (`claude-cli/2.1.92` Stainless fingerprint +
  Anthropic Beta list) verified live against `agentrouter.org` on
  2026-08-12.
- WAF cookie jar: parse, merge by name, serialize to `Cookie:` header.
  Pure functions, full unit test coverage.
- `AgentRouterClient`: warmup probe, JSON / streaming `send`, login relay
  with warmup-then-POST (`/api/user/login`), and `/api/user/self`,
  `/api/user/subscription`, `/api/user/dashboard`.
- HTTP proxy (`POST /v1/messages`, `POST /v1/chat/completions`,
  `GET /v1/models`) with format-aware SSE pump, circuit breaker, per-model
  health, and WAF cookie persistence into the active profile.
- Local sign-in flow: TUI `[l]` opens a localhost HTML form, relays the
  credentials to `/api/user/login`, captures the session token into the
  profile, and pulls `/api/user/self` for the Profile page.
- TUI dashboard with 4 pages (Profile, Usage & Cost, Models, Proxy Config)
  and toggleable log side panel (`Ctrl+L`, `f`, `Shift+C`, `Shift+O`).
- `UsageStore` aggregates per-request tokens + Anthropic `cost_cny.total`
  for the Usage & Cost page.
- CLI: `run`, `run --server`, `profile add|list|use|remove|login|logout|whoami`,
  `update`, `help`, `--version`.
- Self-update: `releases/latest` (1h cache) → `.tgz` → clean global install
  → `npm install -g`.
- Distribution: `.tgz` + GitHub Release workflow + post-release install
  simulation.

### Test coverage

41 unit tests across `profile`, `waf`, `sse`, `circuit`, `usage_store`.
Live smoke (`test/live_smoke_test.dart`) verifies warmup + `/v1/models` +
`/v1/chat/completions` + `/v1/messages` (stream + non-stream) end-to-end
against the user's API key (run by hand, gated on `dev/api_key.txt`).

