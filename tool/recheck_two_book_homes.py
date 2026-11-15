"""Sample exactly two known book-source hosts twice; never execute resources."""

import argparse
from datetime import datetime, timezone
import hashlib
from html.parser import HTMLParser
import http.client
import json
from pathlib import Path
import re
import socket
import time

if __package__:
    from .audit_legado_catalog import CATALOG, RequestDeadline, inventory, public_addresses
    from .audit_legado_amsi import failure_category, sample_response
    from .triage_legado_eval_candidates import selected_indices
else:
    from audit_legado_catalog import CATALOG, RequestDeadline, inventory, public_addresses
    from audit_legado_amsi import failure_category, sample_response
    from triage_legado_eval_candidates import selected_indices


HOSTS = ('www.jjmh.top', 'www.635k.com')
VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}
SUPPRESSED = {'script', 'style', 'noscript', 'template', 'svg', 'head'}
CLUES = {
    'adult_explicit': ('成人漫画', '成人小說', '成人小说', '色情漫画', '色情小说', '色情網站', '成人视频',
                       '十八禁', '18禁', '18+', '色情', '裸体', '全裸', '色情网', '无码'),
    'photography_or_sexy': ('写真', '美腿', '美女', '性感', '丝袜', '套图', '写真集'),
    'gambling': ('在线博彩', '博彩平台', '网上赌场', '在线赌场', '真人百家乐', '体育投注',
                 '体育博彩', '六合彩', '赌博平台', '棋牌投注', '线上赌场', '线上博彩'),
}


def now():
    return datetime.now(timezone.utc).isoformat()


def clean(text, limit):
    return ' '.join(text.split())[:limit]


class StaticText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.in_title = False
        self.title = []
        self.descriptions = []
        self.visible = []

    def handle_starttag(self, tag, attributes):
        attrs = {str(k).lower(): v for k, v in attributes}
        if tag == 'meta' and ((attrs.get('name') or '').lower() == 'description'
                              or (attrs.get('property') or '').lower() == 'og:description'):
            content = attrs.get('content')
            if content:
                self.descriptions.append(clean(content, 240))
        if tag == 'title':
            self.in_title = True
        style = (attrs.get('style') or '').lower().replace(' ', '')
        hidden = (tag in SUPPRESSED or 'hidden' in attrs or
                  (attrs.get('aria-hidden') or '').lower() == 'true' or
                  'display:none' in style or 'visibility:hidden' in style)
        if tag not in VOID:
            self.stack.append((tag, hidden))

    def handle_endtag(self, tag):
        if tag == 'title':
            self.in_title = False
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                break

    def handle_data(self, text):
        if self.in_title:
            self.title.append(text)
        elif not any(hidden for _, hidden in self.stack):
            self.visible.append(text)


def excerpt(text, word):
    pos = text.lower().find(word.lower())
    return clean(text[max(0, pos - 35):pos + len(word) + 35], 90)


def inspect_html(payload):
    match = re.search(rb'charset\s*=\s*["\']?([a-zA-Z0-9_-]+)', payload[:4096], re.I)
    declared = match.group(1).decode('ascii').lower() if match else ''
    encoding = declared if declared in ('utf-8', 'utf8', 'gbk', 'gb2312', 'gb18030', 'big5') else 'utf-8'
    try:
        html = payload.decode(encoding)
    except UnicodeDecodeError:
        try:
            html, encoding = payload.decode('gb18030'), 'gb18030'
        except UnicodeDecodeError:
            html, encoding = payload.decode('utf-8', errors='replace'), 'utf-8-replacement'
    parser = StaticText()
    parser.feed(html)
    parser.close()
    text = clean(' '.join(parser.visible), 100000)
    clues = {}
    for category, words in CLUES.items():
        found = []
        for word in words:
            if word.lower() in text.lower():
                item = {'word': word, 'excerpt': excerpt(text, word)}
                if item not in found:
                    found.append(item)
        clues[category] = found[:10]
    return {'encoding': encoding, 'title': clean(' '.join(parser.title), 160),
            'descriptions': list(dict.fromkeys(parser.descriptions))[:2], 'visible_text_clues': clues}


def fetch_once(host, timeout):
    deadline = time.monotonic() + timeout
    addresses = public_addresses(host, timeout)
    family, address = addresses[0]
    with RequestDeadline(deadline) as limit:
        with socket.socket(family, socket.SOCK_STREAM) as plain:
            limit.attach(plain)
            plain.settimeout(limit.remaining())
            plain.connect((address, 443))
            with limit.wrap(plain, host) as secure:
                secure.settimeout(limit.remaining())
                secure.do_handshake()
                secure.settimeout(limit.remaining())
                result = sample_response(secure, host, limit)
                limit.remaining()
                return result


def source_evidence(rows, hosts, imported):
    parsed, selected = selected_indices(rows, imported)
    result = {}
    for host in HOSTS:
        records = []
        for index in hosts[host]:
            source = parsed.get(index)
            ident = source['id'] if source else None
            records.append({'record_index': index, 'raw_name': rows[index].get('bookSourceName'),
                            'source_id': ident, 'selected_version': bool(ident and selected.get(ident) == index)})
        result[host] = records
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--import-inventory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    rows, hosts, _, _, manifest = inventory(CATALOG)
    data = args.import_inventory.read_bytes()
    imported = json.loads(data)
    if imported['archive_sha256'] != manifest['archiveSha256']:
        raise ValueError('import inventory does not match bundled catalog')
    sources = source_evidence(rows, hosts, imported)
    result = {'method': 'At most two anonymous HTTPS GET / requests per exact host; validated public DNS, one pinned IP, verified TLS, no redirects, scripts, subresources or credentials. No response body saved.',
              'limitations': 'Visible text is a static approximation excluding common hidden/script elements; dynamic content, stylesheet visibility, malware and parsing usability are not verified. Photo/glamour labels and a single category are not proof that an entire host is adult.',
              'archive_sha256': manifest['archiveSha256'],
              'import_inventory_sha256': hashlib.sha256(data).hexdigest(),
              'import_inventory_generated_at': imported['generated_at'],
              'timeout_seconds': 8, 'started_at': now(), 'sources': sources, 'results': []}
    for attempt in (1, 2):
        for host in HOSTS:
            item = {'host': host, 'attempt': attempt, 'started_at': now()}
            try:
                response, body = fetch_once(host, 8)
                item.update(response)
                if body:
                    item.update(inspect_html(body))
            except (OSError, ValueError, http.client.HTTPException) as error:
                item['failure'] = failure_category(error)
            item['observed_at'] = now()
            result['results'].append(item)
            time.sleep(1)
    result['completed_at'] = now()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
