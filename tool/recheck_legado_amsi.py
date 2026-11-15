"""Recheck one previously AMSI-detected catalog root without saving content."""

import argparse
import base64
import binascii
import hashlib
import http.client
import json
from pathlib import Path
import re
from urllib.parse import urlsplit

if __package__:
    from . import audit_legado_amsi as audit
    from .audit_legado_amsi import controls, extract_inline_scripts, failure_category, fetch_root, now, save, scan_many_in_worker
else:
    import audit_legado_amsi as audit
    from audit_legado_amsi import controls, extract_inline_scripts, failure_category, fetch_root, now, save, scan_many_in_worker


def structural_indicators(payload, scripts):
    # Construct this harmless test marker in memory, never in full in a file.
    marker = b'X5O!P%@AP[4\\PZX54(P^)7CC)7}' + b'$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
    script_text = b'\n'.join(body for _, body in scripts).lower()
    return {
        'complete_eicar_control_present': marker in payload,
        'eicar_word_present_case_insensitive': b'eicar' in payload.lower(),
        'contains_404_text': b'404' in payload,
        'meta_refresh_pattern_present': bool(re.search(rb'<meta\b[^>]*http-equiv\s*=\s*["\']?refresh', payload, re.I)),
        'iframe_tag_present': bool(re.search(rb'<iframe(?:\s|>)', payload, re.I)),
        'script_location_reference_present': bool(re.search(rb'\b(?:window\s*\.\s*)?location\b', script_text)),
        'script_eval_reference_present': bool(re.search(rb'\beval\s*\(', script_text)),
        'script_base64_decode_reference_present': bool(re.search(rb'\batob\s*\(', script_text)),
        'script_document_write_reference_present': bool(re.search(rb'\bdocument\s*\.\s*write\s*\(', script_text)),
        'external_script_attribute_present': bool(re.search(rb'<script\b[^>]*\bsrc\s*=', payload, re.I)),
    }


def decode_atob_literals(scripts):
    """Decode only bounded literal base64 arguments; never interpret JavaScript."""
    pattern = re.compile(rb'\batob\s*\(\s*(["\'])([A-Za-z0-9+/=]{1,4096})\1\s*\)', re.I)
    samples, seen, invalid = [], 0, 0
    for meta, body in scripts:
        for match in pattern.finditer(body):
            seen += 1
            try:
                raw = match.group(2)
                decoded = base64.b64decode(raw + b'=' * (-len(raw) % 4), validate=True)
                if not decoded:
                    invalid += 1
                    continue
            except (ValueError, binascii.Error):
                invalid += 1
                continue
            if len(samples) < 4:
                lower = decoded.lower().strip()
                url = bool(re.search(rb'https?://[^\s"\'<>]+', lower))
                nav = bool(re.search(rb'(?:window\s*\.\s*)?location\s*(?:\.|=|\[)', lower))
                script = bool(re.search(rb'<script\b|\beval\s*\(|\bfunction\s*\(|\bdocument\s*\.', lower))
                executable = lower.startswith((b'mz', b'\x7felf', b'#!'))
                is_text = all((32 <= c < 127) or c in (9, 10, 13) for c in decoded)
                category = ('http_url_text' if url else 'script_or_html_text' if script or nav
                            else 'text' if is_text else 'binary_or_non_ascii')
                info = {'script_ordinal': meta['ordinal'], 'decoded_bytes': len(decoded),
                        'decoded_sha256': hashlib.sha256(decoded).hexdigest(), 'category': category,
                        'contains_http_url': url, 'contains_navigation_syntax': nav,
                        'contains_script_syntax': script, 'executable_file_magic': executable}
                samples.append((info, decoded))
    return {'literal_calls_observed': seen, 'invalid_or_empty_literals': invalid,
            'decoded_values_selected': len(samples),
            'omitted_values': max(0, seen - invalid - len(samples)),
            'limitation': 'Only direct quoted base64 arguments in selected script prefixes are decoded; no variables, concatenation, escapes, code execution or network requests.'}, samples


