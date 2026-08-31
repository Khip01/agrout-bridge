# AgentRouter model-to-endpoint mapping

Which upstream endpoint — Anthropic Messages or OpenAI Chat Completions —
each model behaves best on, what we measured, and how to wire it up in
`opencode.jsonc` (or any other client). This file is the source of truth
for the recommendation; the **bridge does not auto-route** today, so the
caller still has to pick the right path. A future revision may add
auto-routing with response-shape conversion (see *Roadmap* below).

> Scope: this file covers the five models exposed by AgentRouter that
> are part of the bridge's default install. New models need a fresh
> probe before they can be added to the recommendation table.

### Naming convention: `/An` and `/Op` suffix

To make the path assignment visible in the OpenCode model picker, every
model entry in `opencode.jsonc` carries a short suffix on its display
`name`:

- **`/An`** — served from the Anthropic path (`/v1/messages`). Use for
  the Claude family and any model the probe showed was more reliable
  on that path, in particular `glm-5.3` (moved here on 2026-08-28
  after the OpenAI path returned repeated 400 / `sensitive_words`).
- **`/Op`** — served from the OpenAI path (`/v1/chat/completions`). Use
  for the rest, in particular `gpt-5.6-sol` and `deepseek-v4-flash`.

The model *id* (the key under `provider.X.models`) stays the raw model
name (`claude-opus-5`, `glm-5.3`, …) — only the display `name` gets the
suffix. The suffix is purely a UI label; the bridge does not look at
it. The actual routing is decided by which provider block the model
sits under (Anthropic vs OpenAI), and that block's `npm` field is what
tells the OpenCode SDK which path to use.

## Why this matters

The bridge forwards client requests to AgentRouter along two HTTP paths
that the upstream treats very differently:

| Caller path                  | Upstream format            | Bridge UA spoofed |
| ---------------------------- | -------------------------- | ----------------- |
| `POST /v1/messages`          | Anthropic Messages API     | `claude-cli/2.1.92` |
| `POST /v1/chat/completions`  | OpenAI Chat Completions    | `opencode/1.0`     |

A model name placed in the body is forwarded verbatim — the bridge
does not (yet) translate between the two formats, nor does it move a
request to the "other" path if the chosen one is the wrong fit. Picking
the wrong path is the single most common reason for `Bad Request`,
`400`, or `sensitive_words_detected` from AgentRouter when the model
itself is healthy.

OpenCode's default provider block in `opencode.jsonc` has no `npm`
field for the AgentRouter provider, so OpenCode routes via the
OpenAI-compatible path. That works for some models, breaks for others
(see Probe results below).

## How we measured

Three sources, in priority order:

1. **AgentRouter admin panel** — the *Supported endpoint types* column
   for each model on the provider dashboard. This is what the upstream
   accepts at all; the only signal that is authoritative for "the
   upstream will not even parse this".
2. **Live probe through the bridge** — 3-shot reliability test for each
   (model, path) combination, sending `"halo!"` with `max_tokens=30`
   and recording HTTP status, latency, and content excerpt. Probe
   data captured in `/tmp/opencode/probe_reliability.py` and
   `/tmp/opencode/probe_endpoints.py` (not committed; not reproducible
   without a real AgentRouter key).
3. **Operational log** — observations from `logs.jsonl` (see
   `docs/ARCHITECTURE.md` for the log layout) on what real sessions
   saw on each path. Used to catch patterns the one-shot probe missed,
   such as the `sensitive_words_detected` spike on `glm-5.3` via the
   OpenAI path on 2026-08-28.

For models that the operator has no remaining budget for at probe time
(`402 Budget pool quota has been exhausted`), the recommendation falls
back to the panel signal alone and is marked **panel-only**.

## Recommendation table

| Model              | `supported_endpoint_types` (panel) | Anthropic path probe (3-shot)         | OpenAI path probe (3-shot)              | Recommendation | Display name (suffix)       |
| ------------------ | ----------------------------------- | ------------------------------------- | -------------------------------------- | -------------- | ---------------------------- |
| `gpt-5.6-sol`      | `openai`                            | 402 (budget)                          | 402 (budget)                           | **openai** (panel-only — only one path accepted by upstream) | `AgentRouter - GPT 5.6 SOL /Op` |
| `claude-opus-4-8`  | `anthropic`, `openai`               | 402 (budget)                          | 402 (budget)                           | **anthropic** (panel-only — Claude family canonical home) | `AgentRouter - Claude Opus 4.8 /An` |
| `claude-opus-5`    | `anthropic`, `openai`               | 402 (budget)                          | 402 (budget)                           | **anthropic** (panel-only — Claude family canonical home) | `AgentRouter - Claude Opus 5 /An` |
| `deepseek-v4-flash` | `openai`, `anthropic`              | 3/3 200 OK, ~1435 ms avg              | 3/3 200 OK, ~1252 ms avg               | **openai** (faster, stable on both) | `AgentRouter - DeepSeek V4 Flash /Op` |
| `glm-5.3`          | `anthropic`, `openai`               | 3/3 200 OK, ~2123 ms avg              | 3/3 200 OK, ~1450 ms avg               | **anthropic** (stable — moved off `openai` after intermittent 400 / `sensitive_words_detected`; see *caveat* below) | `AgentRouter - GLM 5.3 /An` |

### `deepseek-v4-flash` caveat

`deepseek-v4-flash` is recommended on the **OpenAI path** (`/Op`).
It probed stable on both paths (3/3 200 OK each), and the OpenAI
path was marginally faster (~1,252 ms vs ~1,435 ms avg). It stays
on `/Op`.

However, `deepseek-v4-flash` on the OpenAI path is **more sensitive
to the `sensitive_words_detected` 500 gate** than GLM-5.3. During
hcnsec.cn provider research, politically sensitive Chinese phrases
entered the session as tool output (`assistant`/`tool` history).
DeepSeek tripped 500 on those phrases; GLM on the Anthropic path
tolerated the same payload. The root cause was content, not the
path; moving DeepSeek to the Anthropic path did not help.

Fix shipped in v0.1.25: the bridge scrubs those phrases (protection
B, `scrubSensitiveZh`) before forwarding on every request. With the
scrub active, DeepSeek on `/Op` returns 200 OK for the same sessions
that previously triggered the 500. The recommendation remains
`openai` (`/Op`).

If `sensitive_words_detected` 500 re-appears on DeepSeek after a new
session accumulates new Chinese content in `assistant`/`tool` history:
check `AGRROUT_DEBUG=1` dumps for the phrase, add it to
`_sensitiveZhRegex` in `lib/src/services/translator.dart`, and
re-probe. See `docs/CONTENT-FILTER.md` "sensitive_words_detected"
and `docs/LANGUAGE-GATE.md` "Sensitive Chinese phrase scrub".

### `glm-5.3` caveat

The recommendation for `glm-5.3` was **changed from `openai` to
`anthropic`** on 2026-08-28 after the OpenAI path kept returning
intermittent 400 / 500 / `sensitive_words_detected` responses during
real sessions. The Anthropic path (`/v1/messages`) has been stable in
3-shot probe every time it was tested.

Bridge log excerpt of the OpenAI-path flakiness:

```
2026-08-28T03:57:03  PROXY 400 (stream) model=glm-5.3 in=0 out=0 3.001s
2026-08-28T03:57:12  PROXY 400 (stream) model=glm-5.3 in=0 out=0 2.956s
2026-08-28T04:01:26  PROXY 400 (stream) model=glm-5.3 in=0 out=0 8.830s
2026-08-28T04:08:05  PROXY 200 (78 tokens)   model=glm-5.3 in=14 out=64 3.478s
2026-08-28T04:08:54  PROXY 200 (204 tokens)  model=glm-5.3 in=26 out=178 3.924s
2026-08-28T04:08:55  PROXY 500 (0 tokens)    model=glm-5.3 in=0 out=0 60ms
2026-08-28T04:09:33  PROXY 200 (189 tokens)  model=glm-5.3 in=25 out=164 4.011s
2026-08-28T06:02:16  PROXY 400 (stream) model=glm-5.3 in=0 out=0 6.160s
2026-08-28T06:03:43  PROXY 400 (stream) model=glm-5.3 in=0 out=0 4.103s
```

Between 06:00 and 07:59 the OpenAI path was 9 successes out of 11
attempts (~18% failure rate) for `glm-5.3`, and the body of every 400
came back as `Content-Length: 0` from upstream (OpenCode renders that
generic as `Bad Request`). The payload sent by the client was
identical between the successful and failed requests in the same
session, so the trigger is upstream-side, not the client.

If `glm-5.3` on the Anthropic path also starts failing, revert the
move (drop the `glm-5.3` block from the Anthropic provider) and
re-probe both paths; the recommendation in the table at the top of
this file is the single source of truth.

### `claude-opus-*` panel-only notes

`claude-opus-5` and `claude-opus-4-8` were unable to be probed live
because the operator's AgentRouter budget pool was exhausted
(`402 Budget pool quota has been exhausted` from the upstream) for the
entire window in which the probe was attempted. The recommendation
*anthropic* is from the panel signal plus the Claude family's
canonical upstream format. Once budget is restored, run the same
3-shot probe to confirm.

## Per-model example configurations

The two blocks below use the **same** bridge `baseURL`; they only
differ in the `npm` field, which selects the OpenCode SDK and therefore
the path the client uses to reach the bridge. Place both under
`provider` in `opencode.jsonc` and assign models by name.

### Anthropic-compatible block (use for `claude-opus-*` and `glm-5.3`)

```jsonc
"Khip01 - AgentRouter (Anthropic)": {
  "npm": "@ai-sdk/anthropic",
  "name": "AgentRouter (Anthropic-compatible)",
  "options": {
    "baseURL": "http://127.0.0.1:8318/v1",
    "apiKey": "anything"
  },
  "models": {
    "claude-opus-5": {
      "name": "AgentRouter - Claude Opus 5 /An",
      "attachment": true, "tool_call": true,
      "temperature": true, "reasoning": true,
      "limit":   { "context": 900000, "input": 900000, "output": 8192 },
      "modalities": { "input": ["text","image"], "output": ["text"] },
      "cost": { "input": 8, "output": 40 }
    },
    "claude-opus-4-8": {
      "name": "AgentRouter - Claude Opus 4.8 /An",
      "attachment": true, "tool_call": true,
      "temperature": true, "reasoning": true,
      "limit":   { "context": 900000, "input": 900000, "output": 8192 },
      "modalities": { "input": ["text","image"], "output": ["text"] },
      "cost": { "input": 8, "output": 40 }
    },
    "glm-5.3": {
      "name": "AgentRouter - GLM 5.3 /An",
      "attachment": true, "tool_call": true,
      "temperature": true, "reasoning": true,
      "limit":   { "context": 420000, "input": 420000, "output": 8192 },
      "modalities": { "input": ["text","image"], "output": ["text"] },
      "cost": { "input": 3, "output": 12 }
    }
  }
}
```

### OpenAI-compatible block (use for `gpt-5.6-sol`, `deepseek-v4-flash`)

```jsonc
"Khip01 - AgentRouter (OpenAI)": {
  "npm": "@ai-sdk/openai-compatible",
  "name": "AgentRouter (OpenAI-compatible)",
  "options": {
    "baseURL": "http://127.0.0.1:8318/v1",
    "apiKey": "anything"
  },
  "models": {
    "gpt-5.6-sol": {
      "name": "AgentRouter - GPT 5.6 SOL /Op",
      "attachment": true, "tool_call": true,
      "temperature": true, "reasoning": true,
      "limit":   { "context": 420000, "input": 420000, "output": 8192 },
      "modalities": { "input": ["text","image"], "output": ["text"] },
      "cost": { "input": 3, "output": 15 }
    },
    "deepseek-v4-flash": {
      "name": "AgentRouter - DeepSeek V4 Flash /Op",
      "temperature": true, "reasoning": true,
      "limit":   { "context": 420000, "input": 420000, "output": 8192 },
      "modalities": { "input": ["text"], "output": ["text"] },
      "cost": { "input": 2, "output": 6 }
    }
  }
}
```

`deepseek-v4-flash` is **text-only** on AgentRouter; the `attachment`
flag and the `image` modality are omitted to avoid a misconfigured
request from the client. If a future AgentRouter update adds image
support, the field is a one-line change.

## Common pitfalls

1. **OpenCode provider with no `npm` field falls back to OpenAI
   path.** Without `npm: @ai-sdk/anthropic`, OpenCode uses
   `@ai-sdk/openai-compatible` by default. Adding the `npm` field is
   how you tell it to use the Anthropic path on the same `baseURL`.
2. **Anthropic path does not accept `model` names that the upstream
   only supports on the OpenAI path.** The bridge will return 4xx
   from upstream, not from the bridge. Check the panel
   `Supported endpoint types` column before adding a model to either
   block.
3. **`sensitive_words_detected` is an upstream filter, not a bridge
   bug.** It is the same `content-blocked` family that
   `docs/CONTENT-FILTER.md` discusses. Moving to a different path does
   not necessarily help; if the trigger is the request content
   itself, compact and retry.
4. **Caching the path assignment is not safe across models.** A
   single provider block that mixes, say, `claude-opus-5` and
   `gpt-5.6-sol` *will* send the wrong model to the wrong path. Keep
   the Anthropic and OpenAI models in separate provider blocks; the
   `baseURL` is shared but the `npm` field and the model list differ.
5. **`max_tokens` differs between paths.** Anthropic path needs
   `max_tokens` at the request root; OpenAI path uses
   `max_tokens` *or* `max_completion_tokens` for newer models. The
   bridge does not translate; the client must send the field the
   chosen path expects.

## How to verify

Run a one-shot probe and compare to the table above. The probe is
sized to be cheap (10 small requests, < $0.01 even at the most
expensive tier):

```bash
KEY=sk-...                                    # the upstream key
for m in gpt-5.6-sol claude-opus-4-8 claude-opus-5 deepseek-v4-flash glm-5.3; do
  for path in /v1/messages /v1/chat/completions; do
    body=$(case "$path" in
      /v1/messages)        echo "{\"model\":\"$m\",\"max_tokens\":30,\"messages\":[{\"role\":\"user\",\"content\":\"halo!\"}]}";;
      /v1/chat/completions) echo "{\"model\":\"$m\",\"max_tokens\":30,\"messages\":[{\"role\":\"user\",\"content\":\"halo!\"}]}";;
    esac)
    echo -n "$m $path "
    curl -sS -o /dev/null -w "%{http_code} %{time_total}s\n" \
      "https://agentrouter.org$path" \
      -H "Authorization: Bearer $KEY" \
      -H "Content-Type: application/json" \
      -H "User-Agent: opencode/1.0" \
      -d "$body"
  done
done
```

If a model moves between paths (e.g. AgentRouter adds a new
`supported_endpoint_type`), update this file and `CHANGELOG.md`
together with the new probe data.

## Roadmap

Auto-routing and response-shape conversion (Anthropic Messages API
↔ OpenAI Chat Completions) was discussed and **deferred** in the v0.1.24
cycle as too risky to ship in one pass. The full proposal:

- Default mapping lives in `~/.config/agrout-bridge/model_endpoint_map.json`
  (user-editable).
- `server_controller` reads the mapping on every request, decides
  the upstream path from the *model name* (not the caller path),
  converts the body and the streamed response when the caller path
  and the model-preferred path differ.
- Conversion scope for v1: text + thinking blocks, non-streaming
  only. Tool use, image blocks, and SSE streaming are follow-up
  work.

Until that ships, this document is the operator's manual.
