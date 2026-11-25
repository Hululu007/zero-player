"""Build the searchable Shiren index from saved public poetry directories."""

import argparse
import gzip
from html.parser import HTMLParser
import json
from pathlib import Path
import re
from urllib.parse import urljoin, urlsplit


ORIGIN = "https://www.shiren.org"
DIRECTORIES = (
    ("shiren-gs.html", "gs", "古典诗库", ""),
    ("shiren-xs.html", "xs", "现代诗库", "navlistli9"),
    ("poetry-foreign.body", "ws/wg", "外国诗歌中译", "navlistli4"),
    ("poetry-foreign-folk.body", "ws/ww", "外文原作", ""),
    ("poetry-abroad-chinese.body", "ws/zg", "中国诗歌外译", ""),
    ("poetry-bilingual.body", "ws/sy", "双语诗歌", ""),
)
OUTPUT = Path("assets/catalogs/books/panda-shiren.json.gz")
PATH = re.compile(r"/shiku/(?:gs|xs|ws/(?:wg|ww|zg|sy))/(?:[\w-]+/){0,4}[\w-]+\.(?:html?|pdf)", re.ASCII)
POET_CREDIT = re.compile(r"^([\u3400-\u9fff·]{2,8}?)(?:诗全集|词全集|全集|诗精选|诗赋选|赋选|诗集|诗选|词选)$")
ENGLISH_CREDIT = re.compile(r"(?:^|\s)Poems by (.+?)(?: \(in [^)]+\))?$", re.I)
PLACEHOLDER = re.compile(r"^(?:首页|更多[.…]*|总目录|作品汇编|电子书库|返回.*)$")
COLLECTIVE = re.compile(r"历代|唐宋|明清|魏晋|南北朝|汉代|秦代|五代|元代|明代|清代|先秦|全唐|全宋|诗歌|金元|古代|名家|文人")


class Catalogue(HTMLParser):
    def __init__(self):
        super().__init__()
        self.list_id = ""
        self.current = None
        self.links = []

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == "li":
            self.list_id = attrs.get("id", "")
        elif tag == "a" and attrs.get("href"):
            self.current = (attrs["href"], self.list_id, [])

    def handle_data(self, data):
        if self.current is not None:
            self.current[2].append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self.current is not None:
            href, role, caption = self.current
            self.links.append((href, role, " ".join("".join(caption).split())))
            self.current = None
        elif tag in {"li", "ul"}:
            self.list_id = ""


def entries(folder, file, branch, category, author_role):
    catalogue = Catalogue()
    catalogue.feed((folder / file).read_bytes().decode("gb18030"))
    for href, role, caption in catalogue.links:
        url = urlsplit(urljoin(f"{ORIGIN}/shiku/{branch}/index.htm", href))
        if (
            url.scheme != "https" or url.netloc != "www.shiren.org"
            or url.query or url.fragment or not PATH.fullmatch(url.path)
            or not url.path.startswith(f"/shiku/{branch}/")
            or url.path == f"/shiku/{branch}/index.htm"
        ):
            continue
        title = re.sub(r"\s*\[PDF\]\s*$", "", caption, flags=re.I).strip("《》 ")
        if not title or len(title) > 180 or PLACEHOLDER.fullmatch(title):
            continue
        author = ""
        if author_role and role == author_role:
            author = title
        elif match := ENGLISH_CREDIT.search(title):
            author = match[1]
        elif match := POET_CREDIT.fullmatch(title):
            if not COLLECTIVE.search(match[1]):
                author = match[1]
        yield [url.path, title, author, category]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("saved_directory", type=Path)
    args = parser.parse_args()
    books = {}
    for spec in DIRECTORIES:
        rows = set()
        for item in entries(args.saved_directory, *spec):
            path = item[0]
            previous = books.get(path)
            if previous is None or (item[2] and not previous[2]):
                books[path] = item
            rows.add(path)
        if not rows:
            raise ValueError(f"Empty or invalid directory: {spec[0]}")
        print(f"{spec[2]} {len(rows)} entries")
    if len(books) < 1000:
        raise ValueError("The saved archive appears incomplete")
    index = json.dumps(list(books.values()), ensure_ascii=False, separators=(",", ":"))
    OUTPUT.write_bytes(gzip.compress(index.encode(), mtime=0))
    print(f"Wrote {len(books)} records to {OUTPUT}")


if __name__ == "__main__":
    main()