def template_digest(payload, host):
    normalized = re.sub(re.escape(host.encode('ascii')), b'<host>', payload, flags=re.I)
    normalized = re.sub(rb'(\batob\s*\(\s*["\'])[A-Za-z0-9+/=]{1,4096}(["\']\s*\))',
                        rb'\1<base64>\2', normalized, flags=re.I)
    return {'method': 'Replace exact requested-host text and directly quoted atob base64 arguments; preserve all other bytes.',
            'sha256': hashlib.sha256(normalized).hexdigest()}


def shape_digest(payload, host):
    normalized = re.sub(re.escape(host.encode('ascii')), b'<host>', payload, flags=re.I)
    normalized = re.sub(rb'(["\'])(?:\\.|(?!\1).)*?\1', b'<quoted>', normalized, flags=re.S)
    normalized = re.sub(rb'\b[0-9a-f]{8,}\b', b'<hex>', normalized, flags=re.I)
    normalized = re.sub(rb'\d+', b'<number>', normalized)
    normalized = re.sub(rb'\s+', b' ', normalized).strip()
    return hashlib.sha256(normalized).hexdigest()


def literal_navigation(scripts, original_host):
    """Recognize direct quoted location assignments/calls, never evaluate JS."""
    assignment = re.compile(
        rb'\blocation(?:\s*\.\s*href)?\s*=\s*(["\'])([^"\'\\\r\n]{1,2048})\1\s*(?=[;}\r\n]|$)', re.I)
    call = re.compile(
        rb'\blocation\s*\.\s*(?:assign|replace)\s*\(\s*(["\'])([^"\'\\\r\n]{1,2048})\1\s*\)', re.I)
    references, targets = 0, []
    for meta, body in scripts:
        references += len(re.findall(rb'\blocation\b', body, re.I))
        for pattern in (assignment, call):
            for match in pattern.finditer(body):
                scheme, path_kind, has_query = None, None, None
                try:
                    value = match.group(2).decode('ascii')
                    parts = urlsplit(value)
                    scheme = parts.scheme.lower() or None
                    has_query = bool(parts.query)
                    path_kind = 'root_or_empty' if parts.path in ('', '/') else 'other_path'
                    if parts.username is not None or parts.password is not None:
                        category, host = 'credentials_present_not_reported', None
                    elif parts.hostname and parts.scheme.lower() in ('', 'http', 'https'):
                        category, host = 'http_or_protocol_relative', parts.hostname.lower().rstrip('.')
                    elif not parts.scheme and value.startswith('/') and not value.startswith('//'):
                        category, host = 'relative_path', original_host
                    else:
                        category, host = 'other_or_unparsed', None
                except (UnicodeError, ValueError):
                    category, host = 'other_or_unparsed', None
                targets.append({'script_ordinal': meta['ordinal'], 'category': category,
                                'target_host_defanged': host.replace('.', '[.]') if host else None,
                                'target_host_sha256': hashlib.sha256(host.encode()).hexdigest() if host else None,
                                'target_host_is_source': host == original_host if host else None,
                                'scheme': scheme, 'path_kind': path_kind, 'has_query': has_query})
    return {'location_mentions': references, 'direct_constant_targets': targets,
            'limitation': 'Only direct unescaped quoted assignments and assign/replace calls in scanned script prefixes; concatenated or computed values remain unconfirmed and no target is requested.'}


