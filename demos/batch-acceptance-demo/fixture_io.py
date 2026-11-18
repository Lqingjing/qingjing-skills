import json
import os
from pathlib import Path


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def save_json(path, content):
    path.write_text(json.dumps(content, indent=2) + "\n", encoding="utf-8")


def workspace():
    config = Path(os.environ["BATCH_CONFIG"])
    return config.parent.parent, read_json(config)
