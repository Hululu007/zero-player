"""Build local title indexes from the public CBETA and CText catalogue exports."""

import argparse
import csv
import gzip
import json
from pathlib import Path
import re


CATALOGUES = {
    "cbeta": {
        "fields": ("primary_id", "title", "author", "edition"),
        "identifier": re.compile(r"[A-Z]{1,4}[0-9A-Za-z]{4,12}"),
        "minimum": 5000,
    },
    "ctext": {
        "fields": ("Primary_id", "Title", "Author", "Edition"),
        "identifier": re.compile(r"ctp:[a-z0-9-]{1,120}"),
        "minimum": 30000,
    },
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalogue", choices=CATALOGUES)
    parser.add_argument("csv", type=Path)
    args = parser.parse_args()
    spec = CATALOGUES[args.catalogue]
    rows = {}
    with args.csv.open(encoding="utf-8-sig", newline="") as source:
        for row in csv.DictReader(source):
            key, title, author, edition = (
                " ".join((row[field] or "").split()) for field in spec["fields"]
            )
            if title and spec["identifier"].fullmatch(key):
                rows.setdefault(key, [key, title, author, edition])
    if len(rows) < spec["minimum"]:
        raise ValueError("The downloaded catalogue appears incomplete")
    output = Path(f"assets/catalogs/books/panda-{args.catalogue}.json.gz")
    data = json.dumps(list(rows.values()), ensure_ascii=False, separators=(",", ":"))
    output.write_bytes(gzip.compress(data.encode(), mtime=0))
    print(f"Wrote {len(rows)} records to {output}")


if __name__ == "__main__":
    main()
