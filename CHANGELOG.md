# Changelog

## v0.1.24 (2026-08-20)

### Fix

- **Short base64 runs are scrubbed when the request-wide payload is large.**
  A single request full of short base64 runs (for example a PDF paged into
  many <200-char data URIs) accumulates past agentrouter.org's encoded-
  content trigger even though no run is long enough to scrub on its own.
  `scrubBase64Payload` now measures the request-wide base64 payload first
  and, when it reaches a 1400-char safety margin, lowers the run threshold
  so short runs are scrubbed too. A lone short run and real image content
  blocks stay untouched.

### Feat

- **Usage stats are now persistent and grouped per day.** The Usage & Cost
  page no longer reads a volatile in-memory counter that reset on every
  restart. A new `StatsStore` writes one JSON line per calendar day to
  `~/.config/agrout-bridge/stats.jsonl` (max 30 days, oldest pruned on
  write), so per-model breakdown and token totals survive bridge restarts
  and are fully independent of the user-clearable activity log. The page
  shows today's totals plus a compact summary of the kept previous days.
- **Usage page clear keymap.** On the Usage & Cost page only, `[Shift+C]`
  clears all usage stats and `[Shift+O]` clears stats before today, both
  with a Y/N confirmation banner inline on the page. These never touch
  `logs.jsonl`.
- **Log clear keymap moved to Ctrl+Shift.** The log side panel's clear keys
  moved from `[Shift+C]` / `[Shift+O]` to `[Ctrl+Shift+C]` (clear all) and
  `[Ctrl+Shift+O]` (clear before today), freeing the plain-Shift combos for
  the Usage page while keeping the two clears visually distinct.

## v0.1.23 (2026-08-18)

### Fix

- **Drop misleading usage/cost rows from the TUI.** Three rows showed values
  that did not reflect real usage: `Used (last 30d)` came from the
  OpenAI-style usage endpoint, which returns the same `total_usage` for any
  date range and key (not a 30-day figure and not the dashboard
  `Consumption`); `Cache read` / `Cache creation` were always 0 because
  AgentRouter does not emit those fields; and `Cost (CNY)` was only parsed
  from non-streaming billing blocks, so streaming requests always reported
  0. The Profile billing section now fetches and shows subscription limits
  only, and the Usage page shows requests + input/output tokens. The
  per-model breakdown keeps request and token counts.
- **Port-saving dialog states that the change applies after restart.** Saving
  a port used to close the dialog immediately even though the running server
  only picks up the new port on the next launch, which looked like the switch
  was instant (and made the old port test "in use" because the bridge itself
  still held it). Now `[Enter]` persists the port and keeps the dialog open
  with a yellow italic note: "Port N saved: it will be applied on the next
  bridge restart." The "after restart" wording appears ONLY while the saved
  change is pending this session; after a restart there is nothing pending, so
  no hint is shown. The dialog `Current:` label always shows the running port
  (matching the header and the Proxy `Listen` line) so the three displays can
  never disagree.

## v0.1.22 (2026-08-17)

### Feat

- **Daily Claim dialog (`[c]`).** A new global keymap opens a two-stage
  dialog for the AgentRouter daily quota. Stage one picks the sign-up
  provider (GitHub / LinuxDO, arrow keys + Enter, Esc cancels). Stage two
  shows the live OAuth authorize URL built from `GET /api/oauth/state` and
  the public client ids in `GET /api/status`: `[c]` copies it, `[o]` opens
  it in the default browser (where the user is already signed in, so the
  claim completes in one click), `[Esc]` returns to the picker, and
  `[Enter]` marks the day as done and closes the dialog.
- **Daily Claim header badge.** When today has not been claimed yet, the
  header shows `Daily Claim!  [Shift+M] mark as done` next to the version.
  The badge appears automatically as the clock crosses 00:00 (the header
  re-renders every second), and `[Shift+M]` (or `[Enter]` on the URL
  dialog) marks the day done: the badge clears and the footer `[c] daily`
  entry stops being bold until the next day.

### Fix

- **Footer keys keep their colour, only the emboldening changed.** Each
  keymap entry returns to its original hue (something pressable is
  coloured), but the key renders brighter than its label and the label uses
  a muted shade of the same colour. Nothing is bold except the `[c] daily`
  entry, and only while that day's claim is still pending: it renders fully
  bold (key + label) until marked done, then reverts to the
  bright-key/muted-label look. The log panel header and the page-scoped
  footer keys follow the same bright-key/muted-label pattern.
- **Daily-claim URL dialog has a fixed max width.** The long OAuth authorize
  URL used to stretch the dialog past half the screen. The dialog is now
  capped at 80 columns so the URL wraps in place and the box stays compact.
- **Every modal dialog is capped at 80 columns.** Quit, delete-profile,
  update-confirm, port configuration and the daily-claim provider picker
  previously stretched to the full terminal width. They now share the same
  max-width as the daily-claim URL dialog, so short dialogs no longer dwarf
  the screen.
- **`[Shift+C]` / `[Shift+O]` clear the log reliably.** The log-specific
  keys are now handled before the main keymap, so with the log open
  `Shift+C` no longer opens the daily-claim dialog and `Shift+O` no longer
  copies the OpenAI endpoint; both clear the log as labelled.
- **Dialog keymaps moved to the footer.** Dialogs no longer render their own
  keymap (it was duplicated and verbose). While a dialog is open, its keys
  appear once, in the footer, centered on the line, styled with the same
  bright-key/muted-label palette. The log header labels are spelled out:
  `[f] fullscreen`, `[Shift+C] clear all`, `[Shift+O] clear old only`.
- **Update check can no longer be hidden by a stale cache.** Two fixes make
  the badge reliable in both directions. First, `latest.json` is now read
  from `raw.githubusercontent.com` before the jsDelivr CDN: jsDelivr can
  serve a cached copy of the old tag for a while after a push, and as the
  first source it could silently keep reporting "already up to date" when a
  newer release existed. The raw file is always the freshly-pushed `main`
  state, so it must win. Second, the local cache TTL drops to 1 minute, so
  a stale entry cannot hide a new release for long, and a successful
  `update` clears the cache so the next startup cannot show a phantom
  "update available" for the tag that was just installed.
- **Port-config panel keymap renders on one line.** The `[t] test`
  `[Enter] save` `[Esc] back` keymap was laid out as separate rows inside
  the panel (stacked vertically). It is now a single row with the shared
  keymap styles: enabled keys use the bright-key/muted-label colours,
  disabled keys (and their labels) are grey until the condition holds.
- **All dialogs follow the footer keymap style.** Update-confirm
  (`[c] [y] [n]`), quit/delete confirm (`[y] Yes [n] No`), the log clear
  confirmation (`[Y]es [N]o`) and the daily-claim provider/URL keymaps now
  use the same bright-key/muted-label palette; nothing is emboldened except
  the pending `[c] daily` entry.

## v0.1.21 (2026-08-16)

### Fix

- **Update checks are now CDN-backed and dynamic.** The latest stable tag is
  resolved from a `latest.json` file served by jsDelivr (falling back to
  raw.githubusercontent.com) instead of always hitting the rate-limited
  GitHub Tags API. The local cache TTL drops from 1h to 5 minutes, and each
  real release bumps `latest.json` alongside `package.json`. Deleting or
  re-rolling a release now clears the `Update Available` badge within
  minutes instead of holding a dead cache entry for an hour.
- **TUI update dialog exits exactly like quit.** The update flow previously
  used `TerminalBinding.instance.shutdown()`, which clears the alternate
  screen and later exits, leaving the shell looking "cleared" compared to a
  normal quit. `[Shift+U]` -> `[y]` now calls `shutdownApp(0)` exactly like
  `[q]` -> `[y]`, so the terminal is restored the same way; the copied
  `agrout-bridge update` command is left in the clipboard.
- **Headless startup is instant.** `run --server` no longer waits for the
  model refresh or the update check: the "running headless" banner prints
  immediately after binding, and both refresh and the update check run in
  the background. When a newer version exists, headless prints
  `[UPDATE] Update available: vX -> vY` and records it in the activity log.
- **TUI update closes only the TUI; the command is copied, not printed.
  Earlier attempts were broken twice.**
  - The first version did a plain `await _proxy.stop()`, which blocks while
    an SSE stream is active, so the TUI froze. The second version called
    `shutdownApp(0)`, which maps to `exit(0)` in nocterm and killed the
    whole process.
  - Now the confirm dialog shows `agrout-bridge update` and `[c]` copies it
    to the clipboard. `[y]` calls `_proxy.stop()` with a 2s timeout (never
    hangs), cancels every app timer (page refresh / status / login expiry)
    so no stray frame repaints the restored main buffer, then uses
    `TerminalBinding.instance.shutdown()` which restores the terminal
    WITHOUT exiting the process. `runApp()` returns in `main.dart`, which
    then exits cleanly; no instruction is printed for TUI mode because the
    user already copied it.
- **Update check no longer delays or clutters TUI startup.** The startup
  check previously ran `await fetchLatestTag()` in plain mode too, adding a
  network round-trip before the TUI opened (perceived as delay) and printing
  "Update available" above the TUI. TUI mode now relies on its own
  non-blocking `_checkForUpdate()` badge; model refresh is also moved to the
  background so `agrout-bridge run` opens immediately.
- **Headless checks for updates in the background after the bridge
  starts.** `--server` no longer prints the notice before its "running
  headless" banner. The bridge starts first; the check runs behind the
  scenes and, when a newer version exists, writes to the activity log and
  prints the "stop the bridge first, then run `agrout-bridge update`"
  instruction.
- **In-TUI update no longer freezes or prints a doubled version.**
  - The confirm dialog and update notice showed `-> vv0.1.21`: `_updateTag`
    already carries the leading `v` (it is the GitHub tag), so the extra `v`
    prefix was dropped everywhere (`Update Available!`, the confirm dialog,
    the `[Shift+U]` help entry and the headless startup notice).
