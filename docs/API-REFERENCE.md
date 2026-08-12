# API reference

All endpoints are served at `http://127.0.0.1:<serverPort>` (default
`8318`). The listen address is configurable via the `[p]` panel in the
TUI (persisted to `config.json`) or by passing the value at startup
(see `config.listenAddress`).

## OpenAI compatible

Base URL: `http://127.0.0.1:8318/v1`

| Path | Method | Description |
|------|--------|-------------|
| `/v1/chat/completions` | POST | OpenAI Chat Completions (stream + non-stream) |
| `/v1/models` | GET | Live model list (only models the active key can use) |
| `/v1/token` | GET | Returns the active profile's API key (localhost-only) |

The client sends `Authorization: Bearer <anything>` (or anything as
`apiKey`); the bridge forwards the active profile's real API key to
`agentrouter.org` along with the Claude Code spoof headers.

## Anthropic compatible

Base URL: `http://127.0.0.1:8318`

| Path | Method | Description |
|------|--------|-------------|
| `/v1/messages` | POST | Anthropic Messages API (stream + non-stream) |
| `/messages` | POST | Same as `/v1/messages` (alternate path) |

The client sends `x-api-key: <anything>` (or `Authorization: Bearer`).
The bridge forwards the active profile's real API key upstream.

## Diagnostics

| Path | Method | Description |
|------|--------|-------------|
| `/health` | GET | Bridge status (open) |
| `/api/health` | GET | Alias of `/health` |
| `/info` | GET | Bridge info + config |

## `/health` response shape

```json
{
  "ok": true,
  "upstream": "agentrouter.org:443",
  "listen": "127.0.0.1:8318",
  "running": true,
  "activeStreams": 0,
  "wafCookies": ["acw_tc", "cdn_sec_tc"],
  "circuit": {
    "consecutiveFails": 0,
    "openUntil": 0,
    "isOpen": false
  },
  "modelHealth": {
    "windowMs": 3600000,
    "failures": {}
  },
  "modelCount": 1,
  "activeProfile": "live-…",
  "uptimeSec": 2
}
```

## Authentication

When `proxyAuthToken` is set in `config.json`, all upstream routes
(`/v1/models`, `/v1/messages`, `/v1/chat/completions`) require one of:

- `Authorization: Bearer <token>`
- `X-Proxy-Token: <token>`

Health, info, and the npm-launched local browser always stay open.

## Models endpoint

`GET /v1/models` returns the models the active profile's API key can
access. Concretely: the bridge calls `GET https://agentrouter.org/v1/models`
with the active key + spoof headers + persisted WAF cookies, caches the
response in `profiles.json`, and serves it locally. This is the same
mechanism that prevents OpenCode from selecting model names the upstream
rejects with `该令牌无权访问模型`.

## Streaming behaviour

Both `/v1/messages` and `/v1/chat/completions` support SSE. The bridge
pipes the upstream stream through a format-aware pump:

- Anthropic: pass-through verbatim; injects `event: message_delta` +
  `event: message_stop` if the upstream died before sending its own
  terminal events.
- OpenAI: drops empty `data: null` keepalive frames that confuse some
  clients; injects `data: [DONE]` if missing.

The pump enforces a 120-second idle timeout (configurable via
`SSE_IDLE_TIMEOUT_MS` in code) so a stalled upstream cannot keep the
client socket open indefinitely.

## Usage & cost capture

Every proxied request contributes to the in-memory `UsageStore`:

- Tokens (input / output / cache_read / cache_creation) parsed from
  both non-stream responses and accumulated across stream deltas.
- `cost_cny` parsed from Anthropic's non-stream `billing.request.cost_cny.total`.

The aggregate is visible on the TUI Usage & Cost page (page 2) and
persists until the bridge is restarted.
