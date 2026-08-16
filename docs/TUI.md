# TUI reference

The TUI mirrors `commandcode-bridge`'s layout: a header strip, a
content panel that switches between four pages, a toggleable log side
panel, a status bar, and a footer with the current keymap.

## Layout

```
┌─ agrout-bridge  <profile> [3] Models port 8318 ─────────────────────┐
│ [ page content ]                    │ [ LOG (sidebar) ]              │
│                                      │                                │
│                                      │                                │
├──────────────────────────────────────┴────────────────────────────────┤
│ <status bar>                                                            │
├────────────────────────────────────────────────────────────────────────┤
│ [1-4] page | [r] refresh | [o]/[a] copy endpoint | [p] port | [l] ...   │
└────────────────────────────────────────────────────────────────────────┘
```

The log side panel can be hidden (Ctrl+L) or expanded to fullscreen
(`f`). The body layout is identical to `commandcode-bridge`'s:
content-only when the log is hidden, side-by-side flex 1/1 when the
log is a sidebar, fullscreen log when toggled.

## Pages

| Key | Page | Data |
|-----|------|------|
| `1` | Profile | Active profile, key (masked), key-added date, billing quota/usage (via API key), list of all profiles |
| `2` | Usage & Cost | Total / success / streamed request counts, success rate, tokens (in/out/cache), cumulative cost, per-model breakdown |
| `3` | Models | Live model list. Press `Enter` on a model to copy its id. |
| `4` | Proxy Config | Port, listen address, uptime, active streams, circuit state, WAF cookie entries, model health failures |

## Key bindings (main panel)

| Key | Action |
|-----|--------|
| `1`-`4` | Switch page |
| `r` | Refresh models from `agentrouter.org` |
| `o` | Copy OpenAI endpoint URL to clipboard |
| `a` | Copy Anthropic endpoint URL to clipboard |
| `p` | Port configuration panel |
| `l` | Local sign-in link panel (paste API key) |
| `h` | Help panel |
| `q` | Quit confirmation |
| `Ctrl+L` | Toggle log side panel |
| `Ctrl+C` | Status hint: use `[q]` to quit |

## Log controls (when log is visible)

| Key | Action |
|-----|--------|
| `f` | Toggle log fullscreen / sidebar |
| `Shift+C` | Clear all log entries (Y/N confirm via status bar) |
| `Shift+O` | Clear entries before today |

## Models page

| Key | Action |
|-----|--------|
| `Enter` | Copy selected model id to clipboard |

## Port configuration

`[p]` opens a centred panel with:

- A text field for the new port (`Enter` saves, `Esc` returns).
- Empty input resets to the default (`8318`).
- The bridge scans each candidate port; if `8318` is busy, it
  auto-increments to the next free port and reports the chosen value.

## Login panel

`[l]` starts a local sign-in server on `127.0.0.1:<ephemeral>` and shows
the URL. The user opens it in any browser and pastes an AgentRouter
dashboard API key (`sk-...`), optionally with a key name. AgentRouter has
no username/password registration and the bridge cannot capture the
provider OAuth session automatically, so the flow is API-key only: the
pasted value is validated against `/v1/models` and stored on the active
profile (creating one if none exists). `Profile.apiKeyAt` records when the
key was stored, shown on the Profile page.

Note: the bridge cannot auto-capture the provider session. The OAuth
cookie is set on the agentrouter.org domain, and GitHub rejects a
`redirect_uri` that is not registered on the AgentRouter OAuth app, so a
manual API key paste is the only path. Credit and usage are available from
the API key alone via the billing endpoints (see Profile page), no session
needed.

The same flow exists headless via `agrout-bridge login` (or
`agrout-bridge profile login`): the CLI prints the URL, and after the key
is saved the browser says "return to the bridge".

Keymap (active while the panel is open):

| Key | Action |
|-----|--------|
| `c` | Copy the sign-in URL to clipboard |
| `Esc` | Close the panel (and the local server) |

## Quit panel

`[q]` opens a Y/N confirmation. `[y]` / `Enter` stops the proxy and
exits. `[n]` / `Esc` returns to the main panel.
