# QuotAI

A small, always-on-top macOS menu-bar app that shows how much of your AI quotas you have used — Claude, Codex, OpenAI — before you hit a wall mid-task.

QuotAI only uses **official, documented** data sources. It never asks for your account password, browser cookies or a session token, never scrapes a website, and never bypasses a protection. When a provider exposes no official way to read a quota, QuotAI says **"Not available via an official API"** and offers a link to the provider's page or an optional manual entry (always labelled "Entered by you").

## Download

Grab the latest `QuotAI.dmg` from the [Releases](../../releases) page, open it, and drag **QuotAI** into **Applications**.

- macOS 14 (Sonoma) or later.
- Universal binary — compiled natively for both **Apple Silicon and Intel**, no Rosetta needed on either.
- Free and open source.

> **First launch:** this build is ad-hoc signed, not notarized with a Developer ID, so Gatekeeper will refuse a normal double-click the first time. Right-click (or Control-click) **QuotAI.app** and choose **Open** instead, then confirm once — only needed the first time.

QuotAI is a menu-bar app (no Dock icon). On first launch it opens *Settings* and shows the floating panel.

## Features

- **Always-in-view panel** — a small floating card, draggable anywhere on screen by clicking and holding anywhere on it, that sits above your other windows without stealing focus. Resizes itself as you enable or disable providers; position and size are remembered.
- **Two display modes** — **Normal** (full gauge + reset time per provider) or **Mini** (just the name and the percentage), switchable anytime from the right-click menu or Settings.
- **Every provider in one place** — Claude (Pro/Max), Claude API (Console), Codex (ChatGPT subscription), OpenAI API (platform) — each identified by its own vendor logo.
- **One click to the full picture** — a Details window with every metric a provider exposes, exactly when it resets, and whether a number is official data or something you typed in yourself.
- **Make it yours** — your own orange/red warning thresholds, reorder providers by drag and drop, launch at login, keep the panel always on top, dial in its opacity. Light and dark modes follow the system.
- **Nothing but official data, nothing but the Keychain** — see *Security and privacy* below.

## What is actually available (verified 2026-09-24)

