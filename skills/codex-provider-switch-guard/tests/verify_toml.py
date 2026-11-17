from pathlib import Path
import sys
import tomllib

managed = {
    "model", "model_provider", "preferred_auth_method", "forced_login_method",
    "model_reasoning_effort", "web_search", "model_catalog_json", "model_providers",
}
before, deepseek, restored = (
    tomllib.loads(Path(name).read_text(encoding="utf-8-sig")) for name in sys.argv[1:]
)
assert deepseek["model_provider"] == "deepseek"
assert deepseek["model_providers"]["deepseek"]["env_key"] == "DEEPSEEK_API_KEY"
assert {k: v for k, v in before.items() if k not in managed} == {
    k: v for k, v in deepseek.items() if k not in managed
}
before["features"]["shell_tool"] = True
assert restored == before
