# agrout-bridge

AgentRouter bridge for OpenCode, Claude Desktop, Cursor, and any OpenAI-/Anthropic-compatible client.

The bridge is a local HTTP proxy that forwards client requests to
`https://agentrouter.org` while adding the Claude Code client fingerprint the
upstream gate expects. It manages the WAF session cookie (`acw_tc`) per profile
and survives restarts. The TUI dashboard (nocterm) exposes live model health,
request usage, profile state, and proxy diagnostics. Headless mode runs the
same proxy without a TUI for daemon / Docker usage.

## Auth

The bridge identifies itself to AgentRouter with an API key (`sk-...` from
the agentrouter.org dashboard). A profile is **API-key only**: AgentRouter
sign-in is OAuth-only (GitHub / LinuxDO) and the bridge cannot capture the
provider session cookie automatically, so session tokens and account-info
enrichment were removed. A pasted key is validated against `/v1/models`
before it is stored. The Profile page shows credit/usage fetched with the
API key from the OpenAI-style billing endpoints
(`/v1/dashboard/billing/subscription` and `/v1/dashboard/billing/usage`),
so no session token is required to see quota or consumption.

The pasted key is entered one of two ways (they store the same key):

- CLI (`profile add <key-name> <api-key>`): paste the key directly, no
  browser. Suits agents/scripts that run the bridge non-interactively.
- Web (`login`): open the local sign-in page and paste the key there.

```
agrout-bridge profile add <name> [key]   # CLI: store key directly
agrout-bridge login                      # web: open local sign-in page to paste key
agrout-bridge profile list
agrout-bridge profile use <name>
agrout-bridge profile remove <name>
```

State lives in `~/.config/agrout-bridge/`. API keys are written with file
mode `0600` and are never logged. When a key is saved (via the login page
or `profile add`), `Profile.apiKeyAt` records when it was stored so the TUI
can show the full date.

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
│       │   ├── spoof.dart          # the assistant spoof header constants
│       │   ├── waf.dart            # WAF cookie jar (warmup, capture, merge, persist)
│       │   ├── api_client.dart     # AgentRouter HTTP (New API endpoints)
│       │   ├── login.dart          # Local sign-in server (paste API key, validate /v1/models)
│       │   ├── daily_claim.dart    # Daily-claim OAuth URL builder + default-browser opener
│       │   ├── stats_store.dart    # Persistent per-day usage + cost (stats.jsonl, 30-day retention)
│       │   ├── log_store.dart      # JSONL activity log
│       │   ├── translator.dart     # User-message translation (EN/FR/DE/RU/ZH allow-list), sensitive Chinese scrub, filler expand, LRU cache, parallel dispatch
│       │   └── updater.dart        # Self-update: latest.json (raw first, CDN fallback) + Tags API fallback, download .tgz + npm install -g
│       ├── server/
│       │   ├── server_controller.dart # HTTP server + routing; owns singleton Translator
│       │   ├── proxy.dart             # Forward + WAF capture + usage extraction + debug body dumps
│       │   ├── circuit.dart           # Circuit breaker (transport-only) + per-model health
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
│   ├── ARCHITECTURE.md
│   ├── CONTENT-FILTER.md
│   ├── LANGUAGE-GATE.md
│   └── MODEL-ENDPOINTS.md
├── test/
├── AGENTS.md
├── CHANGELOG.md
├── README.md
├── package.json
├── latest.json                     # Mirrors newest stable tag; update checks via CDN
├── pubspec.yaml
├── build / run                     # Linux/macOS scripts
├── build.bat / run.bat             # Windows batch scripts
└── LICENSE
```

## CLI contract

> TUI update flow: `[Shift+U]` opens a confirm dialog showing
> `agrout-bridge update`. `[c]` copies that command to the clipboard.
> `[y]` exits exactly like quit (`shutdownApp(0)`), leaving the copied
> command in the clipboard; nothing is printed after exit. The TUI never
> runs the update in-process; the standalone command replaces the
> binary from a stable process.
>
> Headless (`--server`) update flow: the "running headless" banner prints
> immediately after binding, and the update check runs in the background.
> When a newer version exists it is printed to stdout as `[UPDATE] ...` and
> written to the activity log (`LogStore`), with the "stop the bridge
> first, then run `agrout-bridge update`" instruction.

```bash
agrout-bridge run                        # TUI mode (auto-starts proxy)
agrout-bridge run --server               # Headless server mode

