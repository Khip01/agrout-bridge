# hcnsec.cn endpoint exploration (WIP)

Branch: `explore/hcnsec-endpoint`. All findings are public/provider info; no
secrets stored here.

## Provider

- Base: `https://api.hcnsec.cn` (New API fork; frontend is the standard New
  API SPA). Alternate host: `https://hcnote.cn` responds 200.
- OpenAI-compatible (`/v1/chat/completions`, `/v1/models`, `/v1/messages`
  Anthropic-compatible also works) plus Gemini/image/audio endpoints on the
  same gateway (`supported_endpoint_types`).

## Auth / daily claim (KEY FINDING)

- `checkin_enabled: true` in `/api/status`.
- Login is **username/password** (or email), NOT OAuth: `github_oauth`,
  `linuxdo_oauth`, `discord_oauth`, `telegram_oauth`, `wechat_login` are all
  false; `password_login_enabled: true`, `register_enabled: true`. No
  Turnstile/PoW in the frontend bundle.
- Daily check-in flow (proven by public repo `tj5332888/hcnsec-checkin`):
  1. `POST /api/user/login` with `{"username","password"}` -> session cookie.
  2. `POST /api/user/checkin` with `{}` + cookie -> reward.
  - "Check-in successful! Received" + reward amount exists in the frontend
    i18n (`Check-in successful! Received`).
- `/api/user/checkin`, `/api/user/self`, `/api/log/self`, `/api/option` all
  require a **session cookie**; the chat API key (`sk-`) alone is rejected
  (`Unauthorized, invalid access token`).
- This is simpler than AgentRouter: no GitHub OAuth authorize-URL trick. A
  username/password login can feed the daily-claim dialog directly.

## Models (probed, 2026-08-18, sk- key)

Stable:
- `auto` -> routes to a healthy channel (echoed `agnes-2.5-flash`), works on
  both `/v1/chat/completions` and `/v1/messages` (Anthropic path returns real
  `cache_read_input_tokens`, `billing_usage.source: oai_chat`).

Unstable (timeout / SSL 525 / 522 / CPU overload at the time of probing):
- `DeepSeek-V4-Flash`, `DeepSeek-V4-Pro`, `glm-5.2`, `kat-coder-pro-v2.5`,
  `Kimi-K2.6`, `MiniMax-M3`, `Qwen3.6-27B`, `Qwen3.8-27B`,
  `sensenova-6.7-flash-lite`, `sensenova-u1-fast`, `step-3.7-flash`,
  `step-explore`, `step-router-v1`.

Notes:
- Echo `model` in responses can differ from the requested id (server-side
  routing; e.g. `Qwen3.8-27B` request echoed `meta/muse-glimmer-30b`).
- `/v1/models` `data[].supported_endpoint_types` is per-model.
- Responses include large `reasoning_content` (DeepSeek-style) on some
  models; the bridge already strips/translates this for AgentRouter.

## Billing

- `/v1/dashboard/billing/subscription`: `soft_limit_usd` /
  `hard_limit_usd` = `100000000` sentinel (same as AgentRouter) -> not a
  usable daily-claim delta sensor.
- `/v1/dashboard/billing/usage`: `total_usage` is flat/static across date
  ranges (same as AgentRouter) -> not reliable; not surfaced in TUI.

## Questions still open

1. Does `/api/user/self` expose `checkin_today` / quota fields for a
   reliable "already claimed" sensor? (needs a real session; no creds yet)
2. Daily reward amount (frontend string exists; amount itself needs a live
   session).
3. Which models are actually stable long-term (provider is load-sensitive).
4. GitHub Action-based checkin exists (`tj5332888/hcnsec-checkin`:
   `signin.yml` cron daily + `signin.py`), and a general New API multi-site
   tool `lengxii/new-api-checkin` (HTTP / CDP / Camoufox, PoW+Turnstile
   fallbacks for sites that require them; hcnsec does not).
