import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from fixture_io import read_json, save_json


PACKAGE = Path(__file__).resolve().parent


def main():
    with tempfile.TemporaryDirectory(prefix="batch-demo-", dir=os.environ.get("BATCH_DEMO_TMP")) as folder:
        root = Path(folder)
        tools = root / "tools"
        tools.mkdir()
        for name in ("bulk.py", "finalize.py", "fixture_io.py"):
            shutil.copyfile(PACKAGE / name, tools / name)
        shutil.copyfile(PACKAGE / "batch-config.example.json", tools / "batch-config.json")

        def run(expected):
            result = subprocess.run([
                "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(PACKAGE / "run_batch.ps1"), "-ChapterDir", str(root),
            ], text=True, capture_output=True, timeout=30)
            if result.returncode != expected:
                raise AssertionError(result.stdout + result.stderr)
            return read_json(root / "batch_attempt.json")

        acceptance = root / "batch_result.json"
        assert run(0)["next_action"] == "archive"
        print("PASS: fresh batch with nonconsecutive numbers")

        override = root / "coverage-fixture.json"
        save_json(override, {
            "pending": [{"number": 3, "issues": ["comment_2_media_pending"]}],
            "media_visual_pending": None,
        })
        result = run(0)
        assert result["status"] == "complete_with_pending"
        assert result["media_visual_status"] == "unknown"
        assert result["pending_issue_count"] == 1
        print("PASS: pending content and unknown visual state")

        previous = acceptance.read_bytes()
        snapshot = Path(read_json(acceptance)["coverage"])
        evidence = snapshot.read_bytes()
        save_json(override, {"questions": 0})
        (root / "simulate-finalize-failure").touch()
        assert run(4)["status"] == "failed"
        assert acceptance.read_bytes() == previous
        assert snapshot.read_bytes() == evidence
        assert (root / "coverage.json").read_bytes() != evidence
        print("PASS: failed rerun preserves accepted result and coverage")

        (root / "demo-3.xml").unlink()
        result = run(6)
        assert result["identity_issues"][0]["number"] == 3
        assert acceptance.read_bytes() == previous
        print("PASS: full count with missing source evidence blocks acceptance")


if __name__ == "__main__":
    main()
