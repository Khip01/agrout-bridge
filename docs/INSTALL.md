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
- `[l]` open the local sign-in link (to add an API key)
- `[Ctrl+L]` toggle the log side panel
- `[q]` quit

## Pointing clients at the bridge

Every client uses the same base URL, an arbitrary `apiKey` placeholder,
and a model id from the live `/v1/models` list. The declared
`context`/`input` limits below are **research-recommended**: they sit a
~5-10% margin below the measured agentrouter.org ceiling for each model so
the client auto-compacts before the gateway returns `504`. Measured
values, methodology, and the exact probe data live in
[`docs/CONTENT-FILTER.md`](CONTENT-FILTER.md). Update the numbers if the
upstream ceiling shifts.

| Model | Measured ceiling (cold) | Recommended declared limit |
|---|---|---|
| `gpt-5.6-sol` | ~432k tokens | context `420000`, input `420000`, output `8192` |
| `claude-opus-5` | ~1.0M tokens (998,593 measured OK) | context `900000`, input `900000`, output `8192` |
| `claude-opus-4-8` | same family, assume ~1.0M | context `900000`, input `900000`, output `8192` |

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

The `limit` block is what the research recommends: keep `context` and
`input` at those values so auto-compaction fires while the request still
fits. Everything else is the standard OpenCode model entry.

### Claude Code (env vars)

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8318
export ANTHROPIC_AUTH_TOKEN=anything
```

`claude` sends `x-api-key: anything` and the bridge forwards it
(stripped); AgentRouter authenticates with the active profile's API
key, not the client's placeholder. Claude Code keeps its own model
metadata, so configure the research-recommended limits in
`~/.claude/settings.json` (reveal `contextWindow` / `maxTokens` for each
`claude-opus-*` entry), following the same "~5-10% below measured ceiling" rule.

### Cursor

Cursor takes an OpenAI-compatible base URL + model id via Settings >
Models > Add model. Point it at `http://127.0.0.1:8318/v1`, add the
desired model id, and set the context/token limit in the model dialog to
the recommended values from the table above.

### Continue

`~/.continue/config.json`:

```jsonc
{
  "models": [
    {
      "title": "AgentRouter",
      "provider": "openai",
      "model": "claude-opus-5",
      "apiBase": "http://127.0.0.1:8318/v1",
      "apiKey": "anything",
      "contextWindow": 900000,   // research-recommended
      "maxTokens": 8192
    }
  ]
}
```

Any other OpenAI-compatible client (LiteLLM, OpenRouter-style proxies,
custom scripts) follows the same pattern: base URL
`http://127.0.0.1:8318/v1`, placeholder `apiKey`, a model id from
`/v1/models`, and the recommended `context`/`input` from the table
above.

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

If port `8318` is already in use (e.g. a stale bridge process), the server
auto-increments to the next free port for that run only. It is never
persisted, so a restart returns to `8318` once the stale listener is gone.
Check the actual listen port with `curl http://127.0.0.1:8318/info`; the
response reports the bound port as `serverPort` and the configured default
as `configuredPort` (try `8319`/`8320` if `8318` is refused).

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
