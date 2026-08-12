# Changelog

All notable changes to this project will be documented in this file.

## v0.1.3 (2026-08-12)

### Fixes

- `agrout-bridge update` reported "Already up to date" after a release
  if the user ran it within one hour of a prior `update` invocation.
  The local `update-cache.json` (1h TTL) shadowed the GitHub
  `releases/latest` lookup, so the newest tag was never queried.
  `Updater.fetchLatestTag()` now accepts a `forceRefresh` flag, and the
  explicit `update` command always passes `forceRefresh: true` so the
  API is consulted on every user-triggered check. The cache remains in
  place for future background polls (none are wired yet). Added a
  regression test (`test/updater_test.dart`) using a local stub HTTP
  server that seeds stale cache, asserts it is bypassed, and asserts
  the cache is refreshed on success.

## v0.1.2 (2026-08-12)

### Fixes

- Local sign-in page returned `ERR_EMPTY_RESPONSE` because the HTML
  body was never written: `_servePage` set the response headers and
  closed the socket without ever calling `response.add(_loginHtml)`.
  Same class of bug in `_serveSuccess`. Both helpers now write the
  UTF-8 body with a `Content-Length` header before closing, and add
  `Cache-Control: no-store`. Added a regression test
  (`test/login_serve_test.dart`) that drives the page over a real
  HttpClient and asserts the form fields are present.
- Header strip rendered `[Closure: ...]` instead of the current page
  number. The interpolation `'$_pageTab(_infoPage)'` was reading the
  method reference as a string; corrected to
  `'${_pageTab(_infoPage)}'`.

## v0.1.1 (2026-08-12)

### Fixes

- TUI quit left the terminal in a broken state: after `[q] Yes` the
  process exited via `dart:io exit()`, bypassing nocterm's terminal
  cleanup. Result: mouse movements continued to print garbage escapes
  on the shell after the bridge had quit (alternate-screen buffer and
  mouse-tracking flags were never restored). Replaced `exit()` with
  `shutdownApp(0)` in `tui/app.dart` and dropped the trailing
  `exit(0)` from `main.dart`, matching `commandcode-bridge`'s flow.

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

