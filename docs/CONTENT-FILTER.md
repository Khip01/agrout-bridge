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
   tool results and web-fetch contents are all neutral, **with one
   exception: base64-encoded blobs** (see below).
3. **Filler does not count.** Repeating boilerplate English (lorem-style
   text) is rejected; real, varied, imperative instruction text is what
   passes. A "dummy" file of random words therefore cannot act as a filter
   bypass and can actively trip the gate.

## Base64-encoded blobs in tool results trip the gate

The "tool results are neutral" rule above fails for base64-encoded content.
WebFetch (format=markdown) and file-read tool results embed images, logos
and fonts as `data:image/png;base64,...` URIs. Enough of those, accumulated
across the tool results of a single request, reads as obfuscated content to
the gate and produces a hard `content-blocked` (HTTP 400), even when the
system prompt is a perfect English anchor:

| Tool content (the only variable) | Result |
|---|---|
| 3 webfetch markdown results, no base64 | **200 OK** |
| rh1 markdown (58,979 chars, base64 total 12,992, longest run 2,408) | `content-blocked` |
| rh2 markdown (59,097 chars, base64 total 13,118) | `content-blocked` |
| hf markdown (7,147 chars, base64 total 1,982, runs <= 58) | **200 OK** |

The trigger is the **aggregate base64 payload per request**, not the request
size: measuring with isolated base64 runs, 2,167 chars in one run passes and
2,250 chars blocks; 2 runs of 1,050 (total 2,105) pass and 2 runs of 1,150
(total 2,305) block. The threshold sits around **~2,200 chars of base64 per
request**. High-entropy random letter strings trigger the same way; plain
words, digits, hex and URLs do not, so the gate appears to flag "encoded /
obfuscated-looking" text.

This explains why a session can pass compaction (tool output is truncated to
`TOOL_OUTPUT_MAX_CHARS = 2000` per tool, below the threshold) yet fail a
later step once 2-3 webfetch results carrying logo data URIs land in the
same request.

The bridge neutralizes this before forwarding: `scrubBase64Payload()` walks
every JSON string value in the body and replaces `data:...;base64,...` URIs
and bare base64 runs (>= 200 chars) with a short placeholder. Plain text,
URLs and tool-call arguments are left untouched. The scrub runs for both the
OpenAI and Anthropic paths.

**Image content blocks are preserved.** Since v0.1.13 the scrub detects
multimodal image parts (OpenAI `image_url` content block, Anthropic `image`
content block with a `source` map) and leaves their data URI / base64 data
untouched. These carry real uploaded reference images the model must see
(for example a first frame for image-to-video generation); replacing them
made upstream fail with `illegal base64 data at input byte 0`. Base64
hidden in text, tool results and WebFetch markdown is still scrubbed.

## Google Docs `kix.` element IDs also trip the gate

The "encoded / obfuscated-looking text" rule has a second, harder hit that
showed up in a real session (2026-08-14, video-analysis workflow): Google
Docs element IDs. Whenever the agent discusses document structure it quotes
real element IDs of the form `kix.kuawx1xiz6sv` (a `kix.` prefix plus a
random lowercase-alphanumeric suffix, ~13-16 chars total).

Live probing with a ~620k-char reconstruction of the failing request showed
the gate is cumulative here:

| Added token (only variable, base = 399-entry request) | Result |
|---|---|
| `kix.kuawx1xiz6sv` (16 chars) | `content-blocked` |
| `kix.kuawx1xiz` (13 chars) | `content-blocked` |
| `kix.kuawx1xi` (12 chars) | **200 OK** |
| `zzz.kuawx1xiz` / `abc.kuawx1xiz` (other prefix) | **200 OK** |
| `kix.zzzzzzzzzzzzz` / `kix.abcdefghijklm` (low-entropy suffix) | **200 OK** |
| `kix.1a2b3c4d5e6f` (regular digit pattern) | **200 OK** |

So the gate flags the `kix.` prefix combined with a high-entropy mixed
alphanumeric suffix once the request accumulates enough encoded-looking
content (the same token at base sizes up to ~350 entries passes; at the
~620k-char boundary it blocks). This is distinct from the base64 trigger:
it is the *content*, not the byte size, and plain-length or low-entropy
tokens do not trip it.

The bridge scrubs these before forwarding: `scrubBase64Payload()` also
replaces `kix.` element IDs (and the bare `kix` + suffix form, no dot) with
a short placeholder in every JSON string value. Short tokens that do not
match the pattern are untouched.

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
event. The numbers below were measured on `gpt-5.6-sol`:

| System | Model | History | Result | First event |
|---|---|---|---|---|
| AGENTS.md | gpt-5.6-sol | ~425k tokens | 200 OK | 64s |
| AGENTS.md | gpt-5.6-sol | ~450k+ tokens | HTTP 504 | never |
| AGENTS.md | gpt-5.6-sol (stream) | ~450k+ tokens | HTTP 504 | never |

On `claude-opus-5` (measured 2026-08-16, budget pool restored) prefill is
much faster and the gateway 504 does not appear before the model's own 1M
context window: 998,593 input tokens returned 200 (first event at 61s),
~1,018k returned 504 (137s), and ~1,046k was rejected by the model itself
with HTTP 400 "Operation not allowed". See the recommended-limits table
below for client settings.

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
- A **cold single request** that ships everything in one go hits the
  ceiling (for `gpt-5.6-sol` that is ~450k tokens; for `claude-opus-5` the
  model's 1M window wins first). Real sessions grow incrementally: the
  older history is served from upstream prompt cache (cheap prefill) and
  only the delta is processed, which is why long sessions in practice reach
  far beyond the cold-request ceiling.

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
| `claude-opus-5` | **~998k** (OK at 61s first event; ~1.0M+ = 504 prefill or 400 Bedrock context limit) | context `900000`, input `900000` | `8192` |
| `claude-opus-4-8` | not re-measured (same Anthropic/Bedrock family); assume the ~1.0M ceiling of `claude-opus-5` | context `900000`, input `900000` | `8192` |

The recommended limit keeps a safety margin below the ceiling: the client
starts auto-compaction while the request still fits, instead of the gateway
returning 504. The `gpt-5.6-sol` cold ceiling of ~432k already produced its
first stream event at 123s, right at the ~120s gateway timeout, so the
declared 420k limit leaves a meaningful safety band for upstream load
variation. The `claude-opus-5` ceiling measured on 2026-08-16 stops just
under ~1.0M tokens: 998,593 actual prompt tokens returned 200 with the
first event at 61s, ~1,018k hit the upstream 504 after 137s (prefill-time
gateway limit), and ~1,046k was rejected by the Bedrock-backed model with
HTTP 400 "Operation not allowed" (model context window). Claude-family
clients should therefore declare ~900k to compact a comfortable margin
before the model's 1M window, keeping the gateway prefill well under its
timeout. Verify per model by sending a single large cold request and
recording the largest size that returns 200 before 504; then set the
declared limit ~5-10% below it.

Note the ceiling can shift with upstream load, model changes and network
latency. The safety margin (and aggressive client auto-compact settings)
absorbs that drift.
