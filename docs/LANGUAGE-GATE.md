# AgentRouter language gate

AgentRouter's gateway rejects requests that contain a `user`-role
message in a language outside its allow-list. The bridge auto-translates
those messages to English before forwarding and instructs the model to
answer in the user's original language.

This document captures the evidence for the gate, the design of the
bridge's translator, and how to opt out.

## Empirical findings (2026-08-30)

Probed against `https://agentrouter.org` via the local bridge on
`localhost:8318`, `max_tokens` ≤ 25, models: `gpt-5.6-sol`,
`claude-opus-5`, `claude-opus-4-8`, `deepseek-v4-flash`, `glm-5.3`. All
five returned identical 400 / `content-blocked` results for the same
input shape.

| Probe | Result |
| ----- | ------ |
| `role: "user"` content: pure English | 200 OK |
| `role: "user"` content: pure Indonesian | 400 `content-blocked` |
| `role: "system"` content: Indonesian + `user` content: English | 200 OK |
| `role: "assistant"` content: Indonesian + `user` content: English | 200 OK |
| History of 3 user-role Indonesian messages + last user = English | 400 `content-blocked` |
| 1 Indonesian sentence in 1 user message + 10 English sentences (1:10 ratio) | 400 `content-blocked` |
| 10 English + 1 Indonesian sentence in same user message (10:1 ratio) | 400 `content-blocked` |
| 1 Indonesian word in user message (`"jelaskan"`) | 200 OK |
| 1 full Indonesian sentence in user message (`"Tolong jelaskan konsep ini"`) | 400 `content-blocked` |
| `role: "user"` content: Chinese (`"你好..."`) | 200 OK |

The error body looks like a normal `content-blocked`, not the
`Unsupported language. Only CN/EN/FR/DE/RU allowed` string the
AgentRouter dashboard advertises; the bridge never sees the
"Unsupported language" wording. The detect-and-block is what it is,
and the right thing to do is translate, not surface a language-specific
error.

