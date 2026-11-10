# OpenCode Desk

Небольшая панель на рабочем столе macOS с отдельными вкладками Codex и Hermes.

## Запуск

```sh
./build.sh
open "build/OpenCode Desk.app"
```

Нужен установленный `opencode` в `/Users/alex/.local/bin`, `/opt/homebrew/bin` или `/usr/local/bin`. Приложение вызывает только локальный CLI/API и не запускает отдельный сервер.

## Прототип

- Панель закреплена над рабочим столом и под окнами приложений.
- Codex: окна лимитов 5 часов и недели читаются из последнего локального Codex `token_count`; последние чаты — из локальной базы Codex.
- Hermes: квоты OpenCode Go (rolling, weekly, monthly) читаются через provider hook Hermes и OpenCode Go usage endpoint.
- Интервал обновления 30 секунд; настройка 15/30/60/120 секунд в контекстном меню.
- Перетащи панель мышью; правый клик открывает настройки и обновление.

Сессии Codex остаются локальными. Для Hermes выполняется read-only запрос квот OpenCode Go с API-ключом, который Hermes сам выбирает из своего credential pool; ключ не выводится и не сохраняется приложением.
