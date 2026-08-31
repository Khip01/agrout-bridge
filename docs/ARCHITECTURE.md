# Architecture

## Stack

- Language: Dart 3.10+
- TUI: `nocterm` v0.8.0
- Server: `dart:io` `HttpServer`
- HTTP client: `dart:io` `HttpClient`
- Compile: `dart compile exe` -> single native binary
- Distribution: npm tarball with Node.js launcher wrapper

## File structure

```
agrout-bridge/
├── bin/
│   ├── agrout_bridge.dart          # Dart entry point
│   └── agrout-bridge.js            # npm wrapper: OS detection + binary spawn
├── lib/
│   ├── agrout_bridge.dart          # Barrel
│   └── src/
│       ├── main.dart               # CLI wiring (run / run --server / profile / update)
│       ├── models/
│       │   ├── profile.dart        # Profile + AppConfig + ProfileStore + ConfigStore
│       │   └── version.dart        # bridgeVersion constant
│       ├── services/
│       │   ├── spoof.dart          # Claude Code spoof header constants
│       │   ├── waf.dart            # WAF cookie jar (parse, merge, serialize, classify)
│       │   ├── api_client.dart     # AgentRouter HTTP client (models, chat, messages, billing)
│       │   ├── login.dart          # Local sign-in server (paste API key, validate /v1/models)
│       │   ├── stats_store.dart    # Persistent per-day usage stats (stats.jsonl, 30-day retention)
│       │   ├── log_store.dart      # JSONL activity log (2000 entries)
│       │   ├── translator.dart     # Auto-translate user messages + scrub sensitive Chinese + filler expand; LRU cache + parallel dispatch
│       │   └── updater.dart        # Self-update: latest.json CDN + Tags API fallback, download .tgz + npm install -g
│       ├── server/
│       │   ├── server_controller.dart # HTTP server + routing; owns singleton Translator instance
│       │   ├── proxy.dart          # Forward + WAF capture + usage extraction + debug body dumps (AGRROUT_DEBUG)
│       │   ├── circuit.dart        # Circuit breaker (transport-only: 502/503/504/socket) + per-model health
│       │   └── sse.dart            # SSE pump (format-aware terminator + OpenAI scrub)
│       └── tui/
│           ├── app.dart            # Nocterm TUI: 4 pages + log side panel
│           └── clipboard.dart      # wl-copy / xclip / pbcopy / clip / OSC 52
├── scripts/
│   └── stage-npm-package.mjs       # CI packaging helper: assembles release tarball
├── .github/
│   └── workflows/
│       ├── test.yml                # Dart analyze + test + smoke build
│       ├── release.yml             # Matrix build + tarball + GitHub release
│       └── post-release.yml        # Install simulation from real asset
├── docs/
│   ├── INSTALL.md
│   ├── API-REFERENCE.md
│   ├── TUI.md
│   └── ARCHITECTURE.md
├── test/
│   ├── profile_test.dart
│   ├── waf_test.dart
│   ├── sse_test.dart
│   ├── circuit_test.dart
│   └── stats_store_test.dart
├── AGENTS.md
├── CHANGELOG.md
├── README.md
├── package.json
├── pubspec.yaml
├── build / run                     # Linux/macOS scripts
├── build.bat / run.bat             # Windows batch scripts
└── LICENSE
```

## Proxy flow

```
Client ──> POST /v1/messages         ──>  proxy.dart
        (x-api-key / Authorization)        │
                                           ├─ inject spoof headers + WAF cookies
                                           ├─ B: scrubSensitiveZh (Chinese phrase regex, all roles)
                                           ├─ B: expandFillerSystemPromptsInBody (narrow filler expand)
                                           ├─ A: translateUserMessagesInBody (user-role, non-allow-list -> EN)
                                           ├─ debug dump: _in_ file (if AGRROUT_DEBUG=1)
                                           ├─ forward to https://agentrouter.org/v1/messages
                                           │
Upstream ──> 200 text/event-stream    <──  │
        (or application/json)
                                           ├─ capture fresh Set-Cookie into profile
                                           ├─ debug dump: _upstream_ file (non-streaming only)
                                           ├─ circuit.recordSuccess / Failure (transport only: 502/503/504/socket)
                                           ├─ modelHealth.recordFailure (4xx + 5xx, for /v1/models filtering)
                                           ├─ pumpSse for SSE; buffered copy otherwise
                                           └─ record usage + cost into StatsStore (per-day)
Client  <──  200 (or 4xx / 5xx)       <──
```

The proxy never translates between protocols. AgentRouter speaks both
Anthropic Messages and OpenAI Chat Completions natively, so each route
is a straight pass-through with the spoof + WAF layer in front.

### Translator (protection A + B)

Before the request is forwarded, `proxy.dart` applies two content
protection layers via `lib/src/services/translator.dart`:

- **B: Sensitive phrase scrub** (`scrubSensitiveZh`). Regex over the
  full serialized body. Replaces politically sensitive Chinese phrases
  (from `_sensitiveZhRegex`) with `[redacted]`. Covers all roles.
  Runs first so that subsequent translation cannot re-introduce a
  phrase in a different encoding.
- **B: Filler expand** (`expandFillerSystemPromptsInBody`). Detects
  the exact string `"You are a helpful assistant."` in the system
  message and replaces it with a longer instruction block. Prevents
  the `sensitive_words_detected` 500 that this narrow filler triggers.
- **A: User-message translate** (`translateUserMessagesInBody`). Walks
  only `user`-role messages. Detects source language via the keyless
  Google translate endpoint. Rewrites anything outside the allow-list
  (CN/EN/FR/DE/RU) to English. Injects `[System note: Respond in
  <lang>]` into the last user message so the model replies in the
  user's original language. Short texts (24 non-WS chars) always go
  through the translator (detector unreliable at that length). A
  two-pass fetch retries with `sl=id` when the first pass returns the
  text unchanged. Runs after B.

The `Translator` instance is a singleton owned by `server_controller`.
It holds an in-memory LRU cache (2048 entries, sha1-keyed) so repeated
user turns in the same session are cache hits. Parallel `Future.wait`
dispatch keeps first-request latency to one Google round-trip. Cache
is not persisted to disk; it resets on bridge restart.

Translation is gated on `AppConfig.translateUserMessages` (default
`true`). Toggle from TUI Proxy Config page (`[4]` then `[t]`).

See `docs/LANGUAGE-GATE.md` for the full empirical evidence and design.

### Debug body dumps

Set `AGRROUT_DEBUG=1` (or `AGRROUT_DEBUG_DIR=<path>`) to write three
JSON files per proxied request to `$AGRROUT_DEBUG_DIR` (default
`/tmp/opencode/agrout-debug`):

| File suffix | Contents |
|---|---|
| `_in_<model>.json` | Inbound request body after all scrubs + translation |
| `_out_<model>.json` | Outbound headers + response metadata |
| `_upstream_<model>.json` | Raw upstream response body (non-streaming only) |

Each file starts with a JSON metadata header (`model`, `path`,
`status`, `ts`, etc.) followed by a `---` separator and the body
content. Bodies are `jsonEncode`'d so control characters survive as
`\n` escapes and the file is parseable by any JSON reader. Body is
clamped to `$AGRROUT_DEBUG_MAX_BODY` bytes (default 256 KiB); set
the env var to a larger number to capture full 2MB+ bodies when
hunting a `sensitive_words` trigger.

Streaming responses skip the upstream body capture (the stream is not
buffered a second time); the `_upstream_` file is empty for SSE
requests.

Off by default. Do not leave on in production; the files accumulate
quickly.

### Circuit breaker (transport-only)

`lib/src/server/circuit.dart` implements a per-model circuit breaker.
Key design decision from v0.1.25: only **transport-level failures**
count as circuit failures. Specifically:

- **Counted**: HTTP 502, 503, 504, socket errors (connection refused,
  timeout, DNS failure).
- **Not counted**: 4xx (client errors, policy gates), HTTP 500 with
  `sensitive_words_detected` or `content-blocked` bodies (permanent
  content policy, not transient upstream failure).

The rationale: `500 sensitive_words_detected` is a deterministic
policy rejection, not a sign that the upstream is degraded. Counting
it as a circuit failure was masking healthy models for 1-10 minutes
after a single policy hit. The per-model `ModelHealth` table still
records every 4xx/5xx for `/v1/models` filtering and TUI surfacing,
even though the circuit does not open for them.

### Content filter and 504 ceiling

See `docs/CONTENT-FILTER.md` for the full empirical study. Key facts:

- agentrouter.org's content gate judges the presence of a coherent English
  instruction block in the **system message**, not the language mix of the
  whole payload. Conversation language, response language and tool output
  are neutral, except for encoded-looking content: accumulated `data:...;base64`
  URIs in tool results over ~2,200 chars per request trip the gate with a
  hard `content-blocked`, and Google Docs `kix.` element IDs (e.g.
  `kix.kuawx1xiz6sv`) do the same once a large request accumulates enough
  of that pattern. The bridge scrubs both from every request-body JSON
  string before forwarding (`scrubBase64Payload()` in
  `lib/src/server/proxy.dart`), on both the OpenAI and Anthropic paths.
  Multimodal image content blocks (OpenAI `image_url`, Anthropic `image`)
  are preserved untouched so real uploaded reference images reach the
  model; scrubbing those broke upstream base64 decoding.
- The bridge therefore does **not** strip the system prompt by default.
  The legacy v0.1.6 strip (`trimSystemMessages`, 8000-char cap + tag
  removal) is gated behind `config.trimSystemPrompt`, default `false`,
  because trimming can drop the system prompt below the filter threshold
  and cause `content-blocked`.
