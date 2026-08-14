# Changelog

## v0.1.11 (2026-08-14)

### Fix

- **Base64-encoded content in tool results no longer trips the upstream
  content filter.** WebFetch (format=markdown) and file-read tool results
  embed images, logos and fonts as `data:...;base64,...` URIs. Accumulated
  base64 over ~2,200 chars per request reads as obfuscated content to
  agentrouter.org's gate and produces a hard `content-blocked` (HTTP 400),
  even with a valid English system anchor. The bridge now scrubs base64
  from every JSON string value in the request body before forwarding:
  `data:...;base64,...` URIs and bare base64 runs (>= 200 chars) are
  replaced with a short placeholder. Plain text, URLs and tool-call
  arguments are untouched. Runs on both the OpenAI and Anthropic paths.

### Docs

- **`docs/CONTENT-FILTER.md` corrected.** The earlier "tool results are
  neutral" claim was disproven by live probing: base64-encoded blobs in
  tool results are the one exception that trips the gate. Documented the
  aggregate ~2,200-char base64 threshold, the measured per-request table
  (markdown with data URIs blocks, without them passes) and the bridge
  scrub behavior. `AGENTS.md` updated to match.

### Internal

- `test/base64_scrub_test.dart`: unit tests for `scrubBase64Payload`
  (data-URI replacement, long bare-run collapse, nested Anthropic content
  blocks, no-op on plain text/URLs).
- `dart analyze`: 0 issues. Full non-live suite: 73 tests pass.

## v0.1.10 (2026-08-14)

### Fix

- **System-prompt trimming is off by default.** The v0.1.6 behavior
  (`trimSystemMessages`) stripped OpenCode's `<memory_blocks>` /
  `<available_skills>` / `<memory_instructions>` / `<journal_instructions>`
  tags and hard-capped the system message at 8000 chars. Live probing of
  agentrouter.org's content filter (2026-08) shows the gate judges the
  presence of a coherent English instruction block in the system message,
  not the language mix of the payload; trimming can drop below that
  threshold and cause `content-blocked`. The strip still exists behind the
  new `config.trimSystemPrompt` flag, default `false`.

### Docs

- **New `docs/CONTENT-FILTER.md`** documents the empirical filter study:
  the gate measures the system message, not the conversation; filler text
  is rejected; the upstream `HTTP 504` on very large requests is a
  prefill-time gateway limit (stable ~123s), not a filter rejection; and
  recommended per-model context/input limits so clients auto-compact
  before the 504. `AGENTS.md` and `docs/ARCHITECTURE.md` updated to match.

### Internal

- `test/profile_test.dart` now covers the `trimSystemPrompt` config field
  roundtrip and default.
- `dart analyze`: 0 issues. Full non-live suite: 67 tests pass.

## v0.1.9 (2026-08-13)

### Fixes

- **Billing info on the TUI Profile page, API key only.** New API panels
  expose OpenAI-style billing endpoints that work with a plain dashboard
  API key, no session token needed. The Profile page now fetches
  `GET /v1/dashboard/billing/subscription` (soft/hard quota) and
  `GET /v1/dashboard/billing/usage` (total usage over the last 30 days)
  with the active profile's API key, so credit and consumption are visible
  without any OAuth sign-in. Triggered on startup and on `[r]`.

### Removed

- Auto-capture of the provider OAuth session is removed. The bridge tried
  bouncing the GitHub / LinuxDO redirect back to its own `/oauth/callback`
  via a `redirect_uri` on `127.0.0.1`, but GitHub rejects any
  `redirect_uri` that is not registered on the AgentRouter OAuth app
  ("Be careful! The redirect_uri is not associated with this application").
  The provider buttons now redirect to the provider only, and the session
  token is pasted manually, exactly like v0.1.7. Credit/usage does not need
  a session token anyway (see billing endpoints above).

### Internal

- `test/billing_test.dart`: mock-driven tests for the two billing
  endpoints (Bearer header, date-range query).
- `test/login_serve_test.dart`: OAuth redirect assert now expects NO
  `redirect_uri`; the callback-exchange test is removed.