def fetch_with_identity(host):
    """Capture verified TLS identity from the same connection as the GET."""
    original, identity = audit.sample_response, {}
    def capture(connection, requested_host, limit):
        certificate = connection.getpeercert()
        issuer = [value for group in certificate.get('issuer', ()) for key, value in group
                  if key in ('organizationName', 'commonName')]
        remote = connection.getpeername()[0]
        identity.update({'tls_verified': True, 'connected_ip_sha256': hashlib.sha256(remote.encode('ascii')).hexdigest(),
                         'tls_certificate_sha256': hashlib.sha256(connection.getpeercert(binary_form=True)).hexdigest(),
                         'tls_issuer': issuer, 'tls_not_before': certificate.get('notBefore'),
                         'tls_not_after': certificate.get('notAfter')})
        return original(connection, requested_host, limit)
    audit.sample_response = capture
    try:
        return (*fetch_root(host, 8), identity)
    finally:
        audit.sample_response = original


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prior-scan', type=Path, required=True)
    parser.add_argument('--host', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    raw = args.prior_scan.read_bytes()
    prior = json.loads(raw)
    candidates = [x for x in prior['results'] if x['host'] == args.host and
                  (x.get('amsi', {}).get('classification') == 'detected' or
                   any(s['amsi']['classification'] == 'detected'
                       for s in x.get('inline_scripts', {}).get('samples', [])))]
    if len(candidates) != 1:
        raise ValueError('host must have an exact prior AMSI detection')
    original = candidates[0]
    result = {'host': args.host, 'record_indices': original['record_indices'],
              'selected_source_ids': original['selected_source_ids'],
              'prior_result_file_sha256': hashlib.sha256(raw).hexdigest(),
              'prior_sample_sha256': original.get('sample_sha256'), 'started_at': now(),
              'method': 'Fresh bounded anonymous HTTPS root GET; public DNS fixed IP; no redirects, credentials, scripts or subresources. Static patterns and AMSI scan in memory only.',
              'limitations': 'Indicators are clues, not a malware verdict; absence of a marker does not prove safety. AMSI may use provider cloud protection.',
              'controls': controls()}
    if not result['controls']['passed']:
        result['failure'] = 'amsi_controls_failed_no_network_requests'
        save(args.output, result)
        return
    try:
        fetched, payload, connection_identity = fetch_with_identity(args.host)
        result.update(fetched)
        result['connection_identity'] = connection_identity
        result['sample_observed_at'] = now()
        if payload:
            stats, scripts = extract_inline_scripts(payload)
            result['same_sha256_as_prior'] = result['sample_sha256'] == original.get('sample_sha256')
            result['structural_indicators'] = structural_indicators(payload, scripts)
            result['literal_navigation'] = literal_navigation(scripts, args.host)
            result['normalized_template'] = template_digest(payload, args.host)
            result['shape_sha256'] = shape_digest(payload, args.host)
            decode_stats, decoded_samples = decode_atob_literals(scripts)
            if decoded_samples:
                decoded_scans = scan_many_in_worker([body for _, body in decoded_samples])
            else:
                decoded_scans = []
            result['static_atob'] = {**decode_stats, 'decoded_samples': [
                {**meta, 'amsi': scan} for (meta, _), scan in zip(decoded_samples, decoded_scans)]}
            selected = scripts[:2]
            width = max(1, (len(payload) + 3) // 4)
            chunks = [(offset, payload[offset:offset + width]) for offset in range(0, len(payload), width)]
            scans = scan_many_in_worker([payload] + [s for _, s in selected] + [s for _, s in chunks])
            result['amsi'] = scans[0]
            result['inline_scripts'] = {**stats, 'scanned_samples': [
                {**meta, 'shape_sha256': shape_digest(body, args.host), 'amsi': scan}
                for (meta, body), scan in zip(selected, scans[1:1 + len(selected)])]}
            result['bounded_segment_scans'] = [
                {'offset': offset, 'sample_bytes': len(chunk), 'sample_sha256': hashlib.sha256(chunk).hexdigest(),
                 'amsi': scan} for (offset, chunk), scan in zip(chunks, scans[1 + len(selected):])]
    except (OSError, ValueError, http.client.HTTPException) as error:
        result['failure'] = failure_category(error)
        result['sample_observed_at'] = now()
    result['completed_at'] = now()
    save(args.output, result)
    print(json.dumps({'host': args.host, 'amsi': result.get('amsi'),
                      'indicators': result.get('structural_indicators'), 'failure': result.get('failure')}))


if __name__ == '__main__':
    main()
