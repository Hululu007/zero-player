"""Pin the manually reviewed local-eval source snapshots and their callers.

This checks archived field hashes, selection and static text markers. Packed
JavaScript is expanded only as data by parsing its quoted constants and doing
text substitution. No source rule, web script or unpacked code is executed.
The conclusions are limited to the inspected snapshots and do not certify a
source, a website, its current content, or a different rule version as safe.
"""

import argparse
import ast
import hashlib
import json
from pathlib import Path
import re

if __package__:
    from .audit_legado_catalog import CATALOG, inventory
    from .audit_legado_rule_patterns import strings
    from .triage_legado_eval_candidates import selected_indices
else:
    from audit_legado_catalog import CATALOG, inventory
    from audit_legado_rule_patterns import strings
    from triage_legado_eval_candidates import selected_indices


# Each tuple pins source ID, the digest of all checked field hashes, and extra
# non-eval fields needed to trace the origin or use of the evaluated data.
REVIEWED = {
    27: ('2ecb4f67377130c47c96eb78997b20e76f88b6e3352dd7bac94a73418b18ad80', '9626a1bd57d9f7cff9f2de3c6dbaefdda0f49b5472e82ac7168ab3bb3066284d', ('bookSourceComment',)),
    243: ('e5044e38adeaa29a5c1e1cec693f715bd27bf869ca2de0864681749795c84cad', '37ee8a42cf0f99c5884dd85f32f6d3b0d0812b9158e91b3ac0d63c40c3645c35', ('bookSourceComment',)),
    733: ('b3be4a799c097a368cd7aadc22034afce90c6d6d17062273525874de2e19b00c', '906130707c723e55103551da48c11dd0fbd29f3a4a487092fc5c4e378a6d87f5', ('bookSourceComment',)),
    3432: ('abfd798c76037dd73bfb1da7c5c91ff67f2c464c00539c4bbfd342898c8c1d56', '6a870dda671aee9a86d65e6f18bb6ca59d033a90700c9e24d8f1cc1212aa9432', ()),
    1160: ('4844827f5d17a25f6978efa8ce0f62924c092927c4601ca454fe79f764bd3706', '83e8c8fbcbcce1cfa15f9c8e9c4b669371c9cbc2cae83a2cae7f16a82150b168', ('bookSourceComment',)),
    1195: ('6df213b17ffed2ae4e4dd3be29e078e307751dbeb57e4940ba7db5cbe8a79204', 'd986d4578c67d67253ae0074de3190dda251ea1d393b8020d361973a7ae4da40', ('variableComment',)),
    1671: ('d5a9dc00da56f1932ab8bf3d43729cc08a561c9d9054f4bb630a0a4fed13e5bf', '29847a13015814b3c64a5a70f3222838c8cc9d372533f57bef4240753245141e', ('bookSourceComment',)),
    1787: ('dd20c02ee9937525898be0bbdadb09e31a4b5da887c99fe99a4ec100ef2ffb0f', 'f5983e6bcd3aebfd380c3f66e014c0feaa8a5bbb8f6fea642496fe39dfd7e2e0', ('bookSourceComment',)),
    1788: ('09ab5c51cd9ae2d950ca405915a0531c580ddaf24c9363159e4cbc33ca44dcb0', '3301db1df2939dad7ae0ecc023cad34efd8f56dd390e72612013f7628eb7d6d6', ('bookSourceComment',)),
    3466: ('09e92e62859b1171da90310ed28f1985e224e4d9dbf371720d4a00e8bc63862a', '4af9187aac198445d8f26cfd1e4bb0eb7c24b056756f2434bbb31218c57948d9', ('bookSourceComment',)),
    3551: ('6a3ec699b1bd26d6a73afc8a7e41693cb3d3bf6dc5da47a9a4bcfc38f4f7fa56', 'fd21594a57384e6175e770bcfbe6dcc160138e18c0e70d0d8da834efa795dde1', ('bookSourceComment',)),
    3552: ('21cf1ffe5a442a8bb29ab23d497abe50998a9f957286a59e4f1806ba3ee5af4c', 'ff9eb5892275ebe277c3cad6097f964b2663c0dba506d72d6b98bce5f9655a52', ('bookSourceComment',)),
    4829: ('3d30aadf74d4922a3f67eb0370b95653b44bef0121f268677fbad12e53e001e6', '8a68a7dcbb92749fbb590b5976b3b1f01b3780055870b3dbd2d4931de43ac187', ('bookSourceComment',)),
    4415: ('770edfb7d285da0655ca662bb64caed3c9137ae70435c1092080dcc18ef0e616', 'bab5c79931def990c5883e4bec3f46b7db28dda5c9cdb08d90fc8a96edd3142c', ('bookSourceComment',)),
    4497: ('5d62bdffeb682308c60195899c22524ea2d1df4967e3b3ed04360e1ce4d2ea04', '6f3c0ebf75394d7ad324bd2f689c43ab4a74c3f2c6cb150cdb4f51030c7f37ac', ('bookSourceComment',)),
    4509: ('abee5694234410c1f236d7693298936d347e4fca19363934cc749f0279ba41e5', '337979230cb5efe8acf27e992353812a81920677c9858ffe6786914d7303953b', ('bookSourceComment',)),
    4828: ('ec72141258d931cf218be074307cf65af36e8a3f4231d85322cec3ee9aebd7a0', '66f7debb0c18e32e0e02f94e469bd014134dcc1f2826fa81bb23878005677091', ('bookSourceComment',)),
    3943: ('009e1a910a328cc9ef2b36835134c18d7319beb134893960552a89214d31240a', '095ce17653bd639a4aea9680f3955de75cbdb73f28342efb1a158fb0d8a3e07e', ('loginUrl', 'jsLib')),
    4481: ('30923a061b13715e8cc3ccdd13ec3a35bd4e615c0b8775eda5e7016f2282d286', 'efea6bd9ada2a74b650c876cee7e46b7b522db5e0a3be2fa6fd3001c98718836', ('bookSourceComment', 'exploreUrl', 'searchUrl')),
}