- Very large single requests die on an upstream **HTTP 504** (gateway
  prefill-timeout at a stable ~123s), not a filter rejection. The client
  should declare a context/input limit below the measured ceiling per
  model so auto-compaction happens first (recommended values in
  `docs/CONTENT-FILTER.md`).

## WAF cookie jar

The upstream edge (`acw_tc`, `acw_sc__v2`, `acw_sc__v3`, `cdn_sec_tc`)
is best handled as a per-profile cache:

1. `services/waf.dart` defines pure parse + merge + serialize functions.
2. `services/api_client.dart` captures cookies from `Set-Cookie` on every
   response (warmup + proxied calls).
3. `lib/src/server/proxy.dart` invokes `onWafCaptured` after every
   proxied response, which the server controller merges into the active
   profile and persists.
4. The profile store writes the updated map back to `profiles.json` on
   every `upsert`, so a restart immediately resumes with the rotated
   cookies, so no extra warmup is needed.

## Spoof header invariants

The Claude Code fingerprint in `services/spoof.dart` is the load-bearing
piece of the upstream gate. The current set was verified live on
2026-08-12 against `https://agentrouter.org`:

- `User-Agent: claude-cli/2.1.92 (external, sdk-cli)` (Anthropic Messages path `/v1/messages`, set in `services/spoof.dart`)
- `User-Agent: opencode/1.0` (OpenAI-compatible path `/v1/chat/completions`, set in `server/proxy.dart`)

Both are verified accepted by the agentrouter.org client-fingerprint
layer. A bare SDK UA (e.g. `Dart/3.x` for `/v1/chat/completions`, or the
default `HttpClient` UA) is rejected with `401 unauthorized client
detected` even with a valid chat key; `claude/*` and `Codex/*` spoofs are
also rejected. So the two spoofing values above are, as of 2026-08-13, the
minimal set that pass. If the upstream gate rotates, the failure mode is
`401 unauthorized client detected` for every request on the affected path.
The fix is a one-line bump in `spoof.dart` (for `/v1/messages`) or
`server/proxy.dart` (for `/v1/chat/completions`), then re-verify against
`/v1/models`. The live smoke test in `test/live_smoke_test.dart` is the
single source of truth for that regression.

## Login flow (API key only)

AgentRouter has no username/password registration: accounts are created and
signed into exclusively through provider OAuth (GitHub or LinuxDO). The
bridge cannot capture the provider session cookie automatically (GitHub
rejects a `redirect_uri` that is not registered on the AgentRouter OAuth
app), so the local sign-in flow is API-key only: the user pastes a
dashboard API key, it is validated against `/v1/models`, and stored. No
session token or account-info enrichment is tracked.

```
login (CLI or TUI [l])  ──> LoginFlow.start()  ──>  HttpServer.bind(127.0.0.1, ephemeral)
                                                     │
Browser  ──> GET  http://127.0.0.1:.../login  <──────┤  serve page (name + API key fields)
Browser  ──> POST .../login/token            <──────┤  LoginFlow._handleTokenSubmit
                                                     │    ├─  validate against GET /v1/models (accepts API key)
                                                     │    └─  Profile.upsert(apiKey) + stamp apiKeyAt
                                                     │         (creates a profile if none exists)
Browser  ──> GET  /success                   <──────┤  LoginFlow._serveSuccess ("return to the bridge")

CLI/TUI  <──  onResult(LoginOutcome)         <──────┘  prints "API key saved to profile X"
```

Dashboard API keys are validated against `/v1/models` (the check that
accepts them). `POST /login/token` parses an optional `name` field to name
the profile. Keys never leave the profile JSON (mode `0600`) and are never
logged. The proxy path uses the API key alone; billing (below) also works
with the API key, so no session token is required anywhere.

## Billing info (API key only)

New API panels expose OpenAI-style billing endpoints that accept a plain
dashboard API key (no session token):

```
GET /v1/dashboard/billing/subscription   -> soft_limit_usd / hard_limit_usd
GET /v1/dashboard/billing/usage?start_date&end_date -> total_usage + daily_costs
```

The TUI Profile page calls both with the active profile's `apiKey` on
startup and on `[r]`, so credit/consumption are visible without any OAuth
sign-in.

## State locations

| File | Mode | Purpose |
|------|------|---------|
| `~/.config/agrout-bridge/config.json` | `0600` | port, listen address, active profile id, optional proxy auth token |
| `~/.config/agrout-bridge/profiles.json` | `0600` | list of `{id, name, apiKey, createdAt, apiKeyAt?, wafCookies, modelCache}` |
| `~/.config/agrout-bridge/logs.jsonl` | normal | JSONL activity log (2000 entry cap, oldest evicted) |
| `~/.config/agrout-bridge/update-cache.json` | normal | last seen stable tag + timestamp (5m TTL), resolved from CDN `latest.json` |
