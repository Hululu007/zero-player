"""Build the local search asset from Project Gutenberg's public-domain CSV."""

import argparse
import csv
import gzip
import json
from pathlib import Path


ASSET = Path(__file__).resolve().parents[1] / "assets/catalogs/books/gutenberg-index.json.gz"
COLUMNS = {"Text#", "Type", "Title", "Authors", "Language"}


def read_books(index):
    books = {}
    with gzip.open(index, "rt", encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        if not COLUMNS.issubset(reader.fieldnames or []):
            raise ValueError("Unrecognized Project Gutenberg CSV columns")
        for row in reader:
            if row["Type"] != "Text" or not row["Title"].strip():
                continue
            identifier = int(row["Text#"])
            if not 1 <= identifier <= 9_999_999 or identifier in books:
                raise ValueError(f"Unexpected Gutenberg identifier {identifier}")
            books[identifier] = [identifier, row["Title"], row["Authors"], row["Language"]]
    if not books or len(books) > 120_000:
        raise ValueError("Gutenberg catalogue has an unexpected size")
    return [books[identifier] for identifier in sorted(books)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("index", type=Path, help="Official pg_catalog.csv.gz")
    args = parser.parse_args()
    books = read_books(args.index)
    text = json.dumps({"version": 1, "books": books}, ensure_ascii=False, separators=(",", ":"))
    payload = text.encode("utf-8")
    if len(payload) > 16 << 20:
        raise ValueError("Gutenberg catalogue exceeds the app's expanded size limit")
    compressed = gzip.compress(payload, mtime=0)
    if len(compressed) > 5 << 20:
        raise ValueError("Gutenberg catalogue exceeds the app's compressed size limit")
    ASSET.write_bytes(compressed)
    print(f"{len(books)} books, {len(compressed)} bytes: {ASSET}")


if __name__ == "__main__":
    main()