| Connector | What QuotAI can show | How | Limits |
|---|---|---|---|
| **Claude (Pro/Max subscription)** | % of the 5-hour session limit, % of the weekly limit, reset times | Claude Code's documented `statusLine` JSON (`rate_limits.five_hour`, `rate_limits.seven_day`). A tiny helper script copies it to a local file that QuotAI reads. No credentials. | Only for Pro/Max subscribers, only after the first response of a Claude Code session, and only refreshed while Claude Code runs. There is **no HTTP API** for subscription usage. |
| **Claude API (Console)** | Month-to-date cost (USD) and tokens | Admin API: `GET /v1/organizations/cost_report`, `GET /v1/organizations/usage_report/messages`. Needs an Admin key (`sk-ant-admin01-…`). | Organizations only (unavailable for individual accounts). Data can lag ~5 minutes. Does **not** cover the Claude subscription. |
| **OpenAI API (platform)** | Month-to-date cost (USD), tokens and requests | `GET /v1/organization/costs`, `GET /v1/organization/usage/completions`. Needs an Admin API key. | Token/request figures cover the *completions* endpoint only (cost covers all services). Does **not** cover ChatGPT/Codex. |
| **Codex (ChatGPT subscription)** | % of the current usage window, % of the secondary (typically weekly) window, any extra per-model reserve (e.g. `/status`'s "Luna Reserve"), credit balance, reset times | No *published* API exposes this, but the `codex` CLI itself does, internally: QuotAI briefly runs `codex app-server` and calls its `account/rateLimits/read` JSON-RPC method over stdio — the same source `/status` uses. Uses your existing `codex login` session; QuotAI never touches its credentials. | This protocol has no public documentation page; its shape was captured from the installed CLI (`codex app-server generate-json-schema`) and confirmed with a live call (see *Verifying the Codex connector* below). It may change without notice on a codex CLI update — QuotAI then falls back to manual entry automatically. Requires the `codex` CLI installed and signed in. |

**Percentages for API providers** are computed by QuotAI as *month-to-date cost ÷ the monthly budget you enter*, because no provider API returns your spending cap. Such values are labelled "Computed from your budget".

**Not implemented:** Gemini. Investigated at length (public API headers, the `gemini` CLI's local state, its ACP protocol, Google's Cloud Quotas API) — none exposes real usage, only static configured limits at best, and the one place that does show real usage (the AI Studio web dashboard) is reachable only by replaying a browser session, which this project's rules explicitly rule out. Removed rather than kept as a connector that could never do more than manual entry.

Each connector's exact sources and verification date are shown in *Settings → Connections → What is officially available*, and live in `QuotAI/Core/Models/ProviderKind.swift`.

## Using QuotAI

- **Panel:** an always-on-top, non-activating window (it does not steal focus), drawn as a self-contained opaque card (rounded corners, soft shadow, optional thin border) rather than a translucent system-material sheet. It's a free-form rectangle, not forced square — it grows and shrinks its height on its own as you enable or disable providers, never its width. If a saved screen is unplugged, the panel moves back onto a visible one. Right-click for the menu (which also has **Quit QuotAI**, next to the menu bar's own).
  - Progress shows as tick-mark segments rather than one smooth fill.
  - When a handful of rows leave extra room, the gaps between them (each holding a thin divider) grow to use the panel's canvas instead of leaving a dead block above the footer; once there are too many rows to fit, it switches to a scrollable list automatically.
  - Rows highlight and show a pointing-hand cursor on hover; the refresh icon only spins while a refresh is running, and skips the spin animation entirely if you have "Reduce Motion" enabled in System Settings → Accessibility.
  - **Click a row to see only that provider's details** — not everyone else's too. Use **← All Connections** at the top of that view to go back to the full list.
- **Menu bar icon:** provider summaries, *Show/Hide Panel*, *Refresh Now* (⌘R), *Details…* (⌘D, opens the full list), *Settings…* (⌘,), *Keep on Top*, *Quit*.
- **Settings** is a sidebar-based preferences window (General / Connections), each section and each provider identified by its own icon or logo:
  - **Connections:** add, edit and delete connections (the "+" menu offers each provider kind); enable/disable each one; save/replace/remove its key; enter an optional budget or manual values; choose the main value and the refresh interval; **drag to reorder** — the same order shows in the panel and in Details; **Test Connection**; see the required permissions and what is officially available.
  - **General → Panel:** keep on top, show at launch, add a border to the main window, mini mode, opacity, reset panel position.
  - **General → Status colors:** the orange and red percentage thresholds the panel and Details use.
  - **General → Shown in the compact view:** reset time, remaining quota, last update time.
  - **General → System:** open at login (optional, uses the system login items).

## Configuring each provider

