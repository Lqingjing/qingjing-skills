from xml.etree.ElementTree import Element, SubElement, ElementTree

from fixture_io import save_json, workspace


root, config = workspace()
records = root / "records"
records.mkdir(exist_ok=True)
for number in config["numbers"]:
    path = records / f"{number:03}.json"
    if path.exists():
        continue
    stem = f"Synthetic item {number}"
    evidence = root / f"demo-{number}.xml"
    tree = Element("hierarchy")
    for field, value in {
        "questiondetails_tv_title": config["chapter"],
        "pagenumtv": f"{number}/{config['total']}",
        "titletv": stem,
    }.items():
        SubElement(tree, "node", {"resource-id": f"demo:id/{field}", "text": value})
    ElementTree(tree).write(evidence, encoding="utf-8")
    save_json(path, {
        "number": number,
        "chapter": config["chapter"],
        "stem": [stem],
        "evidence": [evidence.name],
    })
save_json(root / "progress.json", {
    "status": "captured_pending_source_audit",
    "saved": len(config["numbers"]),
})
