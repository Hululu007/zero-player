"""Build the Smart Education textbook index from the official public metadata."""

import argparse
import gzip
import json
from pathlib import Path
import re
from urllib.parse import urlsplit


PART = re.compile(r"/zxx_secondary/ndrs/resources/tch_material/(part_[0-9]+\.json)")
BOOK_ID = re.compile(r"[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}")
CDN = {f"bdcs-file-{number}.ykt.cbern.com.cn" for number in (1, 2)}
BOOK_TYPES = {"assets_document", "thematic_course"}
TAGS = {"zxxbb", "zxxcc", "zxxnj", "zxxxd", "zxxxk"}


def publications(rows):
    for row in rows:
        identifier = row.get("id", "")
        kind = row.get("resource_type_code")
        labels = row.get("tag_list") or []
        title = " ".join(row.get("title", "").split())
        published = any(tag.get("tag_name") == "电子教材" for tag in labels)
        if (row.get("status") != "ONLINE" or row.get("teachmeterial_ids") or not published
            or kind not in BOOK_TYPES or not BOOK_ID.fullmatch(identifier) or not title):
            continue
        entry = {"id": identifier, "type": kind, "title": title}
        entry["tags"] = list(dict.fromkeys(
            tag["tag_name"] for tag in labels if tag.get("tag_dimension_id") in TAGS and tag.get("tag_name")
        ))
        edition = next((tag.get("tag_name") for tag in labels if tag.get("tag_dimension_id") == "zxxbb"), None)
        if edition:
            entry["edition"] = edition
        covers = row.get("custom_properties", {}).get("thumbnails") or []
        if covers:
            entry["cover"] = covers[0]
        yield identifier, entry


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("snapshots", type=Path)
    cli.add_argument("versions", type=Path)
    cli.add_argument("output", type=Path)
    args = cli.parse_args()
    version = json.loads(args.versions.read_bytes())
    if version.get("module") != "tch_material":
        cli.error("The metadata version does not describe the textbook index")
    books = {}
    for raw in version["urls"].split(","):
        url = urlsplit(raw)
        part = PART.fullmatch(url.path)
        if url.scheme != "https" or url.netloc not in CDN or url.query or url.fragment or not part:
            cli.error(f"Unexpected metadata part: {raw}")
        rows = json.loads((args.snapshots / f"smart-{part[1]}").read_bytes())
        if not isinstance(rows, list) or not rows:
            cli.error(f"Empty or invalid metadata part: {part[1]}")
        books.update(publications(rows))
    if not books:
        cli.error("No published textbooks were found")
    payload = json.dumps(list(books.values()), ensure_ascii=False, separators=(",", ":"))
    args.output.write_bytes(gzip.compress(payload.encode("utf-8"), mtime=0))
    print(f"Index {version['module_version']}: {len(books)} published textbooks")


if __name__ == "__main__":
    main()