### Claude (Pro/Max subscription)
1. *Settings → Connections → Claude*, click **Install Helper Script**. It writes `~/Library/Application Support/QuotAI/quotai-claude-statusline.sh`.
2. Paste the shown snippet into `~/.claude/settings.json` (QuotAI never edits that file):
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "'/Users/you/Library/Application Support/QuotAI/quotai-claude-statusline.sh'"
     }
   }
   ```
3. Use Claude Code. After the first response of a session, the limits appear in QuotAI.

*Already have a statusLine command?* Chain them so both receive Claude Code's JSON:
```sh
#!/bin/sh
input=$(cat)
printf '%s' "$input" | '/Users/you/Library/Application Support/QuotAI/quotai-claude-statusline.sh'
printf '%s' "$input" | /path/to/your-existing-statusline-script
```
The helper prints nothing and writes the JSON atomically with owner-only permissions (`0600`).

### Claude API and OpenAI API
Create an **Admin key** in the provider's console (Anthropic: an Admin API key `sk-ant-admin01-…` from the Claude Console; OpenAI: an organization Admin API key from the platform settings), paste it in QuotAI, and click **Save Key in Keychain**. Optionally enter a monthly budget to get a percentage. Use **Test Connection** to verify. Anthropic workspace keys do not work, and Anthropic's Admin API is unavailable to individual accounts (an organization is required).

### Codex
Nothing to configure: install the `codex` CLI and run `codex login` in a terminal. QuotAI looks for the binary on your `PATH` and in common install locations (Homebrew, npm, `~/.local/bin`, …); *Settings → Connections → Codex* shows whether it was found. If the CLI is missing, not logged in, or its protocol ever changes on an update, QuotAI falls back to whatever you type into the optional manual-entry fields, labelled "Entered by you".

#### Verifying the Codex connector
`account/rateLimits/read` is not documented on a public OpenAI page. To confirm it yourself against your own installed CLI (read-only, no network call, does not touch your account):
```sh
mkdir -p /tmp/codex-schema-check
codex app-server generate-json-schema --out /tmp/codex-schema-check
cat /tmp/codex-schema-check/v2/GetAccountRateLimitsResponse.json
rm -rf /tmp/codex-schema-check
```
This generates the CLI's own protocol schema from the binary you have installed. If a future `codex` version renames or removes this method, QuotAI's connector will fail informatively (falling back to manual entry) rather than silently showing wrong numbers — see `Core/Providers/CodexAppServerConnector.swift`.

## Security and privacy

- Secrets (API/Admin keys) live **only in the macOS Keychain** (generic password, *when unlocked, this device only*, not synced). A saved key is never displayed again.
- Preferences (`UserDefaults`), connections (`connections.json`) and the snapshot cache (`snapshot-cache.json`, in `~/Library/Application Support/QuotAI`) contain no secrets; a unit test enforces this.
- Keys are sent in request headers only, never in URLs. Error messages are generic (no response bodies), and all logging goes through a redactor that masks key-like strings.
- Network access is limited to the provider hosts above. No third-party server, no analytics.
- The app is **not sandboxed** so that Claude Code's helper script (a separate process) can write to `~/Library/Application Support/QuotAI`, and so QuotAI can spawn `codex app-server` for the Codex connector. Hardened Runtime is enabled and no special entitlement is requested. macOS permissions used: outbound network, spawning the `codex` CLI as a subprocess (stdio only, no shared filesystem or IPC access beyond that); "open at login" is opt-in.
- The Codex connector never reads `codex`'s own credential file (`~/.codex/auth.json`) or any other of its local state; it only exchanges JSON-RPC messages with the `codex app-server` subprocess over stdio and terminates it after each refresh.

## Building from source

- Xcode (developed and tested with Xcode 27, Swift 5 language mode).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to regenerate `QuotAI.xcodeproj` from `project.yml`. The generated project is included, so this is only needed after changing `project.yml` or adding files.

```sh
# (Optional) regenerate the Xcode project
xcodegen generate

# Build
xcodebuild -project QuotAI.xcodeproj -scheme QuotAI -configuration Debug -destination 'platform=macOS' build

# Run the unit tests
xcodebuild -project QuotAI.xcodeproj -scheme QuotAI -destination 'platform=macOS' test

