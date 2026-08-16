# agrout-bridge

AgentRouter bridge for OpenCode, Claude Desktop, Cursor, and any OpenAI-/Anthropic-compatible client.

The bridge is a local HTTP proxy that forwards client requests to
`https://agentrouter.org` while adding the Claude Code client fingerprint the
upstream gate expects. It manages the WAF session cookie (`acw_tc`) per profile
and survives restarts. The TUI dashboard (nocterm) exposes live model health,
request usage, profile state, and proxy diagnostics. Headless mode runs the
same proxy without a TUI for daemon / Docker usage.

## Auth

The bridge identifies itself to AgentRouter with an API key (`sk-...`). Each
profile stores one key plus an optional session token captured from a local
sign-in flow. AgentRouter has no username/password registration, so the
sign-in page opens provider OAuth (GitHub / LinuxDO) and accepts a pasted
API key / session token; credentials login is not supported. The pasted
value is validated against `/v1/models` (accepts dashboard API keys) and
stored as the profile `apiKey`. The Profile page shows credit/usage fetched
with the API key from the OpenAI-style billing endpoints
(`/v1/dashboard/billing/subscription` and `/v1/dashboard/billing/usage`),
so no session token is required to see quota or consumption. Provider OAuth
runs in the browser; the session token is pasted back into the local page
(the bridge cannot read the agentrouter session cookie, and GitHub rejects
a `redirect_uri` that is not registered on the AgentRouter OAuth app).

```
agrout-bridge profile add <name>      # prompt for key
agrout-bridge profile list
agrout-bridge profile use <name>
agrout-bridge profile remove <name>
agrout-bridge profile login           # open local sign-in link, capture session token
agrout-bridge profile logout
agrout-bridge profile whoami          # show account info for the active profile
```

State lives in `~/.config/agrout-bridge/`. API keys and session tokens are
written with file mode `0600` and are never logged.

## Architecture

### Stack

- Language: Dart 3.10+
- TUI: `nocterm` v0.8.0
- Server: `dart:io` `HttpServer`
- HTTP client: `dart:io` `HttpClient`
- Compile: `dart compile exe` -> single native binary
- Distribution: npm tarball with Node.js launcher wrapper

