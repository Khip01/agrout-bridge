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
│       │   ├── api_client.dart     # AgentRouter HTTP client (login, self, models, chat, messages)
│       │   ├── login.dart          # Local sign-in callback server + login relay
│       │   ├── usage_store.dart    # Aggregated usage + cost from response billing
│       │   ├── log_store.dart      # JSONL activity log (2000 entries)
│       │   └── updater.dart        # Self-update: API cache + download .tgz + npm install -g
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
│   └── usage_store_test.dart
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
                                           └─ record usage + cost into UsageStore
Client  <──  200 (or 4xx / 5xx)       <──
```

The proxy never translates between protocols — AgentRouter speaks both
Anthropic Messages and OpenAI Chat Completions natively, so each route
is a straight pass-through with the spoof + WAF layer in front.

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
   cookies — no extra warmup needed.

## Spoof header invariants

The Claude Code fingerprint in `services/spoof.dart` is the load-bearing
piece of the upstream gate. The current set was verified live on
2026-08-12 against `https://agentrouter.org`:

- `User-Agent: claude-cli/2.1.92 (external, sdk-cli)`
- `X-App: cli`
- `X-Stainless-*` (`Arch`, `Lang`, `Os`, `Package-Version`, `Runtime`,
  `Runtime-Version`, `Helper-Method`, `Retry-Count`, `Timeout`)
- `Anthropic-Version: 2023-06-01`
- `Anthropic-Beta: claude-code-20250219, oauth-2025-04-20, …`
- `Anthropic-Dangerous-Direct-Browser-Access: true`

If the upstream gate rotates (e.g. it stops trusting `claude-cli/2.1.92`),
the failure mode is `401 unauthorized client detected` for every chat
request. The fix is a one-line bump in `spoof.dart` plus a re-verify
against `/v1/models`. The live smoke test in `test/live_smoke_test.dart`
is the single source of truth for that regression.

## Login flow

```
TUI [l]  ──> LoginFlow.start()           ──>  HttpServer.bind(127.0.0.1, ephemeral)
                                            │
Browser  ──> GET  http://127.0.0.1:.../login  <──┤  serve HTML form
Browser  ──> POST .../login (user + pass)  <──┤  LoginFlow._handleSubmit
                                            │
                                            ├─  AgentRouterClient.warmup()
                                            ├─  POST /api/user/login (with warmup cookies)
                                            ├─  capture session token from JSON
                                            ├─  best-effort GET /api/user/self
                                            └─  Profile.upsert(authToken + accountInfo)

Browser  ──> GET  /success                <──┤  LoginFlow._serveSuccess
                                            │
TUI       <──  onResult(LoginOutcome)     <──┘  panel updates, [Esc] closes the server
```

The local sign-in form is the only credential entry surface; the
session token never leaves the profile JSON (mode `0600`) and is
never logged.

## State locations

| File | Mode | Purpose |
|------|------|---------|
| `~/.config/agrout-bridge/config.json` | `0600` | port, listen address, active profile id, optional proxy auth token |
| `~/.config/agrout-bridge/profiles.json` | `0600` | list of `{id, name, apiKey, authToken?, wafCookies, modelCache, accountInfo?}` |
| `~/.config/agrout-bridge/logs.jsonl` | normal | JSONL activity log (2000 entry cap, oldest evicted) |
| `~/.config/agrout-bridge/update-cache.json` | normal | last seen `releases/latest` tag + timestamp (1h TTL) |
