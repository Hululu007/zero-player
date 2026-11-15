"""Offline DoH aggregation that separates provider disagreement from errors."""

from collections import Counter

if __package__:
    from . import audit_legado_doh_pilot as probe
else:
    import audit_legado_doh_pilot as probe


VALID = {'nxdomain', 'noerror_addresses', 'noerror_no_address'}


def summarize(hosts, observations):
    result = {}
    for group in ('repeated_nxdomain', 'repeated_unspecified'):
        items = [entry for entry in hosts.values() if entry['baseline'] == group]
        unique_ids = {ident for entry in items for ident in entry['selected_source_ids']}
        queries, flags = Counter(), Counter()
        for entry in items:
            rows = [observations[(entry['host'], provider, typ)]
                    for provider in probe.PROVIDERS for typ in probe.TYPES]
            queries.update(row['classification'] for row in rows)
            if all(row['classification'] in VALID for row in rows):
                flags['all_four_dns_responses_usable'] += 1
            if all(row['classification'] == 'nxdomain' for row in rows):
                flags['both_providers_nxdomain_for_a_and_aaaa'] += 1
            has_public = {provider: any(row['provider'] == provider and
                                        row.get('address_categories', {}).get('public') for row in rows)
                          for provider in probe.PROVIDERS}
            if any(has_public.values()):
                flags['at_least_one_provider_public_address'] += 1
            if all(has_public.values()):
                flags['both_providers_public_address'] += 1
            if any(row['classification'] not in VALID for row in rows):
                flags['one_or_more_dns_or_transport_errors'] += 1
            disagreement = False
            for typ in probe.TYPES:
                pair = [row for row in rows if row['query_type'] == typ]
                if all(row['classification'] in VALID for row in pair):
                    categories = {(row['classification'], tuple(sorted(row.get('address_categories', {}))))
                                  for row in pair}
                    disagreement |= len(categories) > 1
            if disagreement:
                flags['valid_provider_category_disagreement'] += 1
        result[group] = {'hosts': len(items), 'selected_source_ids': len(unique_ids),
                         'query_classifications': dict(queries), 'host_observations': dict(flags)}
    return result
