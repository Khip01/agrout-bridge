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
│       │   └── updater.dart        # Self-update: latest.json CDN + Tags API fallback, download .tgz + npm install -g
│       ├── server/
│       │   ├── server_controller.dart # HTTP server + routing
│       │   ├── proxy.dart          # Forward + WAF capture + usage extraction
│       │   ├── circuit.dart        # Circuit breaker + per-model health
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
                                           ├─ forward to https://agentrouter.org/v1/messages
                                           │
Upstream ──> 200 text/event-stream    <──  │
        (or application/json)
                                           ├─ capture fresh Set-Cookie into profile
                                           ├─ circuit.recordSuccess / Failure
                                           ├─ modelHealth.recordFailure (5xx)
                                           ├─ pumpSse for SSE; buffered copy otherwise
                                           └─ record usage + cost into StatsStore (per-day)
Client  <──  200 (or 4xx / 5xx)       <──
```

The proxy never translates between protocols. AgentRouter speaks both
Anthropic Messages and OpenAI Chat Completions natively, so each route
is a straight pass-through with the spoof + WAF layer in front.

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
