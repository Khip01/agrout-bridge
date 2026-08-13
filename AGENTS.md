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
stored as the profile `apiKey`; the provider buttons auto-capture a session
token by bouncing the OAuth redirect back to the bridge's `/oauth/callback`.

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

1. **System-prompt stripping.** The large OpenCode/Claude Code system
   message injects repeating context blocks
   (`<memory_blocks>`, `<available_skills>`, `<memory_instructions>`,
   `<journal_instructions>`). The bridge strips these tags and hard-caps
   any single system message at 8000 chars before forwarding, since these
   are the largest contributors to false-positive content filtering. Only
   `role: system` is trimmed — all user/assistant content is forwarded
   verbatim.
2. **Accepted client fingerprint.** Upstream only lets specific
   `User-Agent`s through (see docs/ARCHITECTURE.md). The bridge spoofs
   `opencode/1.0` (OpenAI path) and `claude-cli/2.1.92` (Anthropic path).
3. **SSE passthrough.** In streaming mode, mid-stream
   `content_blocked` / `sensitive_words` / `billing.summary` / `data: null`
   lines are dropped (logged to the activity log) instead of aborting the
   stream, so OpenCode keeps receiving partial responses.
4. **Port auto-increment (no ratchet).** If `8318` is occupied by a stale
   bridge process, `ServerController.start()` retries the next free port
   (8318 -> 8319 -> 8320, bounded to 25 attempts). The escalated port is
   used only for the current process and is never persisted back into the
   config store, so a restart returns to the configured default once any
   stale listener is cleaned up. `/info` reports the actual bound port as
   `serverPort` and the configured default as `configuredPort`.

If you still hit a hard `content-blocked`, it is an upstream policy
decision, not a bridge bug — request a budget-policy/quota adjustment on
your AgentRouter account or route Claude traffic directly via a non-
AgentRouter provider.

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
| `Enter` | Models page | Copy selected model id |
| `Ctrl+L` | Main | Toggle log side panel |
| `f` | Log open | Toggle log fullscreen / side panel |
| `Shift+C` | Log open | Clear all log entries |
| `Shift+O` | Log open | Clear entries before today |

## Changelog

This project maintains a `CHANGELOG.md` file. Release bodies include a short
summary with a link to the changelog for full details.

## Agent maintenance rules

When making changes to this project, the AI agent must:

1. Sync `CHANGELOG.md` for every functional change before commit.
2. Keep `AGENTS.md` in sync with the actual project state (file structure,
   CLI contract, distribution flow).
3. Never commit API keys, session tokens, or any `~/.config/agrout-bridge/`
   artifact. `.gitignore` must cover them.
