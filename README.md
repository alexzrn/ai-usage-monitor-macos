# AI Usage Monitor for macOS

Desktop panel for recent sessions and provider usage from local AI coding agents. The v0.1 client is a native macOS app. Its session and provider adapters are kept separate from the view so additional agents can be added without changing the app model.

![AI Usage Monitor](docs/screenshots/overview.png)

The screenshot uses sample session names and sample limit values. It contains no account data.

## Supported sources

| Source | Automatic discovery | Data shown | Session link |
| --- | --- | --- | --- |
| Codex | CLI in common install paths or `PATH`; newest `~/.codex/state_*.sqlite` | Recent threads; 5-hour and weekly limits from local rollout events | `codex resume <thread-id>` in Terminal |
| Hermes | CLI and `~/.hermes/state.db` | Recent sessions grouped by `billing_provider` | `hermes --resume <session-id> chat` in Terminal |
| OpenCode | CLI in common install paths or `PATH`; its local API | Recent sessions, model, provider, token counts, and cost when provided | Opens `opencode --session <id>` in the project directory |
| OpenClaw | CLI in common install paths or `PATH` | `sessions --all-agents --json`; provider quota snapshots from `status --usage --json` | Opens `openclaw tui <session-key>` |
| DeepSeek | Hermes provider credentials | Official API balance plus session-derived token and cost totals | Shows matching sessions from detected agents |
| OpenCode Go | Hermes provider credentials and usage adapter | Provider-reported rolling, weekly, and monthly limits | Shows matching Hermes/OpenCode sessions |

Sessions remain visible when their provider has no usage adapter. Such cards show an unavailable status instead of inventing a quota. The OpenClaw adapter follows the documented [sessions JSON](https://docs.openclaw.ai/cli/sessions), [usage JSON](https://docs.openclaw.ai/cli/status), and [TUI session target](https://docs.openclaw.ai/cli/tui) interfaces. OpenClaw is not installed on the machine used to capture the current preview, so that adapter has not been exercised against a live local installation.

## Install from source

Requirements: macOS 14 or later and Xcode Command Line Tools. Provider CLIs are optional; only installed sources appear with data.

```sh
git clone https://github.com/alexzrn/ai-usage-monitor-macos.git
cd ai-usage-monitor-macos
./build.sh
open "build/AI Usage Monitor.app"
```

The app uses SwiftUI and AppKit. It refreshes every 30 seconds by default. Right-click the panel to refresh, choose 15/30/60/120-second intervals, or quit. Session rows open the corresponding local CLI in Terminal; selecting a row does not send a prompt.

## Language

The interface follows the macOS preferred language. English and Russian strings are included. If the preferred language is not included, macOS uses English.

## Discovery and extension

`Resources/registry.json` defines app tabs and known provider relationships. Collectors inspect only documented local stores and installed CLIs. Provider IDs found in session metadata are added to that app's tab automatically. New agents need a session collector; new provider quota sources need a usage adapter. See [`docs/architecture/platforms.md`](docs/architecture/platforms.md) for the platform scope and expansion path.

The current release targets macOS only and is named accordingly. Windows and Linux need their own desktop shell and local-source adapters. Linux DE support will require separate integration choices (for example, a KDE Plasma widget or GNOME Shell extension); the macOS SwiftUI panel cannot run there.

## Privacy and limitations

- Session titles, project paths, models, token counts, and costs are read locally.
- DeepSeek balance requests go directly from this Mac to the DeepSeek API. The key is resolved from Hermes and is neither displayed nor saved by this app.
- The app sends no telemetry.
- Some providers expose only quota windows or balances, not complete historical spend. Session-derived totals are labeled separately from provider-reported values.
- A public source repository is provided without an open-source license.

## Русский

Нативная панель macOS для сессий локальных coding-агентов и Usage их провайдеров. Первая версия автоматически обнаруживает Codex, Hermes, OpenCode и OpenClaw по локальным CLI и базам. Провайдеры определяются по метаданным сессий. DeepSeek подключается через credentials Hermes.

Сборка: macOS 14+, Xcode Command Line Tools, затем `./build.sh`. Приложение обновляет данные раз в 30 секунд; интервал можно изменить в контекстном меню. Нажатие на сессию открывает соответствующий CLI с её ID или ключом и не отправляет запрос модели.

Язык интерфейса выбирается по системному языку macOS. В комплект входят английский и русский; для остальных языков используется английский. Текущий выпуск поддерживает только macOS. Для Windows и Linux понадобятся отдельные оболочки и адаптеры системных источников; Linux-интеграция будет учитывать выбранную DE.

Скриншот демонстрационный: названия сессий и лимиты вымышлены. Баланс, API-ключи и личная история в репозиторий не включены.
