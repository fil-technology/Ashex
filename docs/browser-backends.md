# Browser Backends

Ashex now supports an optional browser automation layer for rendered-page fetches, DOM inspection, screenshots, and lightweight local web research.

## What It Is

- A pluggable browser backend system inside `AshexCore`
- Optional experimental support for an Obscura-style CDP server
- Chrome/Chromium-compatible CDP fallback support
- Agent tools: `browser_fetch`, `browser_extract`, `browser_eval`, `browser_screenshot`
- CLI commands under `ashex browser ...`

This feature is additive. Ashex still builds and runs without Obscura installed.

## Why Obscura Is Experimental

Obscura is treated as an optional local backend, not a hard dependency:

- command-line flags can vary by installed build
- custom extraction methods such as `LP.getMarkdown()` may not exist
- startup behavior and `/json` endpoints may differ between versions

Ashex probes `obscura --help` when available and only adds supported flags.

## Supported Backends

- `auto`: prefer Obscura if available, otherwise use Chrome CDP
- `obscura`: launch `obscura serve` locally and connect over CDP
- `chrome-cdp`: connect to an existing Chrome/Chromium-compatible CDP endpoint

## Security Defaults

Browser navigation is intentionally conservative by default:

- binds Obscura to `127.0.0.1`
- blocks `file://` navigation
- blocks `localhost` navigation
- blocks private-network navigation

Enable local/private targets only when you explicitly need them:

```json
{
  "browser": {
    "security": {
      "allowFileUrls": true,
      "allowLocalhostNavigation": true,
      "allowPrivateNetworkNavigation": true
    }
  }
}
```

## Config Keys

```json
{
  "browser": {
    "backend": "auto",
    "startupTimeoutSeconds": 10,
    "navigationTimeoutSeconds": 30,
    "headless": true,
    "stealthEnabled": false,
    "blockTrackers": true,
    "extraArgs": [],
    "environment": {},
    "obscura": {
      "path": "",
      "host": "127.0.0.1",
      "port": 0,
      "stealth": false,
      "blockTrackers": true
    },
    "security": {
      "allowFileUrls": false,
      "allowLocalhostNavigation": false,
      "allowPrivateNetworkNavigation": false
    },
    "cdp": {
      "endpoint": ""
    }
  }
}
```

## CLI Examples

```bash
ashex browser doctor

ashex config set browser.backend obscura
ashex config set browser.obscura.path /usr/local/bin/obscura

ashex browser fetch https://example.com --markdown
ashex browser fetch https://example.com --text --json

ashex browser eval https://example.com "document.title"

ashex browser screenshot https://example.com --output example.png

ashex browser benchmark https://example.com --backend obscura --json
```

## Fallback Behavior

- If Obscura is unavailable, `auto` falls back to `chrome-cdp`
- If custom markdown extraction is unavailable, Ashex falls back to DOM-based markdown-ish extraction, then text extraction
- If no CDP endpoint is reachable, `browser doctor` reports the failure clearly

## Troubleshooting

- `Obscura binary not found`: set `browser.obscura.path` or add `obscura` to `PATH`
- `Timed out waiting for browser backend`: increase `browser.startupTimeoutSeconds`
- `localhost/private network blocked`: enable the matching `browser.security.*` key explicitly
- `No page target available`: verify the CDP server exposes `/json` and page targets

## Notes

- This browser layer is for local automation, rendered research, DOM extraction, screenshots, and testing.
- It should not be used for credential theft, bypassing access controls, or abusive scraping.
