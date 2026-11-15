"""Download one pinned Block List Project snapshot into ignored build data.

Only the six explicitly named files at the pinned GitHub commit are requested.
No catalog hosts, user data, source rules, credentials, or cookies are sent.
The committed Git blob IDs and byte counts are verified before publication.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import time
import urllib.request


COMMIT = 'ee3bdbaddf49c756cf3340bb2e6a9dee5282d1c6'
COMMIT_DATE = '2026-07-20T13:05:33Z'
TREE = 'b8cf4bdbdf55e6092439c6e31639e8d35490f4f3'
REPOSITORY = 'https://github.com/blocklistproject/Lists'
RAW_BASE = f'https://raw.githubusercontent.com/blocklistproject/Lists/{COMMIT}'
FILES = {
    'LICENSE': (1211, 'fdddb29aa445bf3d6a5d843d6dd77e10a9f99657'),
    'README.md': (23229, 'ef5cfe9523743ef708603f983c5db9e457b7f65a'),
    'gambling.txt': (8368035, '701eb4384ae3d65cfc25d9334f7eb0ee34fb4ef9'),
    'malware.txt': (72161681, '2c588b9044ffd92c13ae58d66c168ab76b01a18b'),
    'phishing.txt': (5686136, 'e0a28da056a5c01c7bc37c12760cb97d4d51207c'),
    'porn.txt': (26095053, '1be063bbf6411576e4b2e911816a77c28b9f49d1'),
}
MAX_TOTAL = 120 * 1024 * 1024
CHUNK = 256 * 1024
MAX_SECONDS_PER_FILE = 300


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('snapshot redirects are not permitted')


def feed_header(prefix):
    """Extract a few attribution fields, never the list's domain entries."""
    wanted = {'title', 'description', 'license', 'last modified', 'entries',
              'date', 'format'}
    found = {}
    for line in prefix.decode('utf-8', errors='replace').splitlines():
        text = line.strip()
        if not text:
            continue
        if not text.startswith('#'):
            break
        match = re.match(r'^#\s*([^:]+):\s*(.*)$', text)
        if match and match[1].strip().lower() in wanted:
            found[match[1].strip().lower().replace(' ', '_')] = match[2].strip()[:200]
    return found


def download_file(opener, folder, name, size, blob):
    if name not in FILES or FILES[name] != (size, blob):
        raise ValueError('file is not in the pinned snapshot allowlist')
    url = f'{RAW_BASE}/{name}'
    request = urllib.request.Request(url, method='GET', headers={
        'User-Agent': 'ZeroPlayer-Offline-Source-Audit/1.0',
        'Accept': 'text/plain',
        'Accept-Encoding': 'identity',
    })
    partial = folder / (name + '.part')
    destination = folder / name
    digest = hashlib.sha256()
    git = hashlib.sha1(f'blob {size}\0'.encode('ascii'))
    prefix = bytearray()
    count = 0
    started = time.monotonic()
    observed = datetime.now(timezone.utc).isoformat()
    with opener.open(request, timeout=20) as response:
        if response.status != 200 or response.geturl() != url:
            raise ValueError(f'unexpected response for {name}')
        length = response.headers.get('Content-Length')
        if length is not None and int(length) != size:
            raise ValueError(f'unexpected Content-Length for {name}')
        if response.headers.get('Content-Encoding', 'identity').lower() != 'identity':
            raise ValueError(f'unexpected Content-Encoding for {name}')
        content_type = response.headers.get('Content-Type')
        etag = response.headers.get('ETag')
        with partial.open('xb') as output:
            while True:
                if time.monotonic() - started > MAX_SECONDS_PER_FILE:
                    raise TimeoutError(f'download deadline exceeded for {name}')
                block = response.read(min(CHUNK, size + 1 - count))
                if not block:
                    break
                count += len(block)
                if count > size:
                    raise ValueError(f'download exceeds pinned size for {name}')
                digest.update(block)
                git.update(block)
                if len(prefix) < 8192:
                    prefix.extend(block[:8192 - len(prefix)])
                output.write(block)
    if count != size or git.hexdigest() != blob:
        raise ValueError(f'download does not match the pinned Git blob for {name}')
    partial.rename(destination)
    return {'url': url, 'observed_at': observed,
            'completed_at': datetime.now(timezone.utc).isoformat(),
            'status': 200, 'content_type': content_type, 'etag': etag,
            'bytes': count, 'git_blob_sha1': blob, 'sha256': digest.hexdigest(),
            'file_header': feed_header(prefix) if name.endswith('.txt') else {}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True,
                        help='new snapshot directory beneath the ignored build directory')
    args = parser.parse_args()
    build = Path('build').resolve(strict=True)
    output = args.output.resolve(strict=False)
    if output == build or not output.is_relative_to(build):
        raise ValueError('snapshot directory must be a new child of build')
    if sum(size for size, _ in FILES.values()) > MAX_TOTAL:
        raise ValueError('pinned snapshot exceeds the total byte budget')
    output.mkdir(parents=False, exist_ok=False)
    opener = urllib.request.build_opener(NoRedirect())
    records = {}
    for name, (size, blob) in FILES.items():
        print(f'downloading {name} ({size} bytes)', flush=True)
        records[name] = download_file(opener, output, name, size, blob)
    metadata = {'repository': REPOSITORY, 'revision': COMMIT,
                'commit_date': COMMIT_DATE, 'tree': TREE,
                'tree_metadata_url': f'https://api.github.com/repos/blocklistproject/Lists/git/trees/{TREE}',
                'repository_license': 'Unlicense (repository LICENSE and README)',
                'files': records}
    (output / 'snapshot.json').write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'verified snapshot saved in {output}', flush=True)


if __name__ == '__main__':
    main()