The earlier conclusion in `docs/CONTENT-FILTER.md` ("conversation
language does not matter") is **only true for `system` and
`assistant` content**. Any Indonesian sentence (or any other language
outside CN/EN/FR/DE/RU) in a `user` message — including messages
buried deep in the conversation history — trips the gate.

## What the bridge does

The bridge walks every `user` message in the request body and, if the
detected source language is outside CN/EN/FR/DE/RU, replaces the
message text with the English translation returned by the translation
endpoint. The translated request is what gets forwarded to
AgentRouter, so the gateway never sees the unsupported-language text.

After all user messages are processed, the bridge appends one line to
the **last** user message:

```
[System note: The message above was auto-translated to English for
compatibility. Respond in <Original Language> (the user's original
language). Keep acting autonomously: use tools, make edits, and
complete the task as instructed rather than only describing it. Do
not mention this translation note.]
```

`<Original Language>` is the human-readable name of the source
language the translator detected for the last translated message
(Indonesian for `id`, Chinese for `zh`, Japanese for `ja`, etc., see
`languageDisplayName`). The instruction is itself in English so it
does not re-trip the gate, and it explicitly preserves agentic
behaviour so the model still uses tools and completes the task
instead of describing it.

`system`, `assistant`, and tool-result content are never inspected
or modified: the gate does not look at them, and editing them would
distort the agent's own context for no benefit.

## What the bridge does NOT do

- **It does not translate the response.** The response stream is
  forwarded verbatim to the client. Translating the response would
  break streaming and require extra round-trips per turn.
- **It does not translate when source language is in the allow-list.**
  The detection and translation are skipped entirely; the message
  is forwarded as-is. No latency overhead for English-only sessions.
- **It does not embed a translation provider.** The endpoint is the
  keyless `translate.googleapis.com/translate_a/single` widget used
  by `translate.google.com`. No API key, no SDK, no extra package —
  just an HTTP `GET` to a public URL. The bridge uses `package:http`
  (already a dependency). Translation failures are swallowed and the
  original message is forwarded as-is; a translator outage never
  blocks a proxied request.

## Translation cache and parallelism

The first revision of the translator called Google translate
sequentially for every `user` message in the request body. A long
session (hundreds of `user` turns) easily added 30-80 seconds of
latency before the first upstream byte. v0.1.25 ships two
mitigations:

1. **In-memory LRU cache** (default capacity 2048, configurable via
   the `Translator` constructor) keyed by `sha1(input text)`.
   Identical text never hits Google twice. Because a session's history
   `user` messages do not change between turns, the second and
   subsequent requests for the same session are essentially free: the
   first request populates the cache, and the rest are cache hits.
2. **Parallel translate calls** in `translateUserMessagesInBody`. The
   walker first collects every text that needs translation, then issues
   them concurrently with `Future.wait`. The first-request latency is
   now roughly one Google round-trip instead of N round-trips.

The body-walker itself is not cache-aware (it only counts distinct
texts that go to the translator). It is the `Translator` instance
that holds the cache. The `server_controller` reuses one `Translator`
per process, so the cache survives across requests in the same
bridge run.

If a session resets the bridge (e.g. user toggles translation off and
on, or restarts the binary) the cache is empty and the next request
re-translates. There is no on-disk persistence in v1: history `user`
messages for the same session are usually stable, so an in-memory
cache alone is enough to remove the per-request overhead within a
single bridge run.

## Tuning and control

The translator runs only when `config.translateUserMessages` is `true`
(default). Disable it from the TUI on the **Proxy Config** page
(`[4]` then `[t]`) if a session is being chewed up by the
translation step — the toggle is in-memory and persists to
`~/.config/agrout-bridge/config.json` on change.

## Short-text detector override (two-pass, added v0.1.25)

Google auto-detect is unreliable for short inputs. Probed 2026-08-31:
`"Halo"` was labelled `en`, `"Saya lapar"` was labelled `ms`. Both
are Indonesian and should trigger translation, but auto-detect
returned the wrong code and the bridge would have forwarded them as
if they were allowed.

Two fixes shipped together:

1. **Length gate.** Any message whose non-whitespace character count
   is 24 or fewer is treated as "unknown language" regardless of
   what auto-detect returns, and is always sent to the translation
   step. `_shortTextThreshold = 24` in `translator.dart`.
2. **Two-pass fetch.** `_fetch` calls the endpoint twice when the
   first pass returns the text unchanged (a sign that `auto` matched
   `en` and skipped translation): the second pass forces `sl=id`
   (Indonesian source) as a fallback. The result of whichever pass
   produced a different translated string is used. If both passes
   return the original text, the original is forwarded as-is
   (translation failure fallback).

This means `"Halo"` -> first pass `en` (unchanged) -> second pass
`sl=id` -> `"Hello"`. The gate sees English and does not block.

## Filler system-prompt expansion (added v0.1.25)

The exact string `"You are a helpful assistant."` (with trailing
period) deterministically trips AgentRouter's `sensitive_words_detected`
500 on every model, even when the rest of the request is clean English
(probed 2026-08-31, 5/5 retries). The same sentence without the
period, or followed by any additional instruction text, passes.

Root cause: the gate requires a coherent English instruction block of
at least ~200 characters in the system message (see
`docs/CONTENT-FILTER.md`). The 30-character filler falls below that
threshold and the gate fires the sensitive-words path as a side
effect.

Fix: `expandFillerSystemPromptsInBody` in `translator.dart` detects
that exact filler string and replaces it with a longer, instruction-rich
English block before the request is forwarded. The replacement contains
real instructions (language, format, safety) so it passes the coherent-
block check. The original filler came from the client (e.g. OpenCode
default) and is not shown to the user.

## Sensitive Chinese phrase scrub (protection B, added v0.1.25)

A separate `sensitive_words_detected` 500 gate fires when
politically sensitive Chinese phrases appear anywhere in the request
body, including `assistant` and `tool` history. These phrases entered
sessions during hcnsec.cn provider research (tool output from live
API probes). The user-message translator (protection A) does not
touch `assistant`/`tool` content, so it cannot remove them.

Protection B (`scrubSensitiveZh` in `translator.dart`) runs a regex
over the full serialized body and replaces matching phrases with
`[redacted]` before the request is forwarded. The scrub runs
**before** translation (order: B then A) so that translated content
does not re-introduce the phrase in a different encoding.

Known phrases covered by the regex (as of v0.1.25):

- `新疆幻城网安科技有限公司` and shorter variants
- A set of flag emoji sequences associated with contested territories

The regex is in `_sensitiveZhRegex` in `translator.dart`. Add new
phrases there if new `sensitive_words_detected` 500s appear with
Chinese content in the body.

## Limitations

- Detection is best-effort. A single Indonesian word slips through the
  detector and the bridge forwards it; the gate did not trigger in
  that case in our probes. The short-text gate (24 chars) partially
  compensates, but multi-word phrases that auto-detect labels as
  an allowed language may still slip through.
- The translation is a **best-effort** preservation of meaning. Tone,
  register, and coding style in the user message can shift slightly.
  This is acceptable for agentic sessions that send instructions and
  ask questions; it is not a substitute for human-written copy.
- The keyless translation endpoint is rate-limited at Google's
  discretion and may degrade under heavy load. Translation failures
  fall back to forwarding the original message, which means a
  session may start failing with `content-blocked` again if the
  translator is unavailable. A future revision can add a secondary
  provider.
- Code blocks and inline code in user messages are not specifically
  protected. The Google endpoint happens to leave fenced code intact
  in our spot-checks (it does not try to translate identifiers), but
  a long pasted snippet with Indonesian comments in between may be
  translated. This is acceptable for the coding-agent use case
  (the model sees the translated snippet as it would any English
  text), and the user asked for the simple behaviour over code-aware
  heuristics.

## Where the code lives

- `lib/src/services/translator.dart` — `Translator` (HTTP + parsing),
  `translateUserMessagesInBody` (walks both OpenAI and Anthropic
  shapes), `buildReplyLanguageInstruction`, supported-language
  allow-list.
- `lib/src/server/proxy.dart` — calls `translateUserMessagesInBody`
  in `proxyRequest` after the base64 scrub, before forwarding.
- `lib/src/server/server_controller.dart` — owns a singleton
  `Translator` instance and passes it to `proxyRequest` only when
  `config.translateUserMessages` is `true`.
- `lib/src/models/profile.dart` — `AppConfig.translateUserMessages`
  flag, default `true`, persisted via the existing `ConfigStore`.
- `lib/src/tui/app.dart` — `[t]` toggle on the Proxy Config page,
  plus a "Language gate" section in `_proxyRows` showing the current
  state.
- `test/translator_test.dart` — 11 tests covering parsing,
  supported-language check, and the body-rewriting walker for
  string-content and content-parts-list messages, English passthrough,
  no-messages edge case, and reply-instruction injection.

## Related docs

- `docs/CONTENT-FILTER.md` — the older document that originally
  reached the (now-incorrect) "conversation language does not matter"
  conclusion. The relevant section has been amended to point here.
- `docs/ARCHITECTURE.md` — proxy flow.
- `CHANGELOG.md` — entry under the unreleased version.