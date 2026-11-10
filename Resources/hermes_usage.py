"""Read OpenCode Go usage through the same provider hook Hermes uses."""
import importlib.util
import json
import sys
from pathlib import Path

home = Path.home()
root = home / ".hermes" / "hermes-agent"
sys.path.insert(0, str(root))
plugin = root / "plugins" / "model-providers" / "opencode-zen" / "__init__.py"
spec = importlib.util.spec_from_file_location("opencode_zen_usage", plugin)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
snapshot = module.opencode_go.fetch_account_usage()
if snapshot is None:
    print(json.dumps({"ok": False}))
else:
    print(json.dumps({
        "ok": True,
        "windows": [{
            "id": key,
            "label": label,
            "percent": float(window.used_percent),
            "reset_epoch": window.reset_at.timestamp() if window.reset_at else None,
        } for key, label, window in [
            ("rolling", "ROLLING", next((w for w in snapshot.windows if w.label == "Rolling window"), None)),
            ("weekly", "WEEKLY", next((w for w in snapshot.windows if w.label == "Weekly"), None)),
            ("monthly", "MONTHLY", next((w for w in snapshot.windows if w.label == "Monthly"), None)),
        ] if window is not None],
    }))