# Markers substantiate the specific manual data-flow claim; full field digests
# are pinned separately. Marker strings and code fragments are not exported.
CHECKS = {
    27: {'ruleContent.content': ('eval(String(source.bookSourceComment))', 'decode(result)'), 'bookSourceComment': ('function decode', 'Cipher.getInstance')},
    243: {'ruleContent.content': ('eval(String(source.bookSourceComment))', 'java.startBrowser(jxurl+result'), 'bookSourceComment': ('jxurl=', 'list:')},
    733: {'bookSourceComment': ('flag = 1',)},
    3432: {'ruleSearch.bookList': ('var O=', 'eval(function(')},
    1160: {'bookSourceComment': ('flag = 1', 'function ti('), 'ruleSearch.name': ('eval(String(source.bookSourceComment))', 'ti(result')},
    1195: {'variableComment': ('result=result.replace',), 'ruleContent.content': ('eval(String(source.variableComment))',)},
    1671: {'bookSourceComment': ('JSON.stringify(body)', 'java.HMacBase64'), 'ruleSearch.bookUrl': ('bookId: {{$.bookId}}', 'eval(String(source.bookSourceComment))'), 'searchUrl': ('keyword: key', 'eval(String(source.bookSourceComment))')},
    1787: {'bookSourceComment': ('flag = 1', 'function ti('), 'ruleSearch.name': ('eval(String(source.bookSourceComment))', 'ti(result')},
    1788: {'bookSourceComment': ('source.getVariable()', 'function ti('), 'ruleSearch.name': ('eval(String(source.bookSourceComment))', 'ti(result')},
    3466: {'bookSourceComment': ('flag = 1',), 'ruleBookInfo.init': ('eval(String(source.bookSourceComment))', 'Jsoup.parse(result)')},
    3551: {'bookSourceComment': ('flag = 1',), 'ruleBookInfo.init': ('eval(String(source.bookSourceComment))', 'Jsoup.parse(result)')},
    3552: {'bookSourceComment': ('flag = 1',), 'ruleBookInfo.init': ('eval(String(source.bookSourceComment))', 'Jsoup.parse(result)')},
    4829: {'bookSourceComment': ('flag = 1', 'function ti('), 'ruleSearch.name': ('eval(String(source.bookSourceComment))', 'ti(result')},
    4415: {'bookSourceComment': ('result=result.replace',), 'ruleSearch.name': ('eval(String(source.bookSourceComment))',)},
    4497: {'bookSourceComment': ('function x(e, m)', 'x(result, m)'), 'ruleContent.replaceRegex': ('eval(String(source.bookSourceComment))',)},
    4509: {'bookSourceComment': ('function x(e, m)', 'x(result, m)'), 'ruleContent.replaceRegex': ('eval(String(source.bookSourceComment))',)},
    4828: {'bookSourceComment': ('function traditionalToSimplified(',), 'ruleBookInfo.intro': ('eval(String(source.bookSourceComment))', 'traditionalToSimplified(result)')},
    3943: {'exploreUrl': ('eval(String(source.loginUrl))', 'login()'), 'searchUrl': ('eval(String(source.loginUrl))', 'login()'), 'loginUrl': ('java.ajax(u)', 'JSON.parse(loginres)', 'source.setVariable'), 'jsLib': ('function creatRequest(', 'JSON.parse(source.getVariable())')},
    4481: {'bookSourceComment': ('escape(result)', 'unescape(html)'), 'ruleToc.chapterName': ('eval(String(source.bookSourceComment))',), 'exploreUrl': ('Jsoup.parse(java.ajax(site.u))',), 'searchUrl': ('java.ajax(url)',)},
}

FLOWS = {
    27: '内容与章节名求值源内固定解码函数；页面文本作为 decode 参数。',
    243: '求值源内播放配置；页面值随后拼入浏览器地址，浏览器调用须另行复核。',
    733: '固定打包代码求值源内开关，页面文本用于 HTML 解析。',
    3432: '求值固定打包规则；网络请求结果传入 HTML 解析，不传入 eval。',
    1160: '固定打包代码求值源内繁简字典；网页仅作解析和替换输入。',
    1195: '源内 variableComment 定义固定字符替换；bookSourceComment 为说明文字。',
    1671: '求值源内签名及请求构造代码；bookId 非引号模板应另行复核。',
    1787: '固定打包代码求值源内繁简字典；网页仅作解析和替换输入。',
    1788: '固定打包代码求值源内配置及繁简字典；网页值用于解析和地址构造。',
    3466: '求值源内固定开关；网页作为 HTML 解析或选择器数据。',
    3551: '求值源内固定开关；网页作为 HTML 解析或选择器数据。',
    3552: '求值源内固定开关；网页作为 HTML 解析或选择器数据。',
    4829: '固定打包代码求值源内繁简字典；网页仅作解析和替换输入。',
    4415: '求值源内固定字符替换表；页面文本作为替换数据。',
    4497: '求值源内固定图字替换表；页面正文作为替换数据。',
    4509: '求值源内固定图字替换表；页面正文作为替换数据。',
    4828: '求值源内繁简转换函数和字典；页面文本作为函数参数。',
    3943: '求值源内 loginUrl；登录响应经 JSON.parse 取字段并保存变量，未见作为 eval 参数。',
    4481: '求值源内固定字体替换表；发现请求响应送 HTML 解析，未见作为 eval 参数。',
}

EVAL = re.compile(r'\beval\s*\(', re.I)
LOCAL_EVAL = re.compile(
    r'eval\s*\(\s*String\s*\(\s*source\s*\.\s*'
    r'(?:bookSourceComment|variableComment|loginUrl)\s*\)\s*\)', re.I,
)
PACKED = re.compile(
    r"return p\}\(('(?:\\.|[^'\\])*'),(\d+),(\d+),"
    r"('(?:\\.|[^'\\])*')\.split\('\|'\),0,\{\}\)\)"
)
PACKED_IDS = {733, 1160, 1787, 1788, 4829}