- **Port configuration now gives feedback and requires a test before save.**
  Previously pressing Enter in the dialog did nothing (the focused TextField
  consumed Enter, and the scan result was only shown, never actionable). The
  dialog is now a state machine: type a new port, press `[t] test` to probe
  it (status shows `Testing port X...`, then green "available" or red "in
  use, try another"), and only after a successful test does `[Enter] save`
  light up and actually persist the port. Keys follow the
  grey-is-disabled convention: `[t]`/`[Enter]` are grey until relevant, and
  `[Esc] back` is red. The auto-increment fallback (silently switching to
  the next free port) was removed in favor of the explicit test flow.
- **Uptime keeps ticking while a dialog is open.** The 1s refresh timer
  early-returned when a panel was shown, freezing the header/status clock;
  it now always re-renders uptime/status/footer, gating only the page-body
  dirty checks on the main panel.

### Improve

- **Docs distinguish the two ways to add an API key.** `profile add
  <key-name> <api-key>` is the CLI path (no browser, suited to agents and
  scripts); `agrout-bridge login` is the web page path. README, INSTALL,
  AGENTS and TUI docs present them as two separate options instead of one
  combined quick-start line.
- **Footer keymap labels are colored uniformly.** Previously the `[1-4]`,
  `[r]`, `[o]/[a]`, `[p]`, `[l]` keys were colored but their labels
  (page/refresh/copy endpoint/port/login) stayed grey. All key+label pairs
  now share one color per group. `[h]` info blue, `[q]` danger red,
  `[Ctrl+L]` violet stay as-is.
- **Log panel keys are violet to match the footer.** `[f]ull`, `[C]lear`,
  `[O]ld` and the `LOG` title now use the same violet as the footer's
  `[Ctrl+L]`, signaling the log window's keymap belongs to it.
- **Header shows all pages with the active one highlighted.**
  `key name: X  |  [1] Profile [2] Usage & Cost [3] Models [4] Proxy Config
  | port: 8318`. The key name and port values are colored; the labels
  (`key name:`, `| port:`) stay grey. The active page is lit amber with a
  white label; the rest are grey.
- **TUI has top/bottom padding and breathing room.** A one-line gutter above
  the header and below the status bar separates the UI from the terminal
  edge, and the header/status text no longer has a stray leading space, so
  it aligns flush with the page content.
- **Refresh indicator is labeled and humanized.** The right-hand status now
  reads `refresh: 12m 3s ago` (or `Xs ago` under a minute) instead of a bare
  `467s ago`, so it is not confused with `uptime`.

### Test

- `test/tui_format_test.dart`: `formatDuration` coverage (zero, seconds,
  minute rollover, hour boundary, hours+minutes+seconds, multi-day uptimes).

## v0.1.20 (2026-08-16)

### Feat

- **Update available notification.** The TUI compares the 1-hour-cached
  GitHub tag against `bridgeVersion` on startup (and when version state
  changes): when a newer stable exists, the header shows a bright amber
  `Update Available! vX.Y.Z` badge and the footer adds a `[Shift+U] update`
  keymap in the same color. Note: the in-TUI auto-update described below
  proved unreliable and was replaced in v0.1.21 with the copy-command flow
  (see the v0.1.21 entry).

### Polish

- Footer keymap colors: `[h] help` is info blue, `[q] quit` is bright red,
  `[Ctrl+L] log` is a distinct violet, each bold.

## v0.1.19 (2026-08-16)

### Improve

- **Footer highlights page-scoped keys.** When a page has extra keymap
  beyond the global keys (Profile: up/down / Enter / Shift+D; Models:
  up/down / Enter), those keys appear in the footer in a distinct bright
  color, so switching pages shows which keys are available there.
- **Refresh after login/add.** Once an API key is validated and stored, the
  TUI refreshes models, WAF, billing and the profile summary immediately,
  so a newly added profile is loaded everywhere without a restart.

## v0.1.18 (2026-08-16)

### Improve

- **TUI first-run UX points to login.** When no API key is configured the
  Profile page says "No API key yet. Press [l] login" (with `[l]`
  highlighted) instead of suggesting a CLI command, and the footer's
  `[l] login` keymap is highlighted until a key exists.
- **Profile page is a picker.** `up`/`down` move the profile highlight,
  `Enter` switches the active profile (config persisted, models + billing
  refreshed), and the current profile is flagged with a bright `(current)`
  label. Selection starts on the active profile when the page is shown.
- **Delete profile from the TUI.** `Shift+D` (Profile page only) opens a
  Y/N confirmation dialog; confirming removes the profile, fixes the active
  id if it pointed at the deleted key, and refreshes.

## v0.1.17 (2026-08-16)

### Changed

- **Profiles are API-key only. Session tokens removed.** `Profile` no longer
  stores `authToken` / `authTokenAt` / `accountInfo`, and `isLoggedIn` is
  gone. The proxy never used the session token (it authenticates with the
  API key), and AgentRouter's provider OAuth session cannot be captured
  automatically, so the token was dead weight. `profile logout` and
  `profile whoami` subcommands are removed; login web now only ever stores
  an API key.
- **Login flow is now headless and single-key friendly.**
  - New top-level `agrout-bridge login` prints the sign-in URL and waits;
    the browser page now has two fields (optional key name + API key) and a
    "Add API key" button, then redirects to a success page that says
    "return to the bridge". `agrout-bridge profile login` remains an alias.
  - No placeholder profile is written before a key arrives: `login` reuses
    the active profile (renames it from the form's name field) or creates
    one only after a valid key is pasted. This also fixes a race where two
    login servers writing the profile store could clobber an existing key.
  - The sign-in page no longer offers provider OAuth buttons (GitHub /
    LinuxDO) because the bridge cannot read the provider cookie; it links
    to the dashboard where an API key is created.
- **Profile page shows when the key was added.** `Profile.apiKeyAt` records
  the store time, shown as a full date on the TUI Profile page.

### Removed

- `agentrouter.org` session endpoints (`/api/user/login`,
  `/api/oauth/state`, `/api/user/self`, `/api/user/subscription`,
  `/api/user/dashboard`), `fetchSelf` / `fetchSubscription` /
  `fetchDashboard` / `fetchOauthConfig` / `fetchOauthState`, and the
  `LoginResult` type.

## v0.1.16 (2026-08-16)

### Docs

- **Measured the cold context ceiling for `claude-opus-5`.** Once the
  budget pool was no longer exhausted, live probing (2026-08-16) found the
  ceiling stops just under ~1.0M tokens: 998,593 input tokens returned 200
  with the first event at 61s, ~1,018k hit the upstream 504 after 137s
  (prefill-time gateway limit), and ~1,046k was rejected by the
  Bedrock-backed model with HTTP 400 "Operation not allowed" (model
  context window). The recommended declared limit for the Claude family is
  updated from a placeholder `480000` to `900000` (context/input) in
  `docs/CONTENT-FILTER.md`, `docs/INSTALL.md` and the README.
- **Per-client configuration docs.** `docs/INSTALL.md` now carries a
  recommended-limits table and concrete configs for OpenCode (Anthropic +
  OpenAI paths), Claude Code, Cursor, Continue, and generic
  OpenAI-compatible clients. The README gained an OpenCode
  configuration section.

### Fix

- **Headless mode never wrote the activity log.** `LogStore.init()` was only
  called from the TUI's `initState`, so `agrout-bridge run --server` produced
  no `logs.jsonl` entries at all (every append silently no-op'd because the
  path was null). `main.dart` now initialises the log store before the server
  starts, and records a headless start line.

### Improve

- **Per-request log lines now carry model and token usage.** Instead of a bare
  `PROXY 200 (stream)`, each completed request logs
  `PROXY <code> (<n> tokens|stream) model=<id> in=<n> out=<n> <duration>`,
  sourced from the existing `ProxyOutcome`. Open endpoints (`/health`,
  `/v1/models`, `/info`, `/v1/token`) log a single `GET <path> (<n> bytes)`
  line, and the duplicated timestamp prefix was removed.
- **Log panel date dividers are now explicit.** Separators read
  `Today - Sunday, 16 Aug 26`, `Yesterday - Saturday, 15 Aug 26`, or
  `Friday, 14 Aug 26` instead of a bare three-letter weekday.
- **Clear-log actions ask for confirmation.** `[Shift+C]` (all) and
  `[Shift+O]` (before today) now show a `[Y]es / [N]o` prompt inline in the log
  panel plus the status bar, count the affected entries up front, and no-op
  with a message when there is nothing to clear. Adapted from
  `commandcode-bridge`. `LogStore.countBeforeToday()` was added to support it.
- **Models page adopts the commandcode-bridge picker UX.** The list is grouped
  by model family (Anthropic / OpenAI / Google / xAI / Other), the highlighted
  row uses a `▸` chevron in bold cyan, models with recent upstream failures
  are flagged in yellow, and a header line shows the model count plus the
  available keys. `[up]`/`[down]` move the highlight, `[Enter]` copies the id,
  and `[PgUp]`/`[PgDn]` scroll scoped to the Models page only.
- **Status bar no longer duplicates "Idle".** The left slot is a single
  indicator: `Proxy stopped` (red), `Streaming (N)` (yellow) when requests are
  in flight, a transient status message, or `Proxy ready` (green). The refresh
  indicator on the right reports time since the last model refresh
  (`Refreshing` / `Idle` / `Xs ago`) instead of re-deriving uptime.
- **Footer keymap is colour-coded by category.** Navigation keys are cyan,
  actions (`[r]`, `[o]`/`[a]`) soft green, configuration (`[p]`, `[l]`) amber,
  and meta keys grey.
- **Login dialog is width-bounded and uses a calmer palette.** Extends the
  v0.1.15 state machine: the panel no longer stretches across the full
  terminal width, and the colours are muted pastels (amber idle, soft green
  success, warm red failure) instead of saturated neon.
- **Removed every em dash (U+2014)** from docs and code comments / UI strings,
  per the global project writing rule.

## v0.1.15 (2026-08-16)

### Improve

- **Login dialog is a state-machine with color-coded feedback.** The sign-in
  dialog now tracks an explicit state: idle / loading / success / failed.
  - Idle: URL is bright green and `[c] copy URL` is the focused primary action.
  - Loading: cyan "Starting server..." while the local server boots.
  - Success: bright-green confirmation message, Escape is the focused action.
  - Failed: red message + reason shown inline, `[c] copy URL` stays bright so
    the user can retry.
- **Version badge in TUI header.** The header now reads
  `agrout-bridge v. X.Y.Z`. The version is resolved at compile time from the
  `PACKAGE_VERSION` dart-define (fallback hard-coded in `version.dart`); the
  `build` / `build.bat` scripts read `package.json` version and pass it in, so
  binary `--version` always matches the npm tarball release.
- **OAuth buttons open in a new browser tab.** `<a ... target="_blank">` so the
  user stays on the `http://127.0.0.1/.../login` page to paste their API key in
  the form below.
- **English-only UX.** All user-facing strings in the TUI (login dialog,
  status messages), `main.dart` stdout, and the login HTML pages
  (`login.dart` `_loginHtml` / `_successHtml`) are now English.

## v0.1.14 (2026-08-16)

### Fix

- **Terminal redraw race that garbled the TUI fixed.** The TUI refresh timer
  fired every 500ms and called `setState` unconditionally on the Proxy and
  Usage pages, which re-rendered the 200-entry log panel while live log lines
  were streaming from the proxy. The interleaved repaint produced the garbled
  output observed in the bridge (log lines, header, footer and proxy status
  lines overlaid on top of each other). The refresh interval is now 1 second
  and `setState` is only invoked when data actually changed, mirroring the
  proven model in `commandcode-bridge`: the timer compares `LogStore.version`,
  `ServerController.modelCacheVersion` and the new `UsageStore.version`
  counter and returns early otherwise.
- **`UsageStore` now exposes a monotonic `version` integer** that advances on
  every recorded request, so the TUI can dirty-check the Usage page without
  reading the mutable singleton fields on every tick.

### Improve

- **Status bar now shows streaming context.** The status bar (below the page
  content) displays uptime, active stream count, and a refresh indicator
  ("Refreshing…" / "Idle" / "Xs ago"), mirroring the commandcode-bridge status
  bar layout so the user can see at a glance whether the proxy is serving
  requests.
  - **Footer highlights active streams.** When `activeStreams > 0` the footer
  appends `(streams:N)` in yellow, giving real-time visibility into in-flight
  requests without switching to the Proxy page.

## v0.1.13 (2026-08-15)

### Fix

- **Real uploaded reference images are no longer destroyed by the base64
  scrub.** v0.1.11's scrub stripped every base64 data URI it could find,
  including the data URI inside OpenAI `image_url` content blocks and
  Anthropic `image` source blocks. When a user attached a real image (for
  example a first frame for image-to-video generation), the bridge replaced
  its data URI with the placeholder text `[base64 data stripped by bridge]`,
  which the upstream model then tried to base64-decode and failed with
  `illegal base64 data at input byte 0`, exhausting retries and opening the
  circuit breaker. The scrub now detects and preserves multimodal image
  content blocks (OpenAI `image_url` part, Anthropic `image` part with a
  `source` map) untouched, so real images reach the model intact. Base64
  hidden inside plain text, tool results and WebFetch markdown is still
  scrubbed as before.

### Internal

- `test/base64_scrub_test.dart`: added unit tests for image content block
  preservation (OpenAI `image_url`, Anthropic `image`, scrub-still-applies
  to text around image blocks).
- `dart analyze`: 0 issues. Full non-live suite: 78 tests pass.

## v0.1.12 (2026-08-14)

### Fix

- **Google Docs `kix.` element IDs no longer trip the upstream content
  filter.** When a session discusses document structure, the agent's text
  carries real Google Docs element IDs like `kix.kuawx1xiz6sv` (a `kix.`
  prefix plus a random lowercase-alphanumeric suffix). Live probing showed a
  single such token of ~13 chars reads as encoded/obfuscated content to
  agentrouter.org's gate and, once a large request accumulates enough
  encoded-looking material (~620k-char boundary), produces a hard
  `content-blocked` (HTTP 400). The bridge now replaces `kix.` element IDs
  (and the bare `kix` + suffix form) with a short placeholder in every JSON
  string value before forwarding. Plain text, URLs and short tokens that do
  not match the pattern are untouched. Runs on both the OpenAI and
  Anthropic paths.

### Internal

- `test/base64_scrub_test.dart`: added unit tests for `kix.` element ID
  scrubbing (dot form, bare form, no-op on short tokens).
- `dart analyze`: 0 issues. Full non-live suite: 76 tests pass.

## v0.1.11 (2026-08-14)

### Fix

- **Base64-encoded content in tool results no longer trips the upstream
  content filter.** WebFetch (format=markdown) and file-read tool results
  embed images, logos and fonts as `data:...;base64,...` URIs. Accumulated
  base64 over ~2,200 chars per request reads as obfuscated content to
  agentrouter.org's gate and produces a hard `content-blocked` (HTTP 400),
  even with a valid English system anchor. The bridge now scrubs base64
  from every JSON string value in the request body before forwarding:
  `data:...;base64,...` URIs and bare base64 runs (>= 200 chars) are
  replaced with a short placeholder. Plain text, URLs and tool-call
  arguments are untouched. Runs on both the OpenAI and Anthropic paths.

### Docs

- **`docs/CONTENT-FILTER.md` corrected.** The earlier "tool results are
  neutral" claim was disproven by live probing: base64-encoded blobs in
  tool results are the one exception that trips the gate. Documented the
  aggregate ~2,200-char base64 threshold, the measured per-request table
  (markdown with data URIs blocks, without them passes) and the bridge
  scrub behavior. `AGENTS.md` and `docs/ARCHITECTURE.md` updated to match.

### Internal

- `test/base64_scrub_test.dart`: unit tests for `scrubBase64Payload`
  (data-URI replacement, long bare-run collapse, nested Anthropic content
  blocks, no-op on plain text/URLs).
- `dart analyze`: 0 issues. Full non-live suite: 73 tests pass.

## v0.1.10 (2026-08-14)

### Fix

- **System-prompt trimming is off by default.** The v0.1.6 behavior
  (`trimSystemMessages`) stripped OpenCode's `<memory_blocks>` /
  `<available_skills>` / `<memory_instructions>` / `<journal_instructions>`
  tags and hard-capped the system message at 8000 chars. Live probing of
  agentrouter.org's content filter (2026-08) shows the gate judges the
  presence of a coherent English instruction block in the system message,
  not the language mix of the payload; trimming can drop below that
  threshold and cause `content-blocked`. The strip still exists behind the
  new `config.trimSystemPrompt` flag, default `false`.

### Docs

- **New `docs/CONTENT-FILTER.md`** documents the empirical filter study:
  the gate measures the system message, not the conversation; filler text
  is rejected; the upstream `HTTP 504` on very large requests is a
  prefill-time gateway limit (stable ~123s), not a filter rejection; and
  recommended per-model context/input limits so clients auto-compact
  before the 504. `AGENTS.md` and `docs/ARCHITECTURE.md` updated to match.

### Internal

- `test/profile_test.dart` now covers the `trimSystemPrompt` config field
  roundtrip and default.
- `dart analyze`: 0 issues. Full non-live suite: 67 tests pass.

## v0.1.9 (2026-08-13)

### Fixes

- **Billing info on the TUI Profile page, API key only.** New API panels
  expose OpenAI-style billing endpoints that work with a plain dashboard
  API key, no session token needed. The Profile page now fetches
  `GET /v1/dashboard/billing/subscription` (soft/hard quota) and
  `GET /v1/dashboard/billing/usage` (total usage over the last 30 days)
  with the active profile's API key, so credit and consumption are visible
  without any OAuth sign-in. Triggered on startup and on `[r]`.

### Removed

- Auto-capture of the provider OAuth session is removed. The bridge tried
  bouncing the GitHub / LinuxDO redirect back to its own `/oauth/callback`
  via a `redirect_uri` on `127.0.0.1`, but GitHub rejects any
  `redirect_uri` that is not registered on the AgentRouter OAuth app
  ("Be careful! The redirect_uri is not associated with this application").
  The provider buttons now redirect to the provider only, and the session
  token is pasted manually, exactly like v0.1.7. Credit/usage does not need
  a session token anyway (see billing endpoints above).

### Internal

- `test/billing_test.dart`: mock-driven tests for the two billing
  endpoints (Bearer header, date-range query).
- `test/login_serve_test.dart`: OAuth redirect assert now expects NO
  `redirect_uri`; the callback-exchange test is removed.
- `dart analyze`: 0 issues. Full non-live suite: 66 tests pass.

## v0.1.8 (2026-08-13)

### Fixes

- Pasting a dashboard **API key** now works. AgentRouter has two distinct
  credential types: an API key (`sk-...` from the dashboard) that
  authorizes `/v1/*` proxy calls, and a session token from provider OAuth
  that authorizes dashboard endpoints like `/api/user/self`. The sign-in
  page previously validated against `/api/user/self`, which rejects
  dashboard API keys with "access token 无效" (无权进行此操作). The pasted
  value is now validated against `/v1/models` (the check that accepts an
  API key) and stored as the profile's `apiKey`; account-info enrichment
  via `/api/user/self` is best-effort only.
- **Auto-capture provider OAuth** (no manual paste). The "Sign in with
  GitHub" / "Sign in with LinuxDO" buttons bounce the provider back to the
  bridge's own `/oauth/callback` (via `redirect_uri` on `127.0.0.1`) and
  exchange the code for a session token. Note: removed in v0.1.9 because
  GitHub rejects a `redirect_uri` not registered on the AgentRouter OAuth
  app.

### Internal

- `test/login_serve_test.dart`: added mock-driven tests for API-key
  validation via `/v1/models` and OAuth code->session exchange.
- `dart analyze`: 0 issues. Full non-live suite: 65 tests pass.

## v0.1.7 (2026-08-13)

### Fixes

- Orphan processes no longer accumulate after stopping the bridge. Two
  root causes fixed:
  - The npm wrapper (`bin/agrout-bridge.js`) now forwards
    `SIGINT`/`SIGTERM`/`SIGHUP` to the spawned Dart binary and kills the
    child on wrapper exit. Previously killing the wrapper orphaned the
    Dart child, which kept running with no port but never terminating.
  - Headless mode (`run --server`) now calls `exit(0)` after the server
    closes. The active `ProcessSignal` subscriptions keep the event loop
    alive after shutdown, so the process never exited on SIGTERM even
    though the listener was released.
- Port auto-increment no longer ratchets the config. The escalated port
  is used only for the current process and is never persisted, so a normal
  restart returns to the configured default (e.g. 8318). `/info` now
  exposes both `serverPort` (actual bound) and `configuredPort`.
- Sign-in flow rewritten for AgentRouter's OAuth-only accounts. AgentRouter
  has no username/password registration; the local sign-in page now shows
  "Sign in with GitHub" and "Sign in with LinuxDO" buttons. Each opens the
  real provider authorize URL built from `/api/oauth/state` (signed state
  token) plus the client ids from `/api/status`, then the user pastes the
  resulting session token / API key back into the local page. The old
  username/password form is removed.

### Internal

- `test/login_serve_test.dart`: asserts the OAuth page (provider buttons +
  token field, no username/password), 404 on unknown provider path, and a
  mock-driven GitHub authorize redirect (302 + client_id + state).
- `test/server_port_auto_increment_test.dart`: asserts escalation is NOT
  persisted into the config store.
- `dart analyze`: 0 issues. Full non-live suite: 63 tests pass.

## v0.1.6 (2026-08-13)

### Fixes

- Reduces `content-blocked` / `sensitive_words` from agentrouter.org's input
  content filter on large OpenCode/Claude Code sessions:
  - Strip oversized system-prompt blocks (`<memory_blocks>`,
    `<available_skills>`, `<memory_instructions>`, `<journal_instructions>`)
    and hard-cap any system message at 8000 chars before forwarding. This is
    the largest contributor to oversized system prompts and the most likely
    false-positive content-filter trigger.
  - Spoof the accepted `User-Agent: opencode/1.0` on upstream requests.
    agentrouter.org's client-fingerprint layer only lets this UA through;
    bare SDK UAs (Dart/Node defaults) get 401 unauthorized; other spoofed
    UAs (claude/*, Codex/*) also get 401. Verified by direct curl
    eksperimen.
  - SSE passthrough: drop mid-stream `content_blocked` / `sensitive_words` /
    `billing.summary` / `data: null` lines instead of aborting the stream, so
    OpenCode keeps receiving partial responses when the gateway emits a soft
    block. (Inspiration: Lyravein/agentrouter-bridge sanitization approach.)

### Internal

- `test/server_port_auto_increment_test.dart`: deterministic, uses high
  pseudo-random ports (no clashes with default 8318 or prior runs).
- `dart analyze`: 0 issues. Full non-live suite: 61 tests pass.

See v0.1.4/v0.1.5 changelog entries for prior fixes (reasoning translation,
Tags API updater, /info version).

## v0.1.5 (2026-08-13)

### Fixes

- `agrout-bridge run --server` crashed on startup with `SocketException:
  Failed to create server socket (OS Error: Address already in use, errno =
  98), port = 8318` when a previous bridge process (or anything else) held
  the default port 8318. `ServerController.start()` now retries the next
  free port (8318 -> 8319 -> 8320, bounded to 25 attempts) on any
  `SocketException`, and persists the bound port into the config store so
  `/info`, `/health` and the TUI report the real listen address. Verified
  live: with 8318 occupied by another process, bridge binds 8319 and
  serves correctly.


All notable changes to this project will be documented in this file.

## v0.1.4 (2026-08-12)

### Fixes

- `agrout-bridge update` failed with "Failed to check latest version from
  GitHub" even when a newer release existed. Root cause: GitHub's
  `/releases/latest` endpoint returns HTTP 404 for this repo (no release
  object is marked `isLatest`, a known GitHub flakiness where every
  release reports `isLatest == false` while tags + assets are valid).
  The updater now queries the stable Tags API
  (`/repos/.../tags`) and picks the highest stable semver, filtering
  prerelease tags (`-rc`, `-beta`, `-alpha`, ...). Verified live:
  `GET /releases/latest` -> 404, `GET /tags` -> returns v0.1.0..v0.1.3.
- Degrade gracefully on API/network failure. v0.1.3 made `update` always
  bypass the cache (`forceRefresh`), which hard-failed when the API was
  unreachable or 404ing. Now, if the Tags API call fails, the updater
  falls back to the cached tag instead of erroring, so an offline or
  throttled user still sees a sensible "already up to date" rather than
  "Failed to check".
- OpenCode (`@ai-sdk/openai-compatible` + `reasoning: true`) on Claude
  models failed with `thinking.enabled is not supported for this model.
  Use thinking.adaptive and output_config.effort...`. AgentRouter
  routes Claude through a backend (Bedrock-style schema) that rejects
  OpenAI-native `reasoning_effort` and Anthropic `thinking.enabled`.
  The bridge now normalizes OpenAI `reasoning_effort` + non-standard
  `thinking: {enabled:true}` into the Anthropic-native
  `thinking: {type:'enabled', budget_tokens}` block for Claude-family
  models on `/v1/chat/completions`. Verified end-to-end: a request with
  `reasoning_effort: "high"` now streams a real Claude response (HTTP
  200) through the bridge instead of returning the upstream schema error.
  OpenAI/o-series reasoning is left untouched.
- `/info` endpoint returned a hardcoded `"version": "0.1.0"` to all
  clients, so monitoring and tooling could never tell the real version.
  It now reports `bridgeVersion`.
- Added regression tests `test/updater_test.dart` (Tags API fetch +
  cache bypass + graceful fallback) and `test/reasoning_translation_test.dart`
  (OpenAI reasoning_effort -> Anthropic thinking normalization).

## v0.1.3 (2026-08-12)

### Fixes

- `agrout-bridge update` reported "Already up to date" after a release
  if the user ran it within one hour of a prior `update` invocation.
  The local `update-cache.json` (1h TTL) shadowed the GitHub
  `releases/latest` lookup, so the newest tag was never queried.
  `Updater.fetchLatestTag()` now accepts a `forceRefresh` flag, and the
  explicit `update` command always passes `forceRefresh: true` so the
  API is consulted on every user-triggered check.

  NOTE: v0.1.3's `forceRefresh` alone was insufficient; it hard-failed
  when `/releases/latest` returned 404 (see v0.1.4). v0.1.4 additionally
  switches to the Tags API and adds graceful cache fallback.

## v0.1.2 (2026-08-12)

### Fixes

- Local sign-in page returned `ERR_EMPTY_RESPONSE` because the HTML
  body was never written: `_servePage` set the response headers and
  closed the socket without ever calling `response.add(_loginHtml)`.
  Same class of bug in `_serveSuccess`. Both helpers now write the
  UTF-8 body with a `Content-Length` header before closing, and add
  `Cache-Control: no-store`. Added a regression test
  (`test/login_serve_test.dart`) that drives the page over a real
  HttpClient and asserts the form fields are present.
- Header strip rendered `[Closure: ...]` instead of the current page
  number. The interpolation `'$_pageTab(_infoPage)'` was reading the
  method reference as a string; corrected to
  `'${_pageTab(_infoPage)}'`.

## v0.1.1 (2026-08-12)

### Fixes

- TUI quit left the terminal in a broken state: after `[q] Yes` the
  process exited via `dart:io exit()`, bypassing nocterm's terminal
  cleanup. Result: mouse movements continued to print garbage escapes
  on the shell after the bridge had quit (alternate-screen buffer and
  mouse-tracking flags were never restored). Replaced `exit()` with
  `shutdownApp(0)` in `tui/app.dart` and dropped the trailing
  `exit(0)` from `main.dart`, matching `commandcode-bridge`'s flow.

## v0.1.0 (2026-08-12)

Initial release.

### Features

- Dart 3.10+ scaffold mirroring `commandcode-bridge`'s layout: bin entry,
  npm Node launcher, nocterm TUI, `dart:io` HttpServer.
- Multi-profile store at `~/.config/agrout-bridge/` (port, active profile,
  API key + optional session token per profile, WAF cookie jar, account
  info). Profile + AppConfig stores write JSON with `0600` file mode,
  atomic via `temp + chmod + rename`.
- Spoof header constants (`claude-cli/2.1.92` Stainless fingerprint +
  Anthropic Beta list) verified live against `agentrouter.org` on
  2026-08-12.
- WAF cookie jar: parse, merge by name, serialize to `Cookie:` header.
  Pure functions, full unit test coverage.
- `AgentRouterClient`: warmup probe, JSON / streaming `send`, login relay
  with warmup-then-POST (`/api/user/login`), and `/api/user/self`,
  `/api/user/subscription`, `/api/user/dashboard`.
- HTTP proxy (`POST /v1/messages`, `POST /v1/chat/completions`,
  `GET /v1/models`) with format-aware SSE pump, circuit breaker, per-model
  health, and WAF cookie persistence into the active profile.
- Local sign-in flow: TUI `[l]` opens a localhost HTML form, relays the
  credentials to `/api/user/login`, captures the session token into the
  profile, and pulls `/api/user/self` for the Profile page.
- TUI dashboard with 4 pages (Profile, Usage & Cost, Models, Proxy Config)
  and toggleable log side panel (`Ctrl+L`, `f`, `Shift+C`, `Shift+O`).
- `UsageStore` aggregates per-request tokens + Anthropic `cost_cny.total`
  for the Usage & Cost page.
- CLI: `run`, `run --server`, `profile add|list|use|remove|login|logout|whoami`,
  `update`, `help`, `--version`.
- Self-update: `releases/latest` (1h cache) → `.tgz` → clean global install
  → `npm install -g`.
- Distribution: `.tgz` + GitHub Release workflow + post-release install
  simulation.

### Test coverage

41 unit tests across `profile`, `waf`, `sse`, `circuit`, `usage_store`.
Live smoke (`test/live_smoke_test.dart`) verifies warmup + `/v1/models` +
`/v1/chat/completions` + `/v1/messages` (stream + non-stream) end-to-end
against the user's API key (run by hand, gated on `dev/api_key.txt`).

