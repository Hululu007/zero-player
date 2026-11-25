"""Index actual book listings in Hina's public shop sitemap."""

import argparse
from html.parser import HTMLParser
import json
from pathlib import Path
from urllib.parse import unquote, urlsplit
from xml.etree import ElementTree


HOST = "www.hinabook.com"
OUTPUT = Path("assets/catalogs/books/panda-hinabook.json")


class ProductPage(HTMLParser):
    def __init__(self):
        super().__init__()
        self.json_ld = False
        self.fragments = []
        self.products = []

    def handle_starttag(self, tag, attrs):
        if tag == "script" and dict(attrs).get("type") == "application/ld+json":
            self.json_ld = True
            self.fragments = []

    def handle_data(self, data):
        if self.json_ld:
            self.fragments.append(data)

    def handle_endtag(self, tag):
        if tag == "script" and self.json_ld:
            self.json_ld = False
            record = json.loads("".join(self.fragments))
            if isinstance(record, dict) and record.get("@type") == "Product":
                self.products.append(record)


def product_url(raw):
    url = urlsplit(raw)
    parts = unquote(url.path).split("/")
    return (url.scheme == "https" and url.netloc == HOST and not url.query
            and not url.fragment and len(parts) == 3 and parts[1] == "product-page"
            and parts[2] and parts[2] not in {".", ".."})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sitemap", type=Path)
    parser.add_argument("products", type=Path)
    args = parser.parse_args()
    sitemap = ElementTree.parse(args.sitemap)
    rows = []
    for index, location in enumerate(sitemap.findall("./{*}url/{*}loc")):
        url = location.text
        if not url or not product_url(url):
            continue
        page = ProductPage()
        page.feed((args.products / f"hina-product-{index:02d}.html").read_text(encoding="utf-8"))
        page.close()
        if len(page.products) != 1:
            parser.error(f"expected one structured product at {url}")
        product, = page.products
        title = product["name"].strip()
        if not title or title.casefold() == "i'm a product":
            continue
        offer = product["offers"]["url"]
        if not product_url(offer) or unquote(url) != unquote(offer):
            parser.error(f"product address does not match sitemap at {url}")
        cover = product["image"][0]["contentUrl"]
        image = urlsplit(cover)
        if image.scheme != "https" or image.netloc != "static.wixstatic.com" or not image.path.startswith("/media/"):
            parser.error(f"unexpected product cover at {url}")
        rows.append({"title": title, "page": url, "cover": cover})
    if not rows:
        parser.error("the sitemap contains no verified book products")
    OUTPUT.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(rows)} verified products to {OUTPUT}")


if __name__ == "__main__":
    main()
