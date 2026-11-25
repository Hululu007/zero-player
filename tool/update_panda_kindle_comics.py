"""Index comic release threads from the forum's public all-genres table."""

import argparse
import gzip
from html.parser import HTMLParser
import json
from pathlib import Path
import re


PAGES = re.compile(r'\bcurpage="([0-9]+)"[^>]*\btotalpage="([0-9]+)"')
THREAD = re.compile(r'normalthread_([1-9][0-9]{0,11})')
ADDRESS = re.compile(r'bbs-([1-9][0-9]{0,11})-1-[1-9][0-9]{0,4}\.html')
GENRE = re.compile(r'forum\.php\?mod=forumdisplay&fid=51&filter=typeid&typeid=[1-9][0-9]{0,3}')
FORMAT = re.compile(r'^(?:[【\[（(]\s*)?(?:azw3?|mobi|epub|pdf|cbz|kindle)\s*(?:[】\]）)】·：:\-\s]+)+', re.I)


class Listings(HTMLParser):
    def __init__(self):
        super().__init__()
        self.row = None
        self.title = None
        self.page = None
        self.genre = False
        self.books = {}

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == "tbody":
            thread = THREAD.fullmatch(attrs.get("id", ""))
            self.row = thread[1] if thread else None
            self.genre = False
        if tag == "a" and self.row:
            href = attrs.get("href", "")
            if GENRE.fullmatch(href):
                self.genre = True
            address = ADDRESS.fullmatch(href)
            if address and address[1] == self.row and "xst" in attrs.get("class", "").split():
                self.title = []
                self.page = href

    def handle_data(self, data):
        if self.title is not None:
            self.title.append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self.title is not None:
            title = " ".join("".join(self.title).split())
            self.title = None
            prefix = FORMAT.match(title)
            if prefix:
                title = title[prefix.end():].strip()
            if title and (prefix or self.genre):
                self.books[self.row] = {"id": self.row, "title": title, "page": self.page}
        if tag == "tbody":
            self.row = None


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("snapshots", type=Path)
    cli.add_argument("output", type=Path)
    args = cli.parse_args()
    first = (args.snapshots / "1.html").read_text(encoding="gb18030")
    last = int(PAGES.search(first)[2])
    books = {}
    for page in range(1, last + 1):
        body = (args.snapshots / f"{page}.html").read_text(encoding="gb18030", errors="replace")
        indicator = PAGES.search(body)
        if not indicator or int(indicator[1]) != page or indicator[2] != str(last):
            cli.error(f"Invalid forum page: {page}")
        catalogue = Listings()
        catalogue.feed(body)
        catalogue.close()
        books.update(catalogue.books)
    if not books:
        cli.error("No published comic releases found")
    payload = json.dumps(list(books.values()), ensure_ascii=False, separators=(",", ":"))
    args.output.write_bytes(gzip.compress(payload.encode("utf-8"), mtime=0))
    print(f"{len(books)} comic releases across {last} pages")


if __name__ == "__main__":
    main()
