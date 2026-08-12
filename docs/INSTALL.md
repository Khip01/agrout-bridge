# Install

## Quick install (from npm tarball)

Download the latest `.tgz` from
[GitHub Releases](https://github.com/Khip01/agrout-bridge/releases/latest),
then:

```bash
npm install -g ./agrout-bridge-vX.Y.Z.tgz
agrout-bridge run
```

Restart any running opencode / Claude Desktop / Cursor session and point
the provider base URL at `http://127.0.0.1:8318/v1`.

## Updating

Once installed, update from the bridge itself:

```bash
agrout-bridge update
```

The update command fetches the latest release tag from GitHub (cached for
one hour), downloads the matching `.tgz`, removes the previous global
install, and runs `npm install -g`. A restart is required after updating.

## Quick start

```bash
# 1. Add a profile (the API key is prompted; the form masks input).
agrout-bridge profile add my-key

# 2. Run the bridge.
agrout-bridge run            # TUI mode
agrout-bridge run --server   # headless (for daemon / Docker)
```

In the TUI:

- `[1] [2] [3] [4]` switch pages
- `[r]` refresh model list
- `[o]` copy OpenAI endpoint URL
- `[a]` copy Anthropic endpoint URL
- `[p]` open the port config panel
- `[l]` open the local sign-in link (to capture a session token)
- `[Ctrl+L]` toggle the log side panel
- `[q]` quit

## Pointing clients at the bridge

### OpenCode (Anthropic compatible)

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

### OpenCode (OpenAI compatible)

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

### Claude Desktop / Claude Code (env vars)

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8318
export ANTHROPIC_AUTH_TOKEN=anything
```

`claude` sends `x-api-key: anything` and the bridge forwards it
(stripped) — AgentRouter authenticates with the active profile's API
key, not the client's placeholder.

## Build from source

```bash
git clone https://github.com/Khip01/agrout-bridge
cd agrout-bridge
./build           # dart pub get + dart compile exe
./run             # TUI mode (proxy auto-starts at 8318)
./run server      # Headless server mode
```

Requires Dart SDK 3.10+ and Node.js 18+ (Node only needed for the npm
launcher wrapper).

## Platform support

| Platform | Status | Clipboard | Build |
|----------|--------|-----------|-------|
| Linux | Primary | `wl-copy` -> `xclip` -> OSC 52 | `./build` |
| macOS | Experimental | `pbcopy` -> OSC 52 | `./build` |
| Windows | Experimental | `clip` -> OSC 52 | `build.bat` |

## File locations

| File | Location |
|------|----------|
| Config | `~/.config/agrout-bridge/config.json` (mode `0600`) |
| Profiles | `~/.config/agrout-bridge/profiles.json` (mode `0600`) |
| Activity log | `~/.config/agrout-bridge/logs.jsonl` |
| Update cache | `~/.config/agrout-bridge/update-cache.json` |

On Windows the path is `%APPDATA%\agrout-bridge\`.