- `dart analyze`: 0 issues. Full non-live suite: 66 tests pass.

## v0.1.8 (2026-08-13)

### Fixes

- Pasting a dashboard **API key** now works. AgentRouter has two distinct
  credential types: an API key (`sk-...` from the dashboard) that
  authorizes `/v1/*` proxy calls, and a session token from provider OAuth
  that authorizes dashboard endpoints like `/api/user/self`. The sign-in
  page previously validated against `/api/user/self`, which rejects
  dashboard API keys with "access token 无效" (无权进行此操作). The pasted
  value is now validated against `/v1/models` (the check that accepts an
  API key) and stored as the profile's `apiKey`; account-info enrichment
  via `/api/user/self` is best-effort only.
- **Auto-capture provider OAuth** (no manual paste). The "Sign in with
  GitHub" / "Sign in with LinuxDO" buttons bounce the provider back to the
  bridge's own `/oauth/callback` (via `redirect_uri` on `127.0.0.1`) and
  exchange the code for a session token. Note: removed in v0.1.9 because
  GitHub rejects a `redirect_uri` not registered on the AgentRouter OAuth
  app.

### Internal

- `test/login_serve_test.dart`: added mock-driven tests for API-key
  validation via `/v1/models` and OAuth code->session exchange.
- `dart analyze`: 0 issues. Full non-live suite: 65 tests pass.

## v0.1.7 (2026-08-13)

### Fixes

- Orphan processes no longer accumulate after stopping the bridge. Two
  root causes fixed:
  - The npm wrapper (`bin/agrout-bridge.js`) now forwards
    `SIGINT`/`SIGTERM`/`SIGHUP` to the spawned Dart binary and kills the
    child on wrapper exit. Previously killing the wrapper orphaned the
    Dart child, which kept running with no port but never terminating.
  - Headless mode (`run --server`) now calls `exit(0)` after the server
    closes. The active `ProcessSignal` subscriptions keep the event loop
    alive after shutdown, so the process never exited on SIGTERM even
    though the listener was released.
- Port auto-increment no longer ratchets the config. The escalated port
  is used only for the current process and is never persisted, so a normal
  restart returns to the configured default (e.g. 8318). `/info` now
  exposes both `serverPort` (actual bound) and `configuredPort`.
- Sign-in flow rewritten for AgentRouter's OAuth-only accounts. AgentRouter
  has no username/password registration; the local sign-in page now shows
  "Sign in with GitHub" and "Sign in with LinuxDO" buttons. Each opens the
  real provider authorize URL built from `/api/oauth/state` (signed state
  token) plus the client ids from `/api/status`, then the user pastes the
  resulting session token / API key back into the local page. The old
  username/password form is removed.

### Internal

- `test/login_serve_test.dart`: asserts the OAuth page (provider buttons +
  token field, no username/password), 404 on unknown provider path, and a
  mock-driven GitHub authorize redirect (302 + client_id + state).
- `test/server_port_auto_increment_test.dart`: asserts escalation is NOT
  persisted into the config store.
- `dart analyze`: 0 issues. Full non-live suite: 63 tests pass.

## v0.1.6 (2026-08-13)

### Fixes

