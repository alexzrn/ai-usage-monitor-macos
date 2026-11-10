# AI Usage Monitor

Native macOS desktop monitor for local coding agents and their model providers. It combines recent sessions and provider usage in a compact, translucent panel.

![AI Usage Monitor on macOS](docs/screenshots/overview.png)

The screenshot uses sample session labels and sample usage values; it contains no account data.

## Features

- App tabs for Codex, Hermes, OpenCode, and provider-wide DeepSeek activity.
- Provider cards pair usage with the latest sessions routed through that provider.
- Automatic provider discovery from Hermes and OpenCode session metadata.
- DeepSeek balance from the official API, using credentials already configured in Hermes.
- Session rows open the matching CLI session in Terminal when the CLI supports resuming by ID.
- Refresh every 30 seconds by default; 15, 30, 60, and 120 second intervals are available from the panel context menu.
- The panel starts at the lower-left of the main display.

## Build and run

Requirements: macOS 14 or later, Xcode Command Line Tools, and the local apps or CLIs you want to monitor.

```sh
./build.sh
open "build/AI Usage Monitor.app"
```

The app is built with Swift and SwiftUI; it has no third-party runtime dependencies. To quit, use the panel context menu or the app menu.

## Data sources and session actions

| App or provider | Discovery and usage | Session action |
| --- | --- | --- |
| Codex | Reads the newest `~/.codex/state_*.sqlite` database and local rollout events for rate limits. | `codex resume <session-id>` in Terminal. |
| Hermes | Reads `~/.hermes/state.db`; groups sessions by `billing_provider`. | `hermes --resume <session-id> chat` in Terminal. |
| OpenCode | Uses the installed `opencode` CLI to read local API sessions and provider/model metadata. | Opens `opencode --session <session-id>` in the session's project directory. |
| OpenCode Go | Reuses the Hermes OpenCode Zen account usage integration and existing credential pool. | Recent Hermes/OpenCode sessions using this provider. |
| DeepSeek | Calls `GET https://api.deepseek.com/user/balance` with the key resolved from Hermes credentials. Session token and cost totals are calculated from local records. | The DeepSeek tab combines recent DeepSeek sessions across detected apps. |

If an app or provider is unavailable, its card remains visible with an explicit status. Session metadata that identifies an unknown provider is still shown; provider usage requires a usage adapter. A standalone DeepSeek CLI is not required.

## Extending discovery

`Resources/registry.json` declares app tabs, provider relationships, and adapter names. Add an app adapter to read another local session store, or a provider usage adapter to expose that provider's usage. Session-derived providers are added to the app view automatically. Credentials should be resolved from the source app's existing credential store and must never be copied into this app's config or logs.

This adapter boundary is intended to support additional local agents such as OpenClaw without coupling the UI to one provider or agent.

## Privacy

Session titles, project paths, token counts, costs, and account balances are read locally. DeepSeek balance requests go directly from this Mac to the DeepSeek API. Credentials are obtained through Hermes and are not rendered, persisted by this app, or included in the helper's JSON output. The app does not upload telemetry.

The frozen first prototype is preserved in [`prototype-v1/`](prototype-v1/).

---

## Русский

Нативный монитор для macOS: вкладки локальных coding-агентов, карточки провайдеров, их Usage и недавние сессии. Вкладка DeepSeek показывает официальный баланс и сессии DeepSeek из доступных приложений.

Собрать и запустить:

```sh
./build.sh
open "build/AI Usage Monitor.app"
```

По умолчанию панель обновляется раз в 30 секунд и располагается внизу слева. Доступны интервалы 15, 30, 60 и 120 секунд. Нажатие на сессию открывает её через соответствующий CLI в Terminal, если источник поддерживает восстановление по ID. Codex, Hermes и OpenCode определяются по локальным CLI и базам данных; провайдеры из сессий обнаруживаются автоматически. Для OpenClaw и других агентов добавляются адаптеры чтения их локальных данных.

Скриншот содержит демонстрационные названия сессий. Реальные названия, пути проектов, Usage и баланс читаются с локального Mac. Баланс DeepSeek запрашивается с официального API, ключ берётся из настроек Hermes и не сохраняется приложением.
