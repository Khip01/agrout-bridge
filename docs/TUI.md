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
| `1` | Profile | Active profile, key (masked), login state, account info (when logged-in), list of all profiles |
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
| `l` | Local sign-in link panel (captures session token) |
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

`[l]` starts a local sign-in server on `127.0.0.1:<ephemeral>` and
shows the URL. The user opens it in any browser, signs in with their
AgentRouter username/password, and the bridge:

1. Warms the WAF cookie jar (`GET /`).
2. `POST /api/user/login` with the warmed cookies.
3. Stores the returned session token on the active profile.
4. Best-effort: fetches `/api/user/self` to populate the Profile page
   with username / email / quota.

Keymap (active while the panel is open):

| Key | Action |
|-----|--------|
| `c` | Copy the sign-in URL to clipboard |
| `Esc` | Close the panel (and the local server) |

## Quit panel

`[q]` opens a Y/N confirmation. `[y]` / `Enter` stops the proxy and
exits. `[n]` / `Esc` returns to the main panel.
