"""Shared read-only checks for the later bundled-source sample evidence."""

import bz2
import hashlib
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
COMMIT = '42aa119be000a20f0220f8c35a17530c449e0ee7'
ARCHIVE_SHA256 = '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d'
HISTORICAL = {
    'ledger': ('docs/implementation/legado-source-ledger-20261115.json',
               '6877424859528319f67848af741f07ccff66bde782905fd2d1e0712c53e5f0dc'),
    'head': ('docs/implementation/legado-unresolved-head-later-20261116.json',
             '3024ff03581b0de4b286601188974e05cd8f7cf602b8af49e234ce054d2a6ebd'),
    'prior_pilot': ('docs/implementation/legado-sfwx-repair-20261116.json',
                    '2b9679fbb2f5b823af0cd10ff771862e04a618fb839c7931842ad921f211b6c0'),
}
SOURCES = {
    3984: ('9f004a19d12200c68d88fd5bafd4d34615b347d27e26322dbfa26142983cd295',
           'www.sfwx.com', '', '338b1507f045152f1795bbfb75b95f68bca074ea40f39ccb42cb08cbed5e238a'),
    828: ('03ce53f0b6632695058a7553e513b103e5aae06c34979992769d32e06af05fa8',
          'www.biquge7.xyz', 'biquge7.xyz#%23@%E9%81%87%E7%9F%A5',
          '0a48023c241f6f1f78c6864403ae3fa68db2f8b877be0fa3981b3fd5cd1f8914'),
    3002: ('ad35798f5b42bac39ba862133be63224081484921a86a8e8e6b5570e65ca63a3',
           'www.biquge7.xyz', '', 'e0768b6f273fc63bb1f09fc7bfb2514b749a3d15f0eb934bf797c1f6cdfac7cf'),
    2578: ('926a302f72881a7c6488555dfd0779da9db89c7f1ae35fbb14fbaaa9846caa43',
           'www.b520.cc', '', 'fc3ddc6cb8e9c568200327d1d360ba7fad42e88a698abb18b57147f8c536b2f8'),
}


def digest(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(',', ':')).encode('utf-8')


def require(condition, label):
    if not condition:
        raise ValueError(label)


def load_inputs():
    archive = (ROOT / 'assets/catalogs/books/legado/catalog.json.bz2').read_bytes()
    history = {key: subprocess.check_output(['git', 'show', f'{COMMIT}:{path}'], cwd=ROOT)
               for key, (path, _) in HISTORICAL.items()}
    return archive, history


def validate_basics(evidence, expected_digest, expected_indices, archive, history):
    require(digest(canonical(evidence)) == expected_digest, 'evidence changed')
    require(digest(archive) == ARCHIVE_SHA256, 'archive changed')
    require(set(history) == set(HISTORICAL), 'historical input set changed')
    for key, (_, expected) in HISTORICAL.items():
        require(digest(history[key]) == expected, f'historical input changed: {key}')
    refs = evidence['inputs']
    require(refs['historical_commit'] == COMMIT and refs['archive_sha256'] == ARCHIVE_SHA256,
            'input reference changed')
    for key, (path, sha) in HISTORICAL.items():
        require(refs['historical_files'][key] == {'path': path, 'sha256': sha},
                f'historical reference changed: {key}')
    data = {key: json.loads(value) for key, value in history.items()}
    ledger = {item['selected_record_index']: item for item in data['ledger']['sources']}
    heads = {item['host']: item for item in data['head']['results']}
    raw = json.loads(bz2.decompress(archive))['records']
    items = evidence.get('sources', [evidence.get('source')])
    observed = {item['index']: item for item in items}
    require(set(observed) == set(expected_indices), 'source scope changed')
    for index in expected_indices:
        identity, host, source_key, legado_sha = SOURCES[index]
        item, saved, record = observed[index], ledger[index], raw[index]
        require(item['id'] == saved['source_id'] == identity and
                item['host'] == saved['endpoint_host'] == host and
                item['source_key'] == source_key and
                item['kind'] == saved['kind'] == 'text' and
                item['format'] == saved['format'] == 'html' and
                item['old_legado_canonical_sha256'] ==
                saved['normalized_legado_canonical_sha256'] == legado_sha,
                f'source identity changed: {index}')
        require(item['endpoint_sha256'] == saved['endpoint_sha256'] and
                item['raw_record_canonical_sha256'] ==
                saved['selected_raw_record_canonical_sha256'] == digest(canonical(record)),
                f'archived source changed: {index}')
        for field, expected in item['raw_field_sha256'].items():
            value = record.get(field)
            encoded = value.encode('utf-8') if isinstance(value, str) else canonical(value)
            require(digest(encoded) == expected, f'raw field changed: {index}/{field}')
        head = heads[host]['latest_head']
        require(item['prior_head_status'] == head['http_status'] == 200 and
                item['prior_head_observed_at_utc'] == head['observed_at'],
                f'historical HEAD changed: {index}')
    serialized = canonical(evidence).decode('utf-8')
    require('?' not in serialized and not re.search(r'https?://|<script', serialized, re.I),
            'unexpected URL, query or page code in evidence')
    return data
