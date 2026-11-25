"""Generate the bundled directory from a DevTools HAR export of the source page."""

import argparse
import base64
import json
import re
from pathlib import Path
from urllib.parse import unquote, urlsplit

SOURCE = 'https://my.feishu.cn/docx/FXD9dBfaAo90vXxizY5cKKqense'
PAGE = urlsplit(SOURCE).path
URL = re.compile(r'https?://[^\s\u200b<>「」《》“”\[\]，；。]+')
LINK_LABEL = re.compile(r'^(?:链接|下载链接|网盘链接|夸克链接|百度网盘|夸克网盘|网盘|地址)[：:\s]*$')


def document(har):
    pages = []
    initial = None
    for entry in har['log']['entries']:
        address = urlsplit(entry['request']['url'])
        response = entry['response']
        if address.hostname != 'my.feishu.cn' or response['status'] != 200:
            continue
        if address.path not in (PAGE, '/space/api/docx/pages/client_vars'):
            continue
        content = response['content']
        text = content.get('text', '')
        if content.get('encoding') == 'base64':
            text = base64.b64decode(text).decode()
        if address.path == PAGE:
            marker = '"data":{"block_map"'
            if marker in text:
                initial = json.JSONDecoder().raw_decode(text, text.index(marker) + 7)[0]
        else:
            payload = json.loads(text)
            if payload.get('code') == 0 and payload['data']['id'] == PAGE.rsplit('/', 1)[1]:
                pages.append(payload['data'])
    if initial is None or not pages or not any(not page['has_more'] for page in pages):
        raise ValueError('The export must contain the initial page and its final continuation')
    blocks = {}
    for page in [initial, *pages]:
        if page['structure_version'] != initial['structure_version']:
            raise ValueError('The document changed during capture')
        blocks.update((key, block['data']) for key, block in page['block_map'].items())
    root = initial['id']
    visited = set()

    def visit(key):
        if key in visited:
            raise ValueError(f'Unexpected shared or cyclic block {key}')
        visited.add(key)
        for child in blocks[key].get('children', []):
            visit(child)

    visit(root)
    return blocks, root


def attributed(block):
    rich = block.get('text', {})
    attrs = rich.get('apool', {}).get('numToAttrib', {}).values()
    text = rich.get('initialAttributedTexts', {}).get('text', {})
    return ''.join(text.values()).replace('\u200b', '').strip(), list(attrs)


def row_links(text, attrs):
    raw = [match[0].rstrip(')）}、,，!！;；') for match in URL.finditer(text)]
    explicit = [unquote(value) for key, value in attrs if key == 'link']
    for link in explicit:
        if link not in raw:
            raw.append(link)
    for link in raw:
        address = urlsplit(link)
        if address.scheme not in ('http', 'https') or not address.hostname or address.username:
            raise ValueError(f'Invalid source URL {link}')
    return raw


def parse_rows(blocks, keys, category):
    rows = []
    current = rows
    pending = ''
    previous = ''
    pending_archive = ''

    def start_archive(name):
        group = {'name': name, 'rows': []}
        rows.append(group)
        return group['rows']

    for key in keys:
        block = blocks[key]
        title, attrs = attributed(block)
        links = row_links(title, attrs)
        children = block.get('children', [])
        if children:
            nested = parse_rows(blocks, children, category)
            name = title or pending_archive or pending
            if name:
                current.append({'name': name.rstrip('：:'), 'rows': nested})
            else:
                current.extend(nested)
            pending = previous = pending_archive = ''
        elif links:
            label = URL.split(title)[0].strip().rstrip('：:').strip()
            if not label or LINK_LABEL.fullmatch(label):
                label = pending or previous or links[0]
            elif pending_archive:
                current = start_archive(pending_archive)
            pending = pending_archive = ''
            previous = label
            for link in links:
                current.append({'name': label, 'url': link})
        elif title:
            # Bold/heading blocks start subarchives unless immediately
            # followed by a separate link line for that title.
            if pending_archive:
                current = start_archive(pending_archive)
                previous = ''
            pending = title
            pending_archive = title if (
                block['type'].startswith('heading')
                or ['bold', 'true'] in attrs
                or (category == '影视' and title == '动画片')
                or block['type'] == 'bullet'
            ) else ''
    return rows


def catalog(blocks, root):
    navigation = {}

    def read_navigation(key):
        block = blocks[key]
        text, attrs = attributed(block)
        links = row_links(text, attrs)
        for link in links:
            if text in navigation and navigation[text] != link:
                raise ValueError(f'Conflicting navigation link for {text}')
            navigation[text] = link
        for child in block.get('children', []):
            read_navigation(child)

    keys = blocks[root]['children']
    for key in keys:
        if blocks[key]['type'] == 'grid':
            read_navigation(key)
    categories = {}
    category = None
    for key in keys:
        block = blocks[key]
        name, _ = attributed(block)
        if block['type'] == 'heading1':
            category = name
            categories[category] = []
        elif block['type'] == 'callout' and category:
            children = block['children']
            first = children[0]
            title, attrs = attributed(blocks[first])
            if title and not row_links(title, attrs):
                rows = parse_rows(blocks, children[1:], category)
                categories[category].append({'name': title, 'rows': rows})
            else:
                categories[category].extend(parse_rows(blocks, children, category))
        elif block['type'] not in ('grid', 'image') and category:
            categories[category].extend(parse_rows(blocks, [key], category))
    if not categories or set(categories) - set(navigation):
        raise ValueError('Missing source category navigation')
    result = [
        {'name': title, 'url': link, 'rows': categories.get(title, [])}
        for title, link in navigation.items()
    ]
    expected = []
    for block in blocks.values():
        text, attrs = attributed(block)
        expected.extend(link for link in row_links(text, attrs) if link not in navigation.values())

    def links(rows):
        for entry in rows:
            if 'url' in entry:
                yield entry['url']
            yield from links(entry.get('rows', []))

    if sorted(links(result)) != sorted([*navigation.values(), *expected]):
        raise ValueError('One or more document links were lost during import')
    return {'source': SOURCE, 'categories': result}


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument('har', type=Path)
    args.add_argument('--output', type=Path, default=Path(
        'assets/catalogs/cloud/resources.json',
    ))
    options = args.parse_args()
    asset = catalog(*document(json.loads(options.har.read_text(encoding='utf-8-sig'))))
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(asset, ensure_ascii=False, indent=2) + '\n',
                              encoding='utf-8', newline='\n')


if __name__ == '__main__':
    main()
