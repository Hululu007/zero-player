"""Extract book metadata and published PDF links from 科普阅读荟 series pages."""

import argparse
from html.parser import HTMLParser
import json
from pathlib import Path
import re
from urllib.parse import urljoin, urlsplit


ROOT = "https://www.cdstm.cn/subjects/jzrm/kpydh/"
PAGES = {
    "bkjgdhj": "cdstm-series.html",
    "ysjkx": "cdstm-ysjkx.html",
    "dmzgnkxj": "cdstm-dmzgnkxj.html",
    "qnkxjqtkx": "cdstm-qnkxjqtkx.html",
}
PDF_HOSTS = {
    "cdstm-resources-bucket.oss.cn-north-4.inspurcloudoss.com",
    "cdn.resources.cdstm.cn",
}


class Shelf(HTMLParser):
    def __init__(self, page):
        super().__init__()
        self.page = page
        self.depth = 0
        self.text_kind = None
        self.text = []
        self.books = []
        self.book = None

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == "div":
            if not self.depth and "daren-box" in attrs.get("class", "").split():
                self.book = {"page": self.page}
                self.depth = 1
            elif self.depth:
                self.depth += 1
        if self.book is None:
            return
        if tag in {"h3", "p"}:
            self.text_kind = tag
            self.text = []
        if tag == "img" and attrs.get("src"):
            image = urlsplit(urljoin(self.page, attrs["src"]))
            if image.scheme == "https" and image.netloc == "www.cdstm.cn" and not image.query and not image.fragment:
                self.book.setdefault("cover", image.geturl())
        if tag == "a" and attrs.get("href"):
            link = urlsplit(urljoin(self.page, attrs["href"]))
            if (link.scheme == "https" and link.netloc in PDF_HOSTS and not link.query and not link.fragment
                and re.fullmatch(r"/h5/jzrm/[a-zA-Z0-9_-]{1,140}\.pdf", link.path)):
                self.book.setdefault("pdf", link.geturl())

    def handle_data(self, data):
        if self.text_kind is not None:
            self.text.append(data)

    def handle_endtag(self, tag):
        if self.book is None:
            return
        if tag == self.text_kind:
            value = " ".join("".join(self.text).split())
            if tag == "h3":
                self.book.setdefault("title", value)
            for prefix, field in (("作者：", "author"), ("书号：", "isbn")):
                if value.startswith(prefix):
                    self.book[field] = value.removeprefix(prefix).strip()
            self.text_kind = None
        if tag == "div":
            self.depth -= 1
            if not self.depth:
                if self.book.get("title") and (self.book.get("isbn") or self.book.get("author")):
                    self.books.append(self.book)
                self.book = None
                self.text_kind = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("saved_directory", type=Path)
    args = parser.parse_args()
    books = []
    for slug, file in PAGES.items():
        shelf = Shelf(f"{ROOT}{slug}/index.html")
        shelf.feed((args.saved_directory / file).read_text(encoding="utf-8-sig"))
        if not shelf.books or shelf.depth:
            raise ValueError(f"Incomplete shelf: {file}")
        books.extend(shelf.books)
        print(f"{slug}: {len(shelf.books)} titles")
    output = Path("assets/catalogs/books/panda-cdstm.json")
    output.write_text(json.dumps(books, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(books)} catalogue entries to {output}")


if __name__ == "__main__":
    main()
