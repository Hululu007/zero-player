"""Validate and finalize collected DoH observations without any DNS/network."""

import argparse
import hashlib
import json
from pathlib import Path

if __package__:
    from . import audit_legado_doh_full as collector
    from . import audit_legado_doh_pilot as probe
    from . import classify_legado_doh as classify
    from . import verify_legado_doh as verifier
else:
    import audit_legado_doh_full as collector
    import audit_legado_doh_pilot as probe
    import classify_legado_doh as classify
    import verify_legado_doh as verifier


OUTPUT = Path('docs/implementation/legado-doh-reviewed-20261115.json')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--collection', type=Path, default=collector.OUTPUT)
    parser.add_argument('--output', type=Path, default=OUTPUT)
    parser.add_argument('--finalized-at', help='reuse an existing UTC timestamp for byte-for-byte reproduction')
    args = parser.parse_args()
    evidence, evidence_hash = probe.read_data(args.collection)
    head, head_hash = probe.read_data(probe.INPUT1)
    addresses, address_hash = probe.read_data(probe.INPUT2)
    pilot, pilot_hash = probe.read_data(collector.PILOT)
    verifier.verify(evidence, head, head_hash, addresses, address_hash, pilot, pilot_hash)
    hosts = collector.groups(head, addresses)
    observations = {(row['host'], value['provider'], value['query_type']):
                    {**value, 'host': row['host'], 'baseline': row['baseline']}
                    for row in evidence['results'] for value in row['observations']}
    evidence['collection_evidence_sha256'] = evidence_hash
    evidence['summary_method'] = 'valid_dns_responses_only_for_disagreement'
    evidence['summary_note'] = ('Provider disagreement requires two usable DNS answers for the same record type; '
                                'timeout, blocked transport, SERVFAIL and truncated replies are counted separately as errors.')
    evidence['summary_generator_sha256'] = hashlib.sha256(Path(classify.__file__).read_bytes()).hexdigest()
    evidence['summary'] = classify.summarize(hosts, observations)
    evidence['summary_finalized_at'] = args.finalized_at or probe.utc()
    verifier.verify(evidence, head, head_hash, addresses, address_hash, pilot, pilot_hash)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(evidence['summary'], ensure_ascii=False))


if __name__ == '__main__':
    main()
