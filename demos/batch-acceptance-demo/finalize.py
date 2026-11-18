from fixture_io import read_json, save_json, workspace


root, config = workspace()
missing = [
    n for n in config["numbers"]
    if not (root / "records" / f"{n:03}.json").is_file()
]
coverage = {
    "questions": config["total"] - len(missing),
    "missing_numbers": missing,
    "source_mismatches": [],
    "pending": [],
    "target_comments_saved": 0,
    "media_visual_pending": [],
}
override = root / "coverage-fixture.json"
if override.exists():
    coverage.update(read_json(override))
save_json(root / "coverage.json", coverage)
if (root / "simulate-finalize-failure").exists():
    raise SystemExit(1)