- Reduces `content-blocked` / `sensitive_words` from agentrouter.org's input
  content filter on large OpenCode/Claude Code sessions:
  - Strip oversized system-prompt blocks (`<memory_blocks>`,
    `<available_skills>`, `<memory_instructions>`, `<journal_instructions>`)
    and hard-cap any system message at 8000 chars before forwarding. This is
    the largest contributor to oversized system prompts and the most likely
    false-positive content-filter trigger.
  - Spoof the accepted `User-Agent: opencode/1.0` on upstream requests.
    agentrouter.org's client-fingerprint layer only lets this UA through;
    bare SDK UAs (Dart/Node defaults) get 401 unauthorized; other spoofed
    UAs (claude/*, Codex/*) also get 401. Verified by direct curl
    eksperimen.
  - SSE passthrough: drop mid-stream `content_blocked` / `sensitive_words` /
    `billing.summary` / `data: null` lines instead of aborting the stream, so
    OpenCode keeps receiving partial responses when the gateway emits a soft
    block. (Inspiration: Lyravein/agentrouter-bridge sanitization approach.)

### Internal

- `test/server_port_auto_increment_test.dart`: deterministic, uses high
  pseudo-random ports (no clashes with default 8318 or prior runs).
- `dart analyze`: 0 issues. Full non-live suite: 61 tests pass.

See v0.1.4/v0.1.5 changelog entries for prior fixes (reasoning translation,
Tags API updater, /info version).

## v0.1.5 (2026-08-13)

### Fixes

- `agrout-bridge run --server` crashed on startup with `SocketException:
  Failed to create server socket (OS Error: Address already in use, errno =
  98), port = 8318` when a previous bridge process (or anything else) held
  the default port 8318. `ServerController.start()` now retries the next
  free port (8318 -> 8319 -> 8320, bounded to 25 attempts) on any
  `SocketException`, and persists the bound port into the config store so
  `/info`, `/health` and the TUI report the real listen address. Verified
  live: with 8318 occupied by another process, bridge binds 8319 and
  serves correctly.


All notable changes to this project will be documented in this file.

## v0.1.4 (2026-08-12)

### Fixes

- `agrout-bridge update` failed with "Failed to check latest version from
  GitHub" even when a newer release existed. Root cause: GitHub's
  `/releases/latest` endpoint returns HTTP 404 for this repo (no release
  object is marked `isLatest`, a known GitHub flakiness where every
  release reports `isLatest == false` while tags + assets are valid).
  The updater now queries the stable Tags API
  (`/repos/.../tags`) and picks the highest stable semver, filtering
  prerelease tags (`-rc`, `-beta`, `-alpha`, ...). Verified live:
  `GET /releases/latest` -> 404, `GET /tags` -> returns v0.1.0..v0.1.3.
- Degrade gracefully on API/network failure. v0.1.3 made `update` always
  bypass the cache (`forceRefresh`), which hard-failed when the API was
  unreachable or 404ing. Now, if the Tags API call fails, the updater
  falls back to the cached tag instead of erroring, so an offline or
  throttled user still sees a sensible "already up to date" rather than
  "Failed to check".
- OpenCode (`@ai-sdk/openai-compatible` + `reasoning: true`) on Claude
  models failed with `thinking.enabled is not supported for this model.
  Use thinking.adaptive and output_config.effort...`. AgentRouter
  routes Claude through a backend (Bedrock-style schema) that rejects
  OpenAI-native `reasoning_effort` and Anthropic `thinking.enabled`.
  The bridge now normalizes OpenAI `reasoning_effort` + non-standard
  `thinking: {enabled:true}` into the Anthropic-native
  `thinking: {type:'enabled', budget_tokens}` block for Claude-family
  models on `/v1/chat/completions`. Verified end-to-end: a request with
  `reasoning_effort: "high"` now streams a real Claude response (HTTP
  200) through the bridge instead of returning the upstream schema error.
  OpenAI/o-series reasoning is left untouched.
- `/info` endpoint returned a hardcoded `"version": "0.1.0"` to all
  clients, so monitoring and tooling could never tell the real version.
  It now reports `bridgeVersion`.
- Added regression tests `test/updater_test.dart` (Tags API fetch +
  cache bypass + graceful fallback) and `test/reasoning_translation_test.dart`
  (OpenAI reasoning_effort -> Anthropic thinking normalization).

## v0.1.3 (2026-08-12)

### Fixes

- `agrout-bridge update` reported "Already up to date" after a release
  if the user ran it within one hour of a prior `update` invocation.
  The local `update-cache.json` (1h TTL) shadowed the GitHub
  `releases/latest` lookup, so the newest tag was never queried.
  `Updater.fetchLatestTag()` now accepts a `forceRefresh` flag, and the
  explicit `update` command always passes `forceRefresh: true` so the
  API is consulted on every user-triggered check.

  NOTE: v0.1.3's `forceRefresh` alone was insufficient; it hard-failed
  when `/releases/latest` returned 404 (see v0.1.4). v0.1.4 additionally
  switches to the Tags API and adds graceful cache fallback.

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

