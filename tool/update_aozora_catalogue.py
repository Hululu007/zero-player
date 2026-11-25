"""Build the compact Aozora catalogue from its official UTF-8 CSV ZIP."""

import argparse
import csv
import gzip
import io
import json
from pathlib import Path
import re
import zipfile


CARD = re.compile(r"https://www\.aozora\.gr\.jp(/cards/\d{6}/card\d{1,6}\.html)")
MEMBER = "list_person_all_extended_utf8.csv"
ASSET = Path("assets/catalogs/books/aozora-index.json.gz")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zip", type=Path)
    args = parser.parse_args()

    books = {}
    with zipfile.ZipFile(args.zip) as archive:
        with io.TextIOWrapper(archive.open(MEMBER), encoding="utf-8-sig") as text:
            for row in csv.DictReader(text):
                card = CARD.fullmatch(row["図書カードURL"])
                title = " ".join(row["作品名"].split())
                if not card or not title:
                    continue
                book = books.setdefault(
                    row["作品ID"],
                    (card[1], title, row["副題"], {}, {}, row["公開日"]),
                )
                name = "".join(row[key].strip() for key in ("姓", "名"))
                role = row["役割フラグ"]
                if name and role == "著者":
                    book[3][name] = None
                if name and role == "翻訳者":
                    book[4][name] = None

    if len(books) < 10000:
        raise ValueError("Aozora catalogue is unexpectedly small")
    rows = [
        [path, title, subtitle, "、".join(authors), "、".join(translators)]
        for path, title, subtitle, authors, translators, _ in sorted(
            books.values(), key=lambda book: (book[5], book[0]), reverse=True
        )
    ]
    data = json.dumps(rows, ensure_ascii=False, separators=(",", ":")).encode()
    ASSET.write_bytes(gzip.compress(data, mtime=0))
    print(f"Wrote {len(rows)} Aozora records to {ASSET}")


if __name__ == "__main__":
    main()
