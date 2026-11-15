"""Build a compact source audit record from already-collected, sanitized files.

This command is offline. It cannot recreate historical HTML or fetch a site.
Its inputs are intentionally temporary; the resulting JSON is self-contained.
"""
import hashlib
import json
from pathlib import Path

ROOT = Path('build/legado_chain_audit')
OUTPUT = Path('docs/implementation/legado-two-chain-pilot-20261116.json')
INPUTS = ('result.json', 'detail_navigation.json', 'targeted.json',
          'link_diagnostics.json', 'free_chapter.json', 'exact_toc.json', 'source_rules.json')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    files = {name: ROOT / name for name in INPUTS}
    data = {name: json.loads(path.read_text(encoding='utf-8')) for name, path in files.items()}
    initial = data['result.json']
    navigation = data['detail_navigation.json']
    targeted = data['targeted.json']
    diagnostics = data['link_diagnostics.json']
    chapter = data['free_chapter.json']
    exact_toc = data['exact_toc.json']
    sources = data['source_rules.json']
    zh, qs = (source['id'] for source in sources)
    assert len(sources) == 2
    assert [source['preflight']['expected_index'] for source in sources] == [2576, 1246]
    assert all(source['preflight']['eligible'] for source in sources)
    assert all(source['preflight']['rule_sha256'] == old['rule_sha256']
               for source, old in zip(sources, initial['preflight']['checks']))
    observations = []

    def add(observation, uri, stage, limit, phase):
        item = {'source_id': observation['id'], 'host': observation['host'], 'stage': stage,
                'phase': phase, 'method': 'GET', 'uri': uri,
                'started_at': observation['started_at'], 'observed_at': observation['observed_at'],
                'http_status': observation['http_status'], 'content_type': observation.get('content_type'),
                'byte_cap': limit, 'sample_bytes': observation.get('sample_bytes'),
                'truncated': observation.get('truncated'), 'sample_sha256': observation.get('sample_sha256'),
                'failure': observation.get('failure')}
        observations.append(item)

    for item in initial['observations']:
        add(item, item['request_uri'], item['phase'], 524288, 'initial')
    add(navigation['observation'], navigation['request_uri'], 'detail', 524288, 'navigation_recheck')
    for item in targeted['observations']:
        add(item['observation'], item['request_uri'], item['stage'], item['byte_limit'], 'targeted_recheck')
    for item in diagnostics['observations']:
        add(item['observation'], item['uri'], item['stage'], 524288, 'link_diagnostics')
    for item, stage in ((chapter, 'content'), (exact_toc, 'toc')):
        obs = item['observation']
        add(obs, 'https://' + obs['host'] + obs['path_with_empty_query'], stage, 524288, 'exact_empty_query')
    observations.sort(key=lambda item: item['started_at'])
    assert len(observations) == 12 and all(item['http_status'] == 200 for item in observations)
    for index, item in enumerate(observations, 1):
        item['observation_id'] = index

    def analysis(source_id, stage):
        return next(item for item in initial['analysis'] if item['id'] == source_id and item['stage'] == stage)

    z_search, z_detail = analysis(zh, 'search'), analysis(zh, 'detail')
    q_search, q_detail = analysis(qs, 'search'), analysis(qs, 'detail')
    z_toc, z_chapter = exact_toc['analysis'], chapter['analysis']
    assert len(z_search['books']) == 3 and z_toc['toc_chapter_count'] == 50
    assert z_toc['chapter_candidates'][0]['uri'] == 'https://m.zhulang.com/515834/29882.html?'
    assert z_chapter['content_characters'] == 2284 and q_detail['toc_chapter_count'] == 2229
    assert len(q_search['books']) == 20
    for source in sources:
        source['raw_selected_index'] = source['preflight']['expected_index']
        source['static_policy'] = {'adult': source['preflight']['static_adult'],
                                   'quarantined': source['preflight']['static_quarantined']}
        source['rule_sha256'] = source['preflight']['rule_sha256']
        source['search_rule_sha256'] = source['preflight']['search_sha256']
        del source['preflight']
    out = {'schema_version': 1,
           'observation_start_utc': observations[0]['started_at'],
           'observation_end_utc': observations[-1]['observed_at'],
           'method': {'scope': 'Two selected catalog sources, a synthetic search keyword, one selected book per source.',
                      'network': 'Anonymous same-host HTTPS GET with validated public DNS and pinned numeric address, TLS verification; no redirects, cookies, credentials, POST or subresources.',
                      'bounds': '10-second internal deadline and 15-second subprocess deadline; complete HTML at most 512 KiB or 2 MiB as recorded; truncated samples were not parsed.',
                      'parser': 'Current selected Legado sources and actual Dart VM LegadoOperation; no JavaScript engine and no site/source script execution.',
                      'privacy': 'No HTML, chapter body, IP address, user database, local user settings or query token is stored.',
                      'historical_reproducibility': 'Hashes and structured observations can be checked; historical DOM/contents cannot be independently recomputed without reacquiring matching response bytes.',
                      'policy_scope': 'Static source policy only, not user dynamic settings or risk database.'},
           'synthetic_keyword': '三国',
           'input_sha256': {name: digest(path) for name, path in files.items()},
           'source_file_sha256_at_initial': initial['file_sha256'],
           'source_file_sha256_at_followup': targeted['current_file_sha256'],
           'fingerprint_changes_from_initial': targeted['fingerprint_changes_from_prior'],
           'offline_verification': {
               'command': 'dart --packages=.dart_tool/package_config.json tool/verify_legado_two_chain.dart',
               'scope': 'Recompute archive, manifest, selected source IDs, normalized rule strings and their SHA-256; validate the structured observation format. It does not recreate historical page bytes or independently repeat their parsing.',
           },
           'sources': sources,
           'observations': observations,
           'findings': [
               {'source_id': zh, 'selected_book_title': z_search['books'][0]['title'],
                'search': {'parsed_books': len(z_search['books']), 'all_match_keyword': all(b['query_match'] for b in z_search['books']),
                           'old_rule_used': True},
                'detail': {'page_title': z_detail['page_title'], 'description_present': z_detail['details']['description_present'],
                           'old_rule_toc_output': 'https://m.zhulang.com/515834/0/?'},
                'toc': {'old_rule_chapters_first_page': z_toc['toc_chapter_count'],
                        'first_chapter_url': z_toc['chapter_candidates'][0]['uri'],
                        'first_chapter_label': z_toc['chapter_candidates'][0]['title'],
                        'pagination_link_candidates': len(diagnostics['observations'][1]['analysis']['toc_link_diagnostics']),
                        'pagination_query_names': ['p', 'order'], 'pagination_fetched': False},
                'content': {'content_length_utf16_code_units': z_chapter['content_characters'],
                            'content_sha256_utf8': z_chapter['content_sha256_utf8'],
                            'access_gate_signal': z_chapter['access_gate_signal'] or z_chapter['content_gate_signal'],
                            'adult_signal': z_chapter['content_adult_signal'], 'body_saved': False},
                'conclusion': 'One specific search, detail, first TOC page and free-labelled chapter were parsed; other pages and books remain unverified.',
                'repair_guidance': 'No source rule change is justified by this sample. Future diagnostics should preserve empty query delimiters and assess pagination separately.',
                'diagnostic_correction': 'The first probe rejected URLs solely because an empty query delimiter was present; exact empty-query URLs were later fetched and parsed.'},
               {'source_id': qs, 'selected_book_title': q_search['books'][0]['title'],
                'search': {'parsed_books_sample': len(q_search['books']), 'result_reporting_cap': 20,
                           'matching_in_sample': sum(b['query_match'] for b in q_search['books'])},
                'detail': {'page_title': q_detail['page_title'], 'description_present': q_detail['details']['description_present'],
                           'title_can_fall_back_to_search_result': True},
                'toc': {'old_rule_chapters_on_detail_page': q_detail['toc_chapter_count'],
                        'first_chapter_url': q_detail['chapter_candidates'][0]['uri']},
                'content': {'parsed': False, 'limit_rechecks_bytes': [524288, 2097152],
                            'reason': 'Both responses exceeded the stated cap; truncated HTML was not parsed.'},
                'conclusion': 'Search and one detail/TOC sample parsed; one chapter exceeded both limits, so content and a complete reading chain were not established.',
                'repair_guidance': 'Investigate whether a permitted same-site lightweight response exists and repeat with the application request settings before proposing a source-specific repair; do not treat this sample as grounds to raise global limits or bypass access controls.'}],
           'limitations': ['An empty adult-signal field is not an adult-content or malware clearance.',
                           'A response status or one successful chapter does not prove availability, safety or full-book completeness.',
                           'The observed oversized response would exceed the application 2 MiB document limit if the application received the same bytes; different requests may produce different pages.',
                           'Temporary probes and intermediate JSON files under build/ are not included in version control and may be removed; a different checkout cannot independently recompute their checksums or regenerate the historical parsing observations from them.',
                           'The two intermediate book_source_risk.dart workspace snapshots represented by the recorded initial/followup SHA-256 values may not be retained; those hashes do not provide their historical file contents.',
                           'No historical body was stored, so old parsing results are attestations tied to byte hashes rather than independently recomputable DOM evidence.']}
    OUTPUT.write_text(json.dumps(out, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'file': str(OUTPUT), 'sha256': digest(OUTPUT), 'observations': len(observations)}))


if __name__ == '__main__':
    main()
