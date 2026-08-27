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

| Model              | `supported_endpoint_types` (panel) | Anthropic path probe (3-shot)         | OpenAI path probe (3-shot)              | Recommendation |
| ------------------ | ----------------------------------- | ------------------------------------- | -------------------------------------- | -------------- |
| `gpt-5.6-sol`      | `openai`                            | 402 (budget)                          | 402 (budget)                           | **openai** (panel-only — only one path accepted by upstream) |
| `claude-opus-4-8`  | `anthropic`, `openai`               | 402 (budget)                          | 402 (budget)                           | **anthropic** (panel-only — Claude family canonical home) |
| `claude-opus-5`    | `anthropic`, `openai`               | 402 (budget)                          | 402 (budget)                           | **anthropic** (panel-only — Claude family canonical home) |
| `deepseek-v4-flash` | `openai`, `anthropic`              | 3/3 200 OK, ~1435 ms avg              | 3/3 200 OK, ~1252 ms avg               | **openai** (faster, stable on both) |
| `glm-5.3`          | `anthropic`, `openai`               | 3/3 200 OK, ~2123 ms avg              | 3/3 200 OK, ~1450 ms avg               | **openai** (faster — see *caveat* below) |

### `glm-5.3` caveat

On 2026-08-28 between 03:57 and 04:10 local time, the OpenAI path for
`glm-5.3` returned several 400 / 500 / `sensitive_words_detected`
responses for sessions using the default OpenCode system prompt
(roughly 8.5 KB of English boilerplate). The 3-shot probe at 21:08 the
same day showed the OpenAI path returning 200 every time. The bridge
log excerpt:

```
2026-08-28T03:57:03  PROXY 400 (stream) model=glm-5.3 in=0 out=0 3.001s
2026-08-28T03:57:12  PROXY 400 (stream) model=glm-5.3 in=0 out=0 2.956s
2026-08-28T04:01:26  PROXY 400 (stream) model=glm-5.3 in=0 out=0 8.830s
2026-08-28T04:08:05  PROXY 200 (78 tokens)   model=glm-5.3 in=14 out=64 3.478s
2026-08-28T04:08:54  PROXY 200 (204 tokens)  model=glm-5.3 in=26 out=178 3.924s
2026-08-28T04:08:55  PROXY 500 (0 tokens)    model=glm-5.3 in=0 out=0 60ms
2026-08-28T04:09:33  PROXY 200 (189 tokens)  model=glm-5.3 in=25 out=164 4.011s
```

The 400s at 03:57–04:01 used the OpenAI path; the 200s at 04:08–04:09
include both paths. The bridge itself does not change behaviour
between the two windows — the upstream just stopped returning 400 on
that path. If a `Bad Request` shows up again, the workaround is to
move the model to a provider block that uses `npm: @ai-sdk/anthropic`
on the same `baseURL` (the bridge forwards correctly on the
`/v1/messages` path).

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

### Anthropic-compatible block (use for `claude-opus-*`, optional `glm-5.3` fallback)

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
      "name": "AgentRouter - Claude Opus 5",
      "attachment": true, "tool_call": true,
      "temperature": true, "reasoning": true,
      "limit":   { "context": 900000, "input": 900000, "output": 8192 },
      "modalities": { "input": ["text","image"], "output": ["text"] },
      "cost": { "input": 8, "output": 40 }
    },
    "claude-opus-4-8": {
      "name": "AgentRouter - Claude Opus 4.8",
      "attachment": true, "tool_call": true,
      "temperature": true, "reasoning": true,
      "limit":   { "context": 900000, "input": 900000, "output": 8192 },
      "modalities": { "input": ["text","image"], "output": ["text"] },
      "cost": { "input": 8, "output": 40 }
    }
  }
}
```

### OpenAI-compatible block (use for `gpt-5.6-sol`, `deepseek-v4-flash`, `glm-5.3`)

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
      "name": "AgentRouter - GPT 5.6 SOL",
      "attachment": true, "tool_call": true,
      "temperature": true, "reasoning": true,
      "limit":   { "context": 420000, "input": 420000, "output": 8192 },
      "modalities": { "input": ["text","image"], "output": ["text"] },
      "cost": { "input": 3, "output": 15 }
    },
    "deepseek-v4-flash": {
      "name": "AgentRouter - DeepSeek V4 Flash",
      "temperature": true, "reasoning": true,
      "limit":   { "context": 420000, "input": 420000, "output": 8192 },
      "modalities": { "input": ["text"], "output": ["text"] },
      "cost": { "input": 2, "output": 6 }
    },
    "glm-5.3": {
      "name": "AgentRouter - GLM 5.3",
      "attachment": true, "tool_call": true,
      "temperature": true, "reasoning": true,
      "limit":   { "context": 420000, "input": 420000, "output": 8192 },
      "modalities": { "input": ["text","image"], "output": ["text"] },
      "cost": { "input": 3, "output": 12 }
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
