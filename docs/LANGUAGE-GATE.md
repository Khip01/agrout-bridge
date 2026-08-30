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

## Tuning and control

The translator runs only when `config.translateUserMessages` is `true`
(default). Disable it from the TUI on the **Proxy Config** page
(`[4]` then `[t]`) if a session is being chewed up by the
translation step — the toggle is in-memory and persists to
`~/.config/agrout-bridge/config.json` on change.

## Limitations

- Detection is best-effort. A single Indonesian word slips through the
  detector and the bridge forwards it; the gate did not trigger in
  that case in our probes. Two-word Indonesian phrases (`"Halo,
  apa"`) do trigger. The bridge does not second-guess the detector —
  it relies on the upstream endpoint to make the call.
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