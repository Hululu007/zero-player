"""Build a title and author index from the published JB51 book list pages."""

import argparse
import gzip
from html.parser import HTMLParser
import json
from pathlib import Path
import re
from urllib.parse import urljoin, urlsplit


ORIGIN = "https://www.jb51.net"
BOOK_PATH = re.compile(r"/books/([1-9][0-9]{0,10})\.html")
LIST_PATH = re.compile(r"/books/list([1-9][0-9]{0,4})_([1-9][0-9]{0,3})\.html")
ACTIVE_PAGE = re.compile(r'<div class="dxypage">.{0,4000}?<strong>\s*(\d+)\s*</strong>', re.S)
IMAGE_PATH = re.compile(r"/do/uploads/[^?#]+\.(?:gif|jpe?g|png|webp)", re.I)
CREDIT = re.compile(r"(?:^|[。；;\s])(?:作者|著者)\s*[:：]\s*([^。；;\r\n]{2,48})")


class BookList(HTMLParser):
    def __init__(self):
        super().__init__()
        self.canonical = ""
        self.rows = []
        self.row = None
        self.paragraph = ""
        self.capture = False
        self.text = []
        self.list_depth = 0
        self.book_image = False

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == "link" and attrs.get("rel") == "canonical":
            self.canonical = attrs.get("href", "")
        if tag == "ul" and (self.list_depth or attrs.get("id") == "list_ul_more"):
            self.list_depth += 1
        if not self.list_depth:
            return
        if tag == "p":
            classes = attrs.get("class", "").split()
            self.paragraph = next((word for word in ("tit", "desc") if word in classes), "")
            self.text.clear()
        if tag == "a":
            url = urlsplit(urljoin(ORIGIN, attrs.get("href", "")))
            match = BOOK_PATH.fullmatch(url.path)
            if url.netloc == "www.jb51.net" and match and not url.query and not url.fragment:
                if self.paragraph == "tit":
                    self.row = {"id": match[1]}
                    self.rows.append(self.row)
                    self.capture = True
                self.book_image = self.row is not None and self.row["id"] == match[1]
        if tag == "img" and self.book_image and self.row is not None and "cover" not in self.row:
            url = urlsplit(urljoin(ORIGIN, attrs.get("src", "")))
            if (url.scheme == "https" and url.netloc == "img.jbzj.com"
                and IMAGE_PATH.fullmatch(url.path) and not url.query and not url.fragment):
                self.row["cover"] = url.geturl()

    def handle_data(self, data):
        if self.capture or self.paragraph == "desc":
            self.text.append(data)

    def handle_endtag(self, tag):
        if tag == "ul" and self.list_depth:
            self.list_depth -= 1
        if tag == "a":
            self.book_image = False
        if self.capture and tag == "a" and self.row is not None:
            self.row["title"] = " ".join("".join(self.text).split())
            self.capture = False
        if tag == "p":
            if self.paragraph == "desc" and self.row is not None:
                credit = CREDIT.search("".join(self.text))
                if credit:
                    self.row["author"] = credit[1].strip()
            self.paragraph = ""
            self.text.clear()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshots", type=Path)
    parser.add_argument("census", type=Path)
    parser.add_argument("output", metavar="INDEX", type=Path)
    args = parser.parse_args()
    census = json.loads(args.census.read_text(encoding="utf-8"))
    books = {}
    for category, summary in census.items():
        if not summary["available"]:
            parser.error(f"category {category} was unavailable")
        for page in range(1, summary["last_page"] + 1):
            path = args.snapshots / f"{category}-{page}.html"
            snapshot = BookList()
            text = path.read_text(encoding="utf-8")
            snapshot.feed(text)
            snapshot.close()
            url = urlsplit(snapshot.canonical)
            match = LIST_PATH.fullmatch(url.path)
            active = ACTIVE_PAGE.search(text)
            alias = match is not None and match[2] == "1" and active is not None and active[1] == str(page)
            if (url.netloc != "www.jb51.net" or match is None or match[1] != category
                or (match[2] != str(page) and not alias)):
                parser.error(f"unexpected canonical URL in {path}")
            for row in snapshot.rows:
                if row.get("title"):
                    books.setdefault(row["id"], {}).update(row)
    if not books:
        parser.error("no book records found")
    payload = json.dumps(list(books.values()), ensure_ascii=False, separators=(",", ":"))
    args.output.write_bytes(gzip.compress(payload.encode("utf-8"), mtime=0))
    print(f"{len(books)} books across {len(census)} categories")


if __name__ == "__main__":
    main()