### File structure

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
│       │   ├── profile.dart        # Profile + Config stores (port persist)
│       │   └── version.dart        # Bridge version constant
│       ├── services/
│       │   ├── spoof.dart          # Claude Code spoof header constants
│       │   ├── waf.dart            # WAF cookie jar (warmup, capture, merge, persist)
│       │   ├── api_client.dart     # AgentRouter HTTP (New API endpoints)
│       │   ├── login.dart          # Local sign-in callback server + OAuth provider relay
│       │   ├── usage_store.dart    # Aggregated usage + cost from response billing
│       │   ├── log_store.dart      # JSONL activity log
│       │   └── updater.dart        # Self-update: API cache + download .tgz + npm install -g
│       ├── server/
│       │   ├── server_controller.dart # HTTP server + routing
│       │   ├── openai_handler.dart    # OpenAI-compatible proxy
│       │   ├── anthropic_handler.dart # Anthropic-compatible proxy
│       │   └── sse.dart               # SSE stream pump (format-aware terminator)
│       └── tui/
│           └── app.dart            # Nocterm TUI: 4 pages + log side panel
├── scripts/
│   └── stage-npm-package.mjs       # CI packaging helper: assembles release tarball
├── .github/
│   └── workflows/
│       ├── test.yml                # Dart analyze + test + smoke
│       ├── release.yml             # Matrix build + tarball + GitHub release
│       └── post-release.yml        # Install simulation from real asset
├── docs/
│   ├── INSTALL.md
│   ├── API-REFERENCE.md
│   ├── TUI.md
│   └── ARCHITECTURE.md
├── test/
├── AGENTS.md
├── CHANGELOG.md
├── README.md
├── package.json
├── pubspec.yaml
├── build / run                     # Linux/macOS scripts
├── build.bat / run.bat             # Windows batch scripts
└── LICENSE
```

## CLI contract

```bash
agrout-bridge run                        # TUI mode (auto-starts proxy)
agrout-bridge run --server               # Headless server mode
agrout-bridge profile add <name> [key]   # Add API key profile (prompt if key omitted)
agrout-bridge profile list
agrout-bridge profile use <name>
agrout-bridge profile remove <name>
agrout-bridge profile login              # Local sign-in flow (copy URL in TUI)
agrout-bridge profile logout
agrout-bridge profile whoami
agrout-bridge update                     # Download and install latest stable release
agrout-bridge help
agrout-bridge --version
```

The npm wrapper (`bin/agrout-bridge.js`) detects `process.platform`, maps to
the correct native binary (`app-linux`, `app-mac`, `app-win.exe`), and spawns
it with `stdio: 'inherit'`. `--version` is intercepted in the wrapper (reads
`package.json`). All other args are forwarded to Dart.

## Distribution

End-user install from a `.tgz` asset attached to a GitHub Release:

```bash
npm install -g ./agrout-bridge-vX.Y.Z.tgz
agrout-bridge run
```

Requirements: Node.js 18+ (for the npm launcher), an AgentRouter account.

### Release workflow

Triggered by pushing a tag matching `v*` or `[0-9]*`:

1. **Build matrix** (3 OS):
   - ubuntu-latest -> `app-linux`
   - macos-latest -> `app-mac`
   - windows-latest -> `app-win.exe`
   - Each: `dart compile exe` + upload artifact
2. **Package job** (ubuntu-latest, stable releases only):
   - Download 3 binary artifacts
   - Run `scripts/stage-npm-package.mjs` which assembles the npm package folder
   - Run `npm pack` to produce `agrout-bridge-vX.Y.Z.tgz`
   - Upload tarball artifact
3. **Release job** (stable releases only):
   - Create GitHub Release with the tarball asset

Stable releases exclude tags with `-rc`, `-beta`, `-alpha`. Prerelease tags
produce binaries but skip packaging and release jobs.

### Post-release validation

Triggered by `release: published` or manual dispatch:

1. Download the real published tarball from GitHub Releases
2. Install to isolated npm prefix
3. Verify `agrout-bridge` command exists
4. Smoke test headless mode (`agrout-bridge run --server`)
5. Uninstall

### Tag strategy

| Pattern | Type | Release behavior |
|---------|------|------------------|
| `v1.0.0` | Stable | Full build + package + GitHub Release |
| `v1.0.1-rc1` | Prerelease | Build binaries only |
| `v1.0.1-beta1` | Prerelease | Build binaries only |
| `v1.0.1-alpha1` | Prerelease | Build binaries only |

### Why npm tarball instead of `npm install -g <git-url>`?

npm v11 has a bug installing global git deps: the install appears to succeed
(`added 1 package`) but the binary is missing. Always install from a local
tarball.

## Platform support

| Platform | Status | Clipboard | Build |
|----------|--------|-----------|-------|
| Linux | Primary | `wl-copy` -> `xclip` -> OSC 52 | `./build` |
| macOS | Experimental | `pbcopy` -> OSC 52 | `./build` |
| Windows | Experimental | `clip` -> OSC 52 | `build.bat` |

## Proxy endpoints

| Path | Method | Description |
|------|--------|-------------|
| `/v1/chat/completions` | POST | OpenAI-compatible chat completions (stream + non-stream) |
| `/v1/messages` | POST | Anthropic-compatible Messages API (stream + non-stream) |
| `/messages` | POST | Anthropic-compatible Messages API (alt path) |
| `/v1/models` | POST | Live model list (filtered by accessible set, unhealthy models removed) |
| `/health` | GET | Status + WAF cookie + circuit + streams |
| `/v1/token` | GET | Return a static pass-through token |
| `/info` | GET | Bridge info + config |

OpenCode (Anthropic compatible) configuration:

```jsonc
"AgentRouter": {
  "npm": "@ai-sdk/anthropic",
  "name": "AgentRouter",
  "options": {
    "baseURL": "http://127.0.0.1:8318/v1",
    "apiKey": "anything"
  },
  "models": {
    "claude-opus-4-8": {
      "name": "claude-opus-4-8"
    }
  }
}
```

OpenCode (OpenAI compatible) configuration:

```jsonc
"AgentRouter OpenAI": {
  "npm": "@ai-sdk/openai-compatible",
  "name": "AgentRouter (OpenAI Compatible)",
  "options": {
    "baseURL": "http://127.0.0.1:8318/v1",
    "apiKey": "anything"
  },
  "models": {
    "claude-opus-4-8": {
      "name": "claude-opus-4-8"
    }
  }
}
```

## Handling upstream content-blocked

When OpenCode/Claude Code sessions grow very large (common with big
codebases), agentrouter.org's input content filter can reject the request
with `402 Budget pool quota has been exhausted` or a soft
`content-blocked` / `sensitive_words` mid-stream line. The bridge
mitigates the most common false positives before forwarding — see
`CHANGELOG.md` v0.1.6 and `docs/ARCHITECTURE.md` (spoof invariants):

1. **System-prompt stripping is OFF by default.** Live probing of the
   filter (2026-08, see `docs/CONTENT-FILTER.md`) shows the gate judges the
   presence of a coherent English instruction block in the system message,
   not the language mix of the conversation. Trimming the system prompt can
   drop below that threshold and cause `content-blocked`. The bridge keeps
   the legacy strip behind `config.trimSystemPrompt` (default `false`); it
   is not needed because OpenCode's own English `default.txt` system block
   is sufficient to pass.
 2. **Encoded content is scrubbed before forwarding.** WebFetch (markdown)
    and file-read tool results embed images as `data:...;base64,...` URIs,
    and document-focused sessions carry Google Docs `kix.` element IDs.
    Accumulated base64 over ~2,200 chars per request trips the gate with a
    hard `content-blocked`, and a `kix.` element ID does the same once a
    large request accumulates enough of that pattern (see
    `docs/CONTENT-FILTER.md`). The bridge strips base64 data URIs, bare
    base64 runs (>= 200 chars) and `kix.` element IDs from every JSON
    string in the body before forwarding (`scrubBase64Payload()`), for both
    the OpenAI and Anthropic paths. Multimodal image content blocks (OpenAI
    `image_url`, Anthropic `image`) are preserved untouched so real uploaded
    reference images reach the model.
3. **Accepted client fingerprint.** Upstream only lets specific
   `User-Agent`s through (see docs/ARCHITECTURE.md). The bridge spoofs
   `opencode/1.0` (OpenAI path) and `claude-cli/2.1.92` (Anthropic path).
4. **SSE passthrough.** In streaming mode, mid-stream
   `content_blocked` / `sensitive_words` / `billing.summary` / `data: null`
   lines are dropped (logged to the activity log) instead of aborting the
   stream, so OpenCode keeps receiving partial responses.
5. **Port auto-increment (no ratchet).** If `8318` is occupied by a stale
   bridge process, `ServerController.start()` retries the next free port
   (8318 -> 8319 -> 8320, bounded to 25 attempts). The escalated port is
   used only for the current process and is never persisted back into the
   config store, so a restart returns to the configured default once any
   stale listener is cleaned up. `/info` reports the actual bound port as
   `serverPort` and the configured default as `configuredPort`.

The 504 ceiling on very large requests is a **prefill-time limit of the
upstream gateway** (stable ~123s timeout), not a filter rejection and not
a bridge bug. The client should declare a context/input limit below the
measured ceiling so it auto-compacts before the 504 (see
`docs/CONTENT-FILTER.md` for measured values per model). If you still hit
a hard `content-blocked`, it is an upstream policy decision, not a bridge
bug — request a budget-policy/quota adjustment on your AgentRouter account
or route Claude traffic directly via a non-AgentRouter provider.

## Port

Default port: `8318` (continuity with the upstream agentrouter-spoof-proxy).
Config persisted at `~/.config/agrout-bridge/config.json`. Port can be changed
via `[p]` panel in the TUI (with availability scan + auto-increment fallback).
Empty input = reset to default. If the configured port is occupied at startup,
the bridge binds the next free port for that run without persisting it; the
actual bound port is visible via `/info` (`serverPort`) and `/health`.

## TUI pages

| Key | Page | Data |
|-----|------|------|
| `1` | Profile | Active profile, session info, WAF state |
| `2` | Usage & Cost | Token + cost aggregates from response billing |
| `3` | Models | Live model list + per-model health |
| `4` | Proxy Config | Port, endpoints, uptime, circuit, active streams |

The Models page mirrors the `commandcode-bridge` picker: rows are grouped by
model family, the highlighted row is a bold cyan `▸` chevron, models with
recent upstream failures are flagged yellow, and the navigation keys
(`up`/`down`/`Enter`/`PgUp`/`PgDn`) are scoped to that page only.

## Logging

`LogStore` writes a JSONL activity log (max 2000 entries) to
`~/.config/agrout-bridge/logs.jsonl`. It is initialised in `main.dart` before
the server starts, so **headless mode logs too** (the TUI re-inits, which is
idempotent).

Per-request lines:

```
[ts] PROXY 200 (5073 tokens) model=gpt-5.6-sol in=5064 out=9 4.160s
[ts] PROXY 200 (stream) model=claude-opus-5 in=14 out=50 1.204s
[ts] GET /health (312 bytes)
```

Proxy requests are logged from the `onOutcome` callback (so model + token
counts + duration come from `ProxyOutcome`); open endpoints are logged inline in
`_handle`. The TUI log panel groups entries under full-date dividers
(`Today - Sunday, 16 Aug 26` / `Yesterday - ...` / `Friday, 14 Aug 26`).

The status bar's left slot is a single indicator: `Proxy stopped` (red),
`Streaming (N)` (yellow), a transient status message, or `Proxy ready` (green).
The right side shows uptime plus the time since the last model refresh.

## Versioning

`bridgeVersion` in `lib/src/models/version.dart` reads the `PACKAGE_VERSION`
dart-define with a hard-coded fallback. `build` and `build.bat` read
`package.json`'s `version` and pass it via
`--dart-define=PACKAGE_VERSION=<v>`, so the compiled binary's `--version` and
the TUI header always match the released tarball. Keep the fallback in sync
with `package.json` when bumping a release.

## Key bindings

| Key | Context | Action |
|-----|---------|--------|
| `1-4` | Main | Switch page |
| `r` | Main | Refresh page data |
| `o` | Main | Copy OpenAI endpoint URL to clipboard |
| `a` | Main | Copy Anthropic endpoint URL to clipboard |
| `p` | Main | Port configuration panel |
| `l` | Main | Login panel (sign-in link) |
| `h` | Main | Help panel |
| `q` | Main | Quit confirmation |
| `up/down` | Main | Scroll / navigate |
| `PgUp/PgDn` | Main | Scroll 10 lines |
| `up/down` | Models page | Move the model highlight |
| `Enter` | Models page | Copy selected model id |
| `PgUp/PgDn` | Models page | Scroll the model list by 10 lines |
| `Ctrl+L` | Main | Toggle log side panel |
| `f` | Log open | Toggle log fullscreen / side panel |
| `Shift+C` | Log open | Clear all log entries (Y/N confirmation) |
| `Shift+O` | Log open | Clear entries before today (Y/N confirmation) |
| `y` / `n` | Clear confirm | Confirm / cancel the pending clear |

## Changelog

This project maintains a `CHANGELOG.md` file. Release bodies include a short
summary with a link to the changelog for full details.

## Agent maintenance rules

When making changes to this project, the AI agent must:

1. Sync `CHANGELOG.md` for every functional change before commit.
2. Keep `AGENTS.md` in sync with the actual project state (file structure,
   CLI contract, distribution flow).
3. **Sync `package.json` `version` with the new release tag.** Before creating
   a stable tag, update `package.json` to match `vX.Y.Z` (no leading `v`).
   The release workflow reads this field to name the npm tarball
   (`agrout-bridge-vX.Y.Z.tgz`) and to validate the `--version` intercept in
   `bin/agrout-bridge.js`. A mismatched version produces a tarball that does
   not match its tag — do not skip this.
4. Never commit API keys, session tokens, or any `~/.config/agrout-bridge/`
   artifact. `.gitignore` must cover them.
