# agentrouter content filter: what is measured, what is not

Empirical findings from live probing of agentrouter.org's input content
filter (2026-08). The bridge forwards client requests to agentrouter.org,
whose gateway applies a content-filter / quota gate before the model is
reached. Understanding what that gate measures is the difference between a
chat that works and a chat that dies with `content-blocked` or `HTTP 504`.

## The gate judges the SYSTEM PROMPT, not the conversation

Repeated deterministic probes (same request shape, varied only in one
variable at a time) produced these results:

| System prompt | User/history | Result |
|---|---|---|
| `You are a helpful assistant.` (tiny) | Indonesian short message | `content-blocked` |
| `You are a helpful assistant.` (tiny) | 66k Indonesian history, last message in ENGLISH | `content-blocked` |
| No system prompt at all | 66k Indonesian history | `content-blocked` |
| English-filler system ("The quick brown fox..." x100, ~5000 chars) | Indonesian message | `content-blocked` |
| AGENTS.md, first 100 chars only | Indonesian message | `content-blocked` |
| AGENTS.md, 200+ chars of real instructions | Indonesian message | **200 OK** |
| OpenCode default.txt (8.5KB English) only, NO AGENTS.md | 200 Indonesian turns | **200 OK** |
| AGENTS.md (18KB) only, NO default.txt | 200 Indonesian turns | **200 OK** |
| default.txt + AGENTS.md (26KB) | 125k Indonesian tokens | **200 OK** |
| AGENTS.md | 260k / 325k / 425k Indonesian tokens | **200 OK** |

Interpretation:

1. The gate looks for a **coherent English instruction block** somewhere in
   the request. That block almost always lives in the system message. The
   threshold is small (roughly 200+ characters of real imperative English);
   a 7-word boilerplate like "You are a helpful assistant." does not count.
2. **Conversation language does not matter.** 125k+ tokens of pure
   Indonesian history passes, and an all-English history still fails, as
   long as the system prompt is the only variable. The gate does not count
   the English/Indonesian ratio of the whole payload, and it does not
   re-check "the last N messages". The user prompt, assistant responses,
   tool results and web-fetch contents are all neutral.
3. **Filler does not count.** Repeating boilerplate English (lorem-style
   text) is rejected; real, varied, imperative instruction text is what
   passes. A "dummy" file of random words therefore cannot act as a filter
   bypass and can actively trip the gate.

## Consequence: never trim the system prompt away

The bridge's v0.1.6 behavior stripped OpenCode's injected
`<memory_blocks>` / `<available_skills>` / `<memory_instructions>` /
`<journal_instructions>` tags and hard-capped any system message at 8000
chars, on the theory that the system prompt is the largest false-positive
contributor. Live testing disproved that theory:

- A trimmed system prompt can drop below the "coherent English instruction"
  threshold and cause `content-blocked`.
- OpenCode always prepends its own English `default.txt` (8.5KB) system
  block, which alone is sufficient to pass. Removing the rest is therefore
  not needed for the filter, and it costs context.

The trim is now **off by default** (`config.trimSystemPrompt`, default
`false`). Only turn it on for a deployment that specifically needs the old
behavior.

## The 504 ceiling is a prefill-time limit, not a filter rejection

At large input sizes the gate no longer says `content-blocked`. It returns
`HTTP 504` with an HTML error page after a stable ~123s, before any stream
event:

| System | History | Result | First event |
|---|---|---|---|
| AGENTS.md | ~425k tokens | 200 OK | 64s |
| AGENTS.md | ~450k+ tokens | HTTP 504 | never |
| AGENTS.md (stream) | ~450k+ tokens | HTTP 504 | never |

The 504 comes from the **upstream gateway**, not the bridge (the bridge
only emits JSON errors with codes 502/503; the HTML body is upstream's).
Because the latency is constant ~123s regardless of the exact size, the
limit is time-based: prefill at 450k+ tokens takes longer than the
upstream's gateway timeout.

Practical consequences:

- The ceiling is **model-specific** (prefill speed, gateway tolerance) and
  is not a universal token number. Different models can tolerate different
  sizes before the 504 appears.
- **Shrinking the system prompt does not meaningfully raise the 504
  ceiling.** The system prompt is a few k tokens; the ceiling is set by
  total input size vs prefill time.
- **Adding dummy content lowers the ceiling.** Every token added to every
  request makes prefill slower and brings the 504 closer.
- A **cold single request** that ships 450k tokens in one go hits the
  ceiling. Real sessions grow incrementally: the older history is served
  from upstream prompt cache (cheap prefill) and only the delta is
  processed, which is why long sessions in practice reach far beyond the
  cold-request ceiling.

## What raises a real-world ceiling (and what does not)

Works:

- Keep the system prompt present and intact. It is the filter anchor.
- Prefer incremental sessions (prompt cache) over one giant cold request.
- Use models with faster prefill / a more lenient gateway timeout.
- Compact at the model-appropriate ceiling so no single request grows
  unbounded.

Does not work:

- Forcing the model to reply in English.
- Adding an English "dummy" file or padding the system prompt.
- Raising the bridge SSE idle timeout (the 504 is upstream, not the pump).
- Counting on an English/Indonesian ratio in the history.

## Configuring client context limits to compact before the 504

The client (OpenCode, Claude Code) decides when to auto-compact based on
the model's declared `context`/`input` limit. If that limit is declared
larger than what agentrouter.org can actually serve in one request, the
client never compacts and dies on the 504 instead. Set the declared
context/input limit **below** the measured ceiling for that model so the
client auto-compacts first.

Measured and recommended values (OpenAI-compatible provider block in
`opencode.jsonc` / equivalent):

| Model | Measured ceiling (cold) | Recommended declared limit | Output |
|---|---|---|---|
| `gpt-5.6-sol` | **~432k** (1730-turn OK at 123s first event; 437k = 504) | context `420000`, input `420000` | `8192` |
| `claude-opus-5` | not measurable while its budget pool is exhausted (402) | context `480000`, input `480000` | `8192` |
| `claude-opus-4-8` | not measurable while its budget pool is exhausted (402) | context `480000`, input `480000` | `8192` |

The recommended limit keeps a safety margin below the ceiling: the client
starts auto-compaction while the request still fits, instead of the gateway
returning 504. The `gpt-5.6-sol` cold ceiling of ~432k already produced its
first stream event at 123s, right at the ~120s gateway timeout, so the
declared 420k limit leaves a meaningful safety band for upstream load
variation. Verify per model by sending a single large cold request and
recording the largest size that returns 200 before 504; then set the
declared limit ~5-10% below it.

Note the ceiling can shift with upstream load, model changes and network
latency. The safety margin (and aggressive client auto-compact settings)
absorbs that drift.