# Release build (universal)
xcodebuild -project QuotAI.xcodeproj -scheme QuotAI -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build ONLY_ACTIVE_ARCH=NO build
open build/Build/Products/Release/QuotAI.app
```

Or open `QuotAI.xcodeproj` in Xcode and press Run.

> **Keychain prompts while developing.** Debug/Release builds are ad-hoc signed, so their code identity changes on every rebuild and macOS may ask again whether QuotAI can access its own Keychain items. A stable Developer ID signature (see *Distribution*) avoids this.

## Architecture

```
QuotAI/
  App/          QuotAIApp (MenuBarExtra), AppEnvironment (windows, wiring)
  Assets.xcassets/
    AppIcon.appiconset/   App icon (all required sizes + Contents.json)
    ClaudeLogo.imageset/  Claude's own mark (not Anthropic's) — template-rendered SVG, from Simple Icons
    OpenAILogo.imageset/  OpenAI's mark — template-rendered SVG, from Simple Icons
  Core/
    Models/     ProviderKind + ProviderDescriptor (capabilities, sources, dates), Connection,
                UsageSnapshot/Metric, ProviderError, ConnectionState, UsageMath
    Providers/  UsageConnector protocol + one independent connector per provider, including
                the Codex CLI locator and its local JSON-RPC session (app-server, over stdio)
    Networking/ HTTPClient (URLSession, ephemeral, timeouts) with status → error mapping
    Security/   SecretStore (Keychain), Redactor + AppLog
    Storage/    Connection repository, snapshot cache, AppSettings
    Refresh/    UsageStore: per-connection refresh, backoff, throttling, timeouts, cache
  UI/           Panel (NSPanel + SwiftUI), Details, Settings (sidebar + shared card components), MenuBar
QuotAITests/    81 unit tests
```

- **Independence:** every connection refreshes in its own task; one failing or slow provider never blocks the others.
- **Respecting API limits:** each provider has a minimum refresh interval (60 s for the Admin APIs; Anthropic documents 1 request/minute for sustained polling); manual refresh is throttled by it; `retry-after` is honoured; network errors back off exponentially (capped at 30 min); rejected keys (401/403) are not retried until you change something.
- **Cache and timeouts:** the last good snapshot is cached locally and shown (flagged "Outdated") when a refresh fails; each fetch has a 45 s overall timeout and a 15 s request timeout.

### Adding a provider
1. Add a case to `ProviderKind` and a `ProviderDescriptor` (auth method, permissions, capabilities, **official sources and verification date**).
2. Implement `UsageConnector.fetch(_:) -> UsageSnapshot` in `Core/Providers/`, throwing only `ProviderError`.
3. Register it in `ConnectorFactory.make`, and add tests with `StubHTTPClient`.

## Known limitations
- No *published* quota API for the Codex subscription; QuotAI instead uses the CLI's own internal, undocumented protocol (see above). Claude subscription data requires Claude Code and its helper script.
- Anthropic Admin API is organization-only; OpenAI needs an Admin key. Cost/usage data can lag by minutes.
- Budgets and manual values are yours, not the provider's; they are labelled accordingly.
- The menu bar uses an SF Symbol rather than a custom glyph.
- Interface language: English only.
- The Claude, OpenAI and Anthropic connectors were verified against their documented schemas with tests, not live accounts (no credentials were available for those during development) — a first **Test Connection** with real keys is recommended. The Codex connector *was* verified live, against a real, currently-authenticated `codex` CLI session.

## Distribution

1. Set your Apple Developer team and a Developer ID Application identity (`DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY="Developer ID Application"`), keep Hardened Runtime on.
2. Archive and export:
   ```sh
   xcodebuild -project QuotAI.xcodeproj -scheme QuotAI -configuration Release \
     -destination 'generic/platform=macOS' -archivePath build/QuotAI.xcarchive archive
   ```
3. Zip or wrap in a DMG, then notarize and staple:
   ```sh
   ditto -c -k --keepParent QuotAI.app QuotAI.zip
   xcrun notarytool submit QuotAI.zip --keychain-profile "<profile>" --wait
   xcrun stapler staple QuotAI.app
   ```
4. Distribute outside the Mac App Store (the app is intentionally not sandboxed; see *Security*).

## Sources (checked 2026-09-24)
- Claude Code status line: https://code.claude.com/docs/en/statusline
- Claude Usage & Cost API: https://platform.claude.com/docs/en/manage-claude/usage-cost-api
- Claude Rate limits (headers, Rate Limits API): https://platform.claude.com/docs/en/api/rate-limits
- OpenAI Usage/Costs (cookbook): https://developers.openai.com/cookbook/examples/completions_usage_api
- Codex with a ChatGPT plan: https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan
