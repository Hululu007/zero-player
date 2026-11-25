"""Build a title and author index from the public ZGL all-books pages."""

import argparse
import gzip
from html.parser import HTMLParser
import json
from pathlib import Path
import re


BOOK = re.compile(r"/detail/([1-9][0-9]{0,11})")
COVER = re.compile(r"https://gbcloud-book\.oss\.zglibrary\.com/[a-f0-9]{32}\.(?:jpe?g|png|webp)")
PAGE = re.compile(r'<li class="number active">([0-9]+)</li>')
LAST = re.compile(r'href="/book/0_([0-9]+)"')
STRING = r'"(?:\\.|[^"\\])*"'
VALUE = rf'{STRING}|[$a-zA-Z_][$a-zA-Z_0-9]{{0,7}}|[0-9]+'
BOOK_FIELDS = re.compile(
    rf'\bbookAuthor:({VALUE}),bookName:({VALUE}),bookCover:(?:{VALUE}),'
    rf'chapterTotal:(?:{VALUE}),bookId:({VALUE}),bookDetail:'
)
NON_JSON = re.compile(rf'{STRING}|\b(?:NaN|void 0)\b|\bArray\([0-9]+\)|![01]|(?<=[,\s])-?\.(?=[0-9])')
COMPONENT = re.compile(r'<script>window\.__NUXT__=\(function\(([^)]+)\)\{(.*?)</script>', re.S)


class Catalogue(HTMLParser):
    def __init__(self):
        super().__init__()
        self.books = {}
        self.row = None
        self.title = False

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        classes = attrs.get("class", "").split()
        if tag == "a":
            match = BOOK.fullmatch(attrs.get("href", ""))
            self.row = {"id": match[1], "title": ""} if match and "bookItem" in classes else None
        elif self.row and tag == "strong" and "bookName" in classes:
            self.title = True
        elif self.row and tag == "img" and "bookCover" in classes:
            if COVER.fullmatch(attrs.get("src", "")):
                self.row["cover"] = attrs["src"]

    def handle_data(self, value):
        if self.row and self.title:
            self.row["title"] += value

    def handle_endtag(self, tag):
        if tag == "strong":
            self.title = False
        if tag == "a" and self.row:
            self.row["title"] = " ".join(self.row["title"].split())
            if self.row["title"]:
                self.books[self.row["id"]] = self.row
            self.row = None


def authors(body):
    # Read literal SSR arguments as data. The page's script is never run.
    component = COMPONENT.search(body)
    if not component:
        raise ValueError("missing published catalogue metadata")
    call = component[2].rsplit("}(", 1)
    if len(call) != 2 or not call[1].endswith("));"):
        raise ValueError("unexpected metadata wrapper")
    def normalize(token):
        value = token[0]
        if value.startswith('"'):
            return value
        if value.endswith("."):
            return "-0." if value.startswith("-") else "0."
        return {"!0": "true", "!1": "false"}.get(value, "null")

    raw = NON_JSON.sub(normalize, call[1][:-3])
    values = json.loads(f"[{raw}]")
    constants = dict(zip(component[1].split(","), values, strict=True))

    def value(atom):
        return json.loads(atom) if atom.startswith('"') else constants.get(atom)

    return {str(value(identifier)): (value(title), value(credit))
            for credit, title, identifier in BOOK_FIELDS.findall(call[0])}


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("snapshots", type=Path)
    cli.add_argument("output", type=Path)
    args = cli.parse_args()
    first = (args.snapshots / "1.html").read_text(encoding="utf-8")
    last = max(map(int, LAST.findall(first)))
    books = {}
    for page in range(1, last + 1):
        body = (args.snapshots / f"{page}.html").read_text(encoding="utf-8")
        active = PAGE.search(body)
        if not active or int(active[1]) != page:
            cli.error(f"Page {page} did not identify itself as requested")
        catalogue = Catalogue()
        catalogue.feed(body)
        catalogue.close()
        if not catalogue.books:
            cli.error(f"Page {page} contains no visible books")
        metadata = authors(body)
        for identifier, book in catalogue.books.items():
            title, credit = metadata.get(identifier, (None, None))
            if isinstance(title, str) and " ".join(title.split()) == book["title"] and isinstance(credit, str):
                book["author"] = " ".join(credit.split())
            books[identifier] = book
    payload = json.dumps(list(books.values()), ensure_ascii=False, separators=(",", ":"))
    args.output.write_bytes(gzip.compress(payload.encode("utf-8"), mtime=0))
    print(f"{len(books)} books across {last} pages. {sum(bool(x.get('author')) for x in books.values())} bylines.")


if __name__ == "__main__":
    main()
