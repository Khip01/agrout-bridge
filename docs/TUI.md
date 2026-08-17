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
| `c` | Daily claim dialog (pick GitHub/LinuxDO, copy/open the claim URL) |
| `Shift+M` | Mark today's daily claim as done (clears the header badge and footer bold) |
| `Shift+U` | Open update dialog: `[c]` copy command, `[y]` exit like quit (shown when a newer stable exists) |
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

The log header spells out the keys: `[f] fullscreen`, `[Shift+C] clear
all`, `[Shift+O] clear old only`.

## Daily claim

`[c]` opens a two-stage dialog. Stage one picks the sign-up provider
(GitHub / LinuxDO) with `up`/`down` and `Enter`; `Esc` cancels. Stage two
shows the live OAuth authorize URL (built from `/api/oauth/state` and the
public client ids in `/api/status`):

- `c` copies the URL, `o` opens it in the default browser (where the user
  is already signed in, so the claim completes in one click).
- `Esc` returns to the provider picker; `Enter` marks the day as done and
  closes the dialog.

While the day is still unclaimed, the header shows a `Daily Claim!
[Shift+M] mark as done` badge (it appears automatically as the clock
crosses 00:00), and the footer `[c] daily` entry is bold. `[Shift+M]`
marks the day done, clearing both. The dialog keymap is shown in the
footer, not inside the dialog.

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

The same flow can be started outside the TUI: `agrout-bridge login` (or
its alias `agrout-bridge profile login`) prints the URL from the shell.
If you prefer no browser at all, add the key directly over the CLI:
`agrout-bridge profile add <key-name> <api-key>`.

Keymap (active while the panel is open):

| Key | Action |
|-----|--------|
| `c` | Copy the sign-in URL to clipboard |
| `Esc` | Close the panel (and the local server) |

## Quit panel

`[q]` opens a Y/N confirmation. `[y]` / `Enter` stops the proxy and
exits. `[n]` / `Esc` returns to the main panel.

## Update flow

When a newer stable version exists, the header shows an
`Update Available!` badge and the footer adds a `[Shift+U]` key.
Pressing it opens a confirm dialog:

- `[c]` copies the update command (`agrout-bridge update`) to the clipboard.
- `[y]` exits exactly like quit (nocterm's `shutdownApp(0)`), restoring the
  terminal the same way as a normal `[q]` quit. The command is already in
  your clipboard; nothing is printed afterwards.
- `[n]` / `Esc` returns to the main panel.

The bridge does not run the update itself. After the TUI exits, paste/run
the copied command in your shell:

```
agrout-bridge update
```

The standalone command replaces the binary from a stable process, then you
can start the bridge again with `agrout-bridge run`.

Headless (`--server`) mode checks for updates in the background after the
bridge starts and logs the "stop the bridge first, then run
`agrout-bridge update`" instruction if a newer version exists.