def digest(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def token(number, base):
    alphabet = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
    if not 2 <= base <= len(alphabet):
        raise ValueError('unsupported literal-packer radix')
    return (token(number // base, base) if number >= base else '') + alphabet[number % base]


def substitute_literals(payload, base, count, words):
    if len(payload) > 16384 or count > 256 or len(words) > 256:
        raise ValueError('packed literal exceeds audit bounds')
    for number in reversed(range(count)):
        if number < len(words) and words[number]:
            pattern = r'\b' + re.escape(token(number, base)) + r'\b'
            payload = re.sub(pattern, lambda _: words[number], payload)
    return payload


def unpack_constant(value):
    match = PACKED.search(value)
    if match is None:
        raise ValueError('expected fixed literal packer not found')
    # Only Python string literals matched from a digest-pinned field are parsed;
    # ast.literal_eval does not interpret or run the contained JavaScript.
    payload = ast.literal_eval(match.group(1))
    words = ast.literal_eval(match.group(4)).split('|')
    return substitute_literals(payload, int(match.group(2)), int(match.group(3)), words)


def assert_local_eval(value, index, field):
    count = 0
    for match in EVAL.finditer(value):
        if LOCAL_EVAL.match(value, match.start()) is None:
            raise ValueError(f'unreviewed eval argument in {index} {field}')
        count += 1
    return count


def checked_fields(row, index, expected_digest, extras):
    available = dict(strings(row))
    paths = sorted({key for key, value in available.items() if EVAL.search(value)} | set(extras))
    if not paths or any(path not in available for path in paths):
        raise ValueError(f'checked field missing: {index}')
    hashes = {path: digest(available[path]) for path in paths}
    aggregate = digest('\n'.join(path + '\t' + hashes[path] for path in paths))
    if aggregate != expected_digest:
        raise ValueError(f'checked field digest changed: {index}')
    for path, tokens in CHECKS[index].items():
        if path not in hashes or any(token not in available[path] for token in tokens):
            raise ValueError(f'expected data-flow marker missing: {index} {path}')
    unpacked = []
    for path in paths:
        value = available[path]
        if not EVAL.search(value):
            continue
        if index in PACKED_IDS and 'eval(function(' in value:
            plain = unpack_constant(value)
            count = assert_local_eval(plain, index, path)
            unpacked.append({'field': path, 'expanded_sha256': digest(plain), 'local_eval_count': count})
        elif index == 3432 and path == 'ruleSearch.bookList':
            match = re.search(r'var O=(\[.*?\]);eval\(', value)
            if match is None:
                raise ValueError('expected fixed array packer not found')
            array = json.loads(match.group(1))
            plain = substitute_literals(array[0], 50, 50, array[3].split('|'))
            if 'Jsoup.parse(java.ajax(b))' not in plain or EVAL.search(plain):
                raise ValueError('record 3432 decoded data flow changed')
            unpacked.append({'field': path, 'expanded_sha256': digest(plain), 'local_eval_count': 0})
        else:
            assert_local_eval(value, index, path)
    return hashes, unpacked


def reviewed_profiles(rows, imported):
    parsed, selected = selected_indices(rows, imported)
    if set(REVIEWED) != set(CHECKS) or set(REVIEWED) != set(FLOWS):
        raise ValueError('manual review tables do not match')
    profiles = []
    for index, (expected_id, expected_digest, extras) in REVIEWED.items():
        source = parsed.get(index)
        if source is None or source['id'] != expected_id or selected.get(expected_id) != index:
            raise ValueError(f'selected source identity changed: {index}')
        hashes, unpacked = checked_fields(rows[index], index, expected_digest, extras)
        profiles.append({
            'source_id': expected_id,
            'name': source['name'],
            'kind': source['kind'],
            'host': source['host'],
            'selected_record_index': index,
            'review_group': 'additional_source_metadata_review' if index in (3943, 4481) else 'supplemental_eval_review',
            'classification': 'local_code_only_observed',
            'recommendation': 'no_quarantine_based_only_on_this_eval_evidence',
            'data_flow_summary': FLOWS[index],
            'checked_field_set_sha256': expected_digest,
            'checked_fields': [{'field': path, 'field_sha256': value} for path, value in hashes.items()],
            'packed_literal_checks': unpacked,
        })
    return profiles


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('imported', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    rows, _, _, _, manifest = inventory(CATALOG)
    imported_bytes = args.imported.read_bytes()
    imported = json.loads(imported_bytes)
    if imported['archive_sha256'] != manifest['archiveSha256']:
        raise ValueError('import inventory must match the bundled archive')
    profiles = reviewed_profiles(rows, imported)
    output = {
        'archive_sha256': manifest['archiveSha256'],
        'import_inventory_sha256': hashlib.sha256(imported_bytes).hexdigest(),
        'scope': ('Static snapshot review of eval arguments and named related fields only; '
                  'no source rule or remote script executed. Not a safety or availability assessment.'),
        'source_profiles': profiles,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'{len(profiles)} selected IDs reviewed; output: {args.output}')


if __name__ == '__main__':
    main()
