"""Create a metadata-only index from Scripta Sinica's public annual catalogues."""

import argparse
import gzip
from html.parser import HTMLParser
import json
from pathlib import Path
import re
from urllib.parse import urlsplit


HOST = "hanchi.ihp.sinica.edu.tw"
OUTPUT = Path("assets/catalogs/books/panda-hanji.json.gz")
BOOK_ID = re.compile(r"[A-Za-z0-9]{9,10}")
ANNUAL_PATH = re.compile(r'/ihp/(20[0-9]{2})_booklist\.htm')


class AnnualCatalogue(HTMLParser):
    def __init__(self):
        super().__init__()
        self.cells = None
        self.fragments = None
        self.link = None
        self.rows = []

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self.cells = []
            self.link = None
        elif tag == "td" and self.cells is not None:
            self.fragments = []
        elif tag == "a" and self.cells is not None and len(self.cells) == 3:
            link = urlsplit(dict(attrs).get("href", ""))
            if (link.scheme in {"http", "https"} and link.netloc == HOST
                and link.path == "/ihpc/hanjieb" and not link.fragment
                and BOOK_ID.fullmatch(link.query)):
                self.link = link.query

    def handle_data(self, data):
        if self.fragments is not None:
            self.fragments.append(data)

    def handle_endtag(self, tag):
        if tag == "td" and self.cells is not None and self.fragments is not None:
            self.cells.append(" ".join("".join(self.fragments).split()))
            self.fragments = None
        elif tag == "tr" and self.cells is not None:
            if self.link and len(self.cells) == 7 and self.cells[3]:
                self.rows.append([self.link, self.cells[3], self.cells[5], self.cells[6]])
            self.cells = None
            self.fragments = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshots", type=Path)
    args = parser.parse_args()
    directory = (args.snapshots / "hanji-new.html").read_text(encoding="utf-8")
    years = sorted(set(ANNUAL_PATH.findall(directory)), reverse=True)
    if not years:
        parser.error("the official index lists no annual catalogues")
    books = {}
    for year in years:
        annual = AnnualCatalogue()
        annual.feed((args.snapshots / f"hanji-{year}.html").read_text(encoding="utf-8-sig"))
        annual.close()
        if not annual.rows:
            parser.error(f"the {year} catalogue has no downloadable metadata rows")
        for row in annual.rows:
            books.setdefault(row[0], row)
    data = json.dumps(list(books.values()), ensure_ascii=False, separators=(",", ":"))
    OUTPUT.write_bytes(gzip.compress(data.encode(), mtime=0))
    print(f"Wrote {len(books)} records from {len(years)} annual catalogues to {OUTPUT}")


if __name__ == "__main__":
    main()
