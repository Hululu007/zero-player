"""Build a title index from the official daizhige-org/daizhigev20 Git tree.

Input is the saved recursive GitHub tree response for the data branch.
"""

import argparse
from collections import defaultdict
import gzip
import json
from pathlib import Path
import re


COLLECTIONS = set("儒藏 史藏 子藏 集藏 诗藏 艺藏 易藏 医藏 佛藏 道藏 现代作品 四庫全書".split())
VOLUME = re.compile(r"(?:卷[0-9]{1,5}|卷首|卷末)")
AUTHOR = re.compile(r"[（(]([^()（）]{1,36}?)(?:撰|著)[)）]$")
INVALID = re.compile(r"[\\\x00-\x1f\x7f]")
OUTPUT = Path("assets/catalogs/books/panda-daizhige.json.gz")


def catalogue(tree):
    folders = defaultdict(list)
    for entry in tree:
        path = entry["path"]
        parts = path.split("/")
        if (
            entry["type"] == "blob"
            and len(parts) >= 2
            and parts[0] in COLLECTIONS
            and all(part and not part.startswith(".") for part in parts)
            and path.endswith(".md")
            and not INVALID.search(path)
            and len(path) <= 397
        ):
            folders["/".join(parts[:-1])].append(parts[-1][:-3])

    books = {}
    for folder, files in folders.items():
        volumes = {name for name in files if VOLUME.fullmatch(name)}
        parent, _, title = folder.rpartition("/")
        if len(volumes) >= 2 and title not in folders.get(parent, ()):
            books[folder + "/"] = title
        for name in files:
            if name.strip() and not (len(volumes) >= 2 and name in volumes):
                books[f"{folder}/{name}.html"] = name

    for path, title in sorted(books.items()):
        credit = AUTHOR.search(title)
        yield [path, " ".join(title.split()), credit[1].strip() if credit else "", ""]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("git_tree", type=Path)
    args = parser.parse_args()
    index = json.loads(args.git_tree.read_bytes())
    if index.get("truncated") is not False:
        raise ValueError("The Git tree is incomplete")
    rows = list(catalogue(index["tree"]))
    if len(rows) < 15000 or {row[0].split("/", 1)[0] for row in rows} != COLLECTIONS:
        raise ValueError("One or more catalogue collections are incomplete")
    data = json.dumps(rows, ensure_ascii=False, separators=(",", ":"))
    OUTPUT.write_bytes(gzip.compress(data.encode(), mtime=0))
    print(f"Wrote {len(rows)} records from Git tree {index['sha']} to {OUTPUT}")


if __name__ == "__main__":
    main()
