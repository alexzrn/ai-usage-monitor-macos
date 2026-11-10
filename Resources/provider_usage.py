"""Read provider usage using Hermes' existing credentials; never emit credential values."""
import importlib.util
import json
import sys
from pathlib import Path

root = Path.home() / ".hermes" / "hermes-agent"
sys.path.insert(0, str(root))
providers = {}

try:
    plugin = root / "plugins" / "model-providers" / "opencode-zen" / "__init__.py"
    spec = importlib.util.spec_from_file_location("opencode_zen_usage", plugin)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    snapshot = module.opencode_go.fetch_account_usage()
    if snapshot:
        windows = []
        for key, label in (("rolling", "rolling"), ("weekly", "weekly"), ("monthly", "monthly")):
            source_label = {"rolling": "Rolling window", "weekly": "Weekly", "monthly": "Monthly"}[key]
            row = next((w for w in snapshot.windows if w.label == source_label), None)
            if row:
                windows.append({"id": key, "label": label, "percent": float(row.used_percent),
                                "reset_epoch": row.reset_at.timestamp() if row.reset_at else None})
        providers["opencode-go"] = {"ok": bool(windows), "windows": windows}
    else:
        providers["opencode-go"] = {"ok": False, "error": "Нет данных OpenCode Go"}
except Exception as exc:
    status = getattr(getattr(exc, "response", None), "status_code", None)
    if status is not None:
        error = f"OpenCode Go API вернул HTTP {status}"
    else:
        error = "Не удалось связаться с Usage API OpenCode Go"
    providers["opencode-go"] = {"ok": False, "error": error}

try:
    from hermes_cli.runtime_provider import resolve_runtime_provider
    import httpx

    runtime = resolve_runtime_provider(requested="deepseek")
    token = str(runtime.get("api_key") or "").strip()
    if not token:
        providers["deepseek"] = {"ok": False, "error": "Ключ DeepSeek не настроен в Hermes"}
    else:
        response = httpx.get("https://api.deepseek.com/user/balance",
                             headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
                             timeout=10.0)
        response.raise_for_status()
        body = response.json() or {}
        providers["deepseek"] = {
            "ok": True,
            "available": bool(body.get("is_available")),
            "balances": [{
                "currency": row.get("currency", "USD"),
                "total": row.get("total_balance"),
                "granted": row.get("granted_balance"),
                "topped_up": row.get("topped_up_balance"),
            } for row in body.get("balance_infos", [])],
        }
except Exception:
    providers["deepseek"] = {"ok": False, "error": "Не удалось получить баланс DeepSeek"}

print(json.dumps({"providers": providers}, ensure_ascii=False))
