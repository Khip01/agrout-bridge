/// Claude Code CLI header fingerprint. The upstream AgentRouter gateway
/// drops requests that lack these, returning `401 unauthorized client detected`
/// even when the chat API key is valid. The spoof owns the Anthropic headers;
/// clients supply only `Authorization` (Bearer) or `x-api-key`.
///
/// Sources of truth:
///   - Live verification on 2026-08-12 with key in this repo's scratch file
///     (`curl -H "User-Agent: claude-cli/2.1.92 ..." /v1/models` returns 200).
///   - Anthropic SDK / Stainless fingerprint for the v2.1.x line of
///     `claude-code`. Bump versions only after re-verifying live; the
///     upstream gate can reject stale fingerprints silently.
library;

/// Headers carried on every Anthropic Messages call (`/v1/messages`).
const Map<String, String> anthropicSpoofHeaders = {
  'Anthropic-Version': '2023-06-01',
  'Anthropic-Beta':
      'claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14,context-management-2025-06-27,prompt-caching-scope-2026-01-05,advanced-tool-use-2025-11-20,effort-2025-11-24,structured-outputs-2025-12-15,fast-mode-2026-02-01,token-efficient-tools-2026-03-28',
  'Anthropic-Dangerous-Direct-Browser-Access': 'true',
};

/// Generic Stainless fingerprint carried on every proxied request,
/// including OpenAI-format chat completions.
const Map<String, String> genericSpoofHeaders = {
  'User-Agent': 'claude-cli/2.1.92 (external, sdk-cli)',
  'X-App': 'cli',
  'X-Stainless-Helper-Method': 'stream',
  'X-Stainless-Retry-Count': '0',
  'X-Stainless-Runtime-Version': 'v24.14.0',
  'X-Stainless-Package-Version': '0.80.0',
  'X-Stainless-Runtime': 'node',
  'X-Stainless-Lang': 'js',
  'X-Stainless-Arch': 'arm64',
  'X-Stainless-Os': 'Linux',
  'X-Stainless-Timeout': '600',
};

/// Full spoof header set sent to `/v1/messages` (Anthropic).
const Map<String, String> anthropicFullSpoofHeaders = {
  ...genericSpoofHeaders,
  ...anthropicSpoofHeaders,
};

/// Browser-like User-Agent used only by the WAF warmup probe. The warmup
/// is a GET `/` with no API key, simulating a real visitor so the edge
/// assigns a fresh `acw_tc` cookie.
const String warmupUserAgent =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

const Map<String, String> warmupHeaders = {
  'User-Agent': warmupUserAgent,
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'en-US,en;q=0.9',
  'Accept-Encoding': 'gzip, deflate, br',
  'Connection': 'keep-alive',
  'Upgrade-Insecure-Requests': '1',
  'Sec-Fetch-Dest': 'document',
  'Sec-Fetch-Mode': 'navigate',
  'Sec-Fetch-Site': 'none',
  'Sec-Fetch-User': '?1',
};
