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
| `1` | Profile | Active profile, key (masked), key-added date, billing quota/usage (via API key), selectable profile list |
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
| `t` | Port config | Test the new port (enables `[Enter]` save) |
| `l` | Local sign-in link panel (paste API key) |
| `Shift+U` | Update the bridge (shown when a newer stable exists) |
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

## Profile page

The profile list is interactive: `up`/`down` moves the highlight, `Enter`
switches the highlighted profile to active, and `Shift+D` opens a Y/N
confirm dialog to delete it (the active id is corrected if needed).

| Key | Action |
|-----|--------|
| `up/down` | Move the profile highlight |
| `Enter` | Switch the active profile |
| `Shift+D` | Delete the highlighted profile (asks Y/N) |

## Models page

| Key | Action |
|-----|--------|
| `Enter` | Copy selected model id to clipboard |

## Port configuration

`[p]` opens a centred panel with:

- A text field for the new port. Empty input resets to the default
  (`8318`).
- The desired port must be tested before it can be saved:
  `[t] test` probes it and shows `Testing port X...`, then green
  "available" or red "in use, try another".
- `[Enter] save` stays grey (disabled) until the test succeeds, then
  persists the port. `[Esc] back` returns without saving.
- The old auto-increment fallback (silently switching to the next free
  port) was removed in favor of this explicit test flow.

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