# Two ways to add your API key (same result, different entry point):
#   CLI:  agrout-bridge profile add <key-name> <api-key>
#   Web:  agrout-bridge login            (opens the local sign-in page)
agrout-bridge profile add <name> [key]   # CLI: store key directly (prompt if key omitted)
agrout-bridge login                      # Web: local sign-in page to paste key
agrout-bridge profile login              # Alias of `login` (same flow)
agrout-bridge profile list
agrout-bridge profile use <name>
agrout-bridge profile remove <name>

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

### Update discovery (`latest.json`)

The bridge resolves the newest stable tag from a `latest.json` file at the
repo root, served by `raw.githubusercontent.com` FIRST (the freshly-pushed
`main` file) and falling back to the jsDelivr CDN
(`cdn.jsdelivr.net/gh/Khip01/agrout-bridge@main/latest.json`), then to the
GitHub Tags API. The raw source must be checked before jsDelivr: jsDelivr
can serve a stale cached copy after a push, and as the first source it
would hide a newer release. The file mirrors the latest *published*
release, so deleting a release stops the badge within the 1-minute local
cache TTL. Rules:

- **Real release:** bump `latest.json` (`{"tag":"vX.Y.Z"}`) in the same
  commit as `package.json` and the tag.
- **Dummy/test release (fake version for update testing):** NEVER touch
  `latest.json`. The dummy tarball may be released, but the badge only
  appears if `latest.json` actually points at it. This is what makes the
  badge dynamic and immune to re-rolled dummies.
- The standalone `update` command always uses `forceRefresh` so it reflects
  upstream truth immediately; the TUI badge uses the 1-minute cache. A
  successful `update` clears the cache so no phantom "update available"
  badge survives the install.

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

OpenCode (Anthropic compatible) configuration. The `limit` block follows
the research-recommended values in `docs/CONTENT-FILTER.md`:

```jsonc
"AgentRouter": {
  "npm": "@ai-sdk/anthropic",
  "name": "AgentRouter",
  "options": {
    "baseURL": "http://127.0.0.1:8318/v1",
    "apiKey": "anything"
  },
  "models": {
    "claude-opus-5": {
      "name": "claude-opus-5",
      "limit": { "context": 900000, "input": 900000, "output": 8192 }
    },
    "claude-opus-4-8": {
      "name": "claude-opus-4-8",
      "limit": { "context": 900000, "input": 900000, "output": 8192 }
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

Per-client configs for Claude Code, Cursor, Continue and other
OpenAI-compatible tools live in `docs/INSTALL.md`. Measured ceilings and
the methodology behind the numbers are in `docs/CONTENT-FILTER.md`.

The bridge has two upstream paths — Anthropic Messages (`/v1/messages`)
and OpenAI Chat Completions (`/v1/chat/completions`) — and **does not
auto-route between them** today. Which of the two a model is best
served from (Anthropic vs OpenAI) is documented in
`docs/MODEL-ENDPOINTS.md` with the live probe data and operational
log excerpts that justify each recommendation. If a model is added
to one block in `opencode.jsonc` and the bridge's recommendation says
the other block, the request will fail with `400` or
`sensitive_words_detected`; the caller has to pick the right block.

## Handling upstream content-blocked

When OpenCode/Claude Code sessions grow very large (common with big
codebases), agentrouter.org's input content filter can reject the request
with `402 Budget pool quota has been exhausted` or a soft
`content-blocked` / `sensitive_words` mid-stream line. The bridge
mitigates the most common false positives before forwarding (see
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
a hard `content-blocked` that the base64 scrub, `kix.` scrub, and
system-prompt trim cannot resolve, it is an upstream policy
decision, not a bridge bug. The most common remaining trigger in
2026-08-30 testing is a `user`-role message in a non-allow-listed
language; the bridge's automatic translation handles that case
without surfacing an error to the client (see
`docs/LANGUAGE-GATE.md`). Request a budget-policy/quota adjustment on
your AgentRouter account or route Claude traffic directly via a
non-AgentRouter provider as a fallback.

## Port

Default port: `8318` (continuity with the upstream agentrouter-spoof-proxy).
Config persisted at `~/.config/agrout-bridge/config.json`. Port can be changed
via `[p]` panel in the TUI: type the new port, `[t] test` probes it (green
available / red in use), and `[Enter] save` persists it only after a
successful test. Empty input = reset to default. If the configured port is
occupied at startup, the bridge binds the next free port for that run without
persisting it; the actual bound port is visible via `/info` (`serverPort`)
and `/health`.

## TUI pages

| Key | Page | Data |
|-----|------|------|
| `1` | Profile | Active profile, API key (masked), added date, billing, WAF state |
| `2` | Usage & Cost | Today's requests + tokens + per-model breakdown, saved previous days |
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

## Debug body dumps

Per-request body dumps land in `/tmp/opencode/agrout-debug/` when
debug mode is on. Enable with `AGRROUT_DEBUG=1` or by setting
`AGRROUT_DEBUG_DIR=<path>` to a custom directory. Three files per
request:

- `<ts>_in_<model>.json` — inbound body after all scrubs + translation
  (what the bridge actually forwarded to upstream)
- `<ts>_out_<model>.json` — outbound metadata (response headers, status,
  timing)
- `<ts>_upstream_<model>.json` — raw upstream response body (non-streaming
  only; empty for SSE requests to avoid double-listen)

Each file starts with a JSON metadata header (`model`, `path`,
`stream`, `status`, `request_id`, `ts`) followed by `------...------`
separator and the body. Bodies are `jsonEncode`'d so raw newlines and
control characters survive as `\n` escapes and the file stays parseable
by any JSON reader. Body is clamped to `AGRROUT_DEBUG_MAX_BODY` bytes
(default 256 KiB). Set a larger value (e.g. `AGRROUT_DEBUG_MAX_BODY=4000000`)
to capture full 2 MB+ bodies when hunting a `sensitive_words_detected`
trigger.

The default is OFF to avoid disk floods. Turn on with `AGRROUT_DEBUG=1`
in the environment when reproducing an issue; turn off again when done.
The debug directory is not cleaned up automatically.

## Usage stats

`StatsStore` persists per-request usage grouped by calendar day to
`~/.config/agrout-bridge/stats.jsonl` (one JSON line per day, max 30 days,
oldest pruned on every write). It is initialised in `main.dart` before the
server starts and re-inits in the TUI (idempotent). This file is a separate
source from `logs.jsonl` and is NEVER touched by the log clear actions; only
the Usage page clear keymap operates on it. The Usage & Cost page shows the
current day's totals + per-model breakdown and a compact summary of the
retained previous days. `Shift+C` (clear all) and `Shift+O` (clear before
today) are page-scoped to the Usage page and ask for Y/N confirmation.

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
| `t` | Port config | Test the new port before saving (`[Enter]` save disabled until it succeeds) |
| `l` | Main | Login panel (paste API key) |
| `c` | Main | Daily claim dialog (pick GitHub/LinuxDO, copy/open the claim URL) |
| `Shift+M` | Main | Mark today's daily claim as done (clears the header badge and footer bold) |
| `Shift+U` | Main | Open update dialog: `[c]` copy command, `[y]` exit like quit (shown when a newer stable exists) |
| `h` | Main | Help panel |
| `q` | Main | Quit confirmation |
| `up/down` | Main | Scroll / navigate |
| `PgUp/PgDn` | Main | Scroll 10 lines |
| `up/down` | Profile page | Move the profile highlight |
| `Enter` | Profile page | Switch the active profile |
| `Shift+D` | Profile page | Delete the highlighted profile (Y/N confirmation dialog) |
| `PgUp/PgDn` | Profile page | Scroll the profile list by 10 lines |
| `up/down` | Models page | Move the model highlight |
| `Enter` | Models page | Copy selected model id |
| `PgUp/PgDn` | Models page | Scroll the model list by 10 lines |
| `up/down` | Daily claim (picker) | Move between GitHub / LinuxDO |
| `Enter` | Daily claim (picker) | Pick the provider and show its claim URL |
| `Esc` | Daily claim (picker) | Close the dialog |
| `c` | Daily claim (URL) | Copy the claim URL to clipboard |
| `o` | Daily claim (URL) | Open the claim URL in the default browser |
| `Esc` | Daily claim (URL) | Back to the provider picker |
| `Enter` | Daily claim (URL) | Mark today's claim done and close the dialog |
| `Ctrl+L` | Main | Toggle log side panel |
| `f` | Log open | Toggle log fullscreen / side panel |
| `Ctrl+Shift+C` | Log open | Clear all log entries (Y/N confirmation) |
| `Ctrl+Shift+O` | Log open | Clear entries before today (Y/N confirmation) |
| `Shift+C` | Usage page | Clear all usage stats (Y/N confirmation) |
| `Shift+O` | Usage page | Clear usage stats before today (Y/N confirmation) |
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
   not match its tag. Do not skip this.
4. **Sync `latest.json` with the same stable tag** (`{"tag":"vX.Y.Z"}`) so
   update checks resolve it. Dummy test releases must NOT touch
   `latest.json`; only real releases bump it (see "Update discovery").
4. Never commit API keys, session tokens, or any `~/.config/agrout-bridge/`
   artifact (API keys are the credential now; session tokens no longer exist).
