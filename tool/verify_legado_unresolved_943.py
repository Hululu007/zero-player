"""Build or verify the redacted later 943-host HEAD recheck without network."""
import argparse
import bz2
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess

try:
    from . import recheck_legado_failures as retry
    from .verify_legado_unresolved_head import _dns_observation, _dns_verdict, _host
except ImportError:
    import recheck_legado_failures as retry
    from verify_legado_unresolved_head import _dns_observation, _dns_verdict, _host

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'docs/implementation/legado-unresolved-943-recheck-20261116.json'
PRIOR = 'docs/implementation/legado-unresolved-head-later-20261116.json'
PRIOR_SHA = '3024ff03581b0de4b286601188974e05cd8f7cf602b8af49e234ce054d2a6ebd'
ARCHIVE = 'assets/catalogs/books/legado/catalog.json.bz2'
ARCHIVE_SHA = '012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d'
INVENTORY = 'docs/implementation/legado-import-inventory-20261115.json'
INVENTORY_SHA = 'ad4e347888cad71812ee7da9477f027baf0bee5bceb1d4247fc69d6c4df8764c'
LEDGER = 'docs/implementation/legado-source-ledger-20261115.json'
COMMIT = '7c9e02eb84738b07cfeb47a6d08ade74ccfa4d00'
LEDGER_SHA = 'ec0f211055eb8a18c1b9c0db0496a3b0653519c9abeccb387bec1f1d3c90624d'
BASELINE = ROOT / 'build/book-source-unresolved-baseline-latest.json'
COLLECTION = ROOT / 'build/book-source-unresolved-recheck-20261116-later.json'
BASELINE_SHA = '6f981cdeb2134d5fe46a9a36975f8a1d6f9c1beb37c5fc93e32a8a23cbabe98e'
COLLECTION_SHA = '20c6b47cfa3a6c653fb5036124a8b235b3cf65e4ede956d5437dddaf7ca9034e'
CANONICAL_SHA = '161905ec2edfc5739cd8639c61e7934dec54bfb1428b2c58ebbf099deccc9e99'
FAILURES = {'connection_or_read_timeout', 'dns_host_not_found', 'non_public_dns_rejected',
            'connection_error', 'tls_error', 'dns_timeout', 'dns_no_data'}


def require(value, reason):
    if not value:raise ValueError(reason)


def sha(value):return hashlib.sha256(value).hexdigest()
def canonical(value):return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode('utf8')


def inputs():
    prior_bytes=(ROOT/PRIOR).read_bytes(); archive=(ROOT/ARCHIVE).read_bytes()
    inventory_bytes=(ROOT/INVENTORY).read_bytes()
    ledger_bytes=subprocess.check_output(['git','show',f'{COMMIT}:{LEDGER}'],cwd=ROOT)
    require(sha(prior_bytes)==PRIOR_SHA and sha(archive)==ARCHIVE_SHA and
            sha(inventory_bytes)==INVENTORY_SHA and sha(ledger_bytes)==LEDGER_SHA,
            'previous evidence, archive, inventory or historical ledger changed')
    prior=json.loads(prior_bytes);ledger=json.loads(ledger_bytes);inventory=json.loads(inventory_bytes)
    require(prior['archive_sha256']==inventory['archive_sha256']==ARCHIVE_SHA and
            ledger['input_sha256'][ARCHIVE]==ARCHIVE_SHA and
            ledger['input_sha256'][PRIOR]==PRIOR_SHA, 'historical references changed')
    rows=json.loads(bz2.decompress(archive))['records']
    old={r['host']:r for r in prior['results'] if r['latest_head']['http_status'] is None}
    require(len(old)==943, 'previous unresolved population changed')
    selected={r['source_id']:r for r in ledger['sources']}
    inventory_ids={r['id'] for r in inventory['selected_sources']}
    for host,row in old.items():
        _host(host)
        for source in row['selected_sources']:
            ident,index=source['source_id'],source['record_index'];record=selected[ident]
            require(ident in inventory_ids and record['endpoint_host']==host and
                    record['selected_record_index']==index and index in row['record_indices'] and
                    sha(canonical(rows[index]))==record['selected_raw_record_canonical_sha256'],
                    'historical selected-source association changed')
    return {'prior':prior,'population':old,'selected':selected}


def summary(rows):
    return {'hosts':len(rows),'selected_source_ids':len({s['source_id'] for r in rows for s in r['selected_sources']}),
            'http_status_recorded':sum(r['latest_head']['http_status'] is not None for r in rows),
            'http_status_unrecorded':sum(r['latest_head']['http_status'] is None for r in rows),
            'http_200':sum(r['latest_head']['http_status']==200 for r in rows),
            'latest_classifications':dict(sorted(Counter(r['latest_head']['classification'] for r in rows).items())),
            'dns_verdicts':dict(sorted(Counter(r['dns']['verdict'] for r in rows).items()))}


def references():
    return {'archive':{'path':ARCHIVE,'sha256':ARCHIVE_SHA},
            'previous_head':{'path':PRIOR,'sha256':PRIOR_SHA},
            'import_inventory':{'path':INVENTORY,'sha256':INVENTORY_SHA},
            'historical_ledger':{'git_commit':COMMIT,'path':LEDGER,'sha256':LEDGER_SHA}}


def build(baseline_bytes, raw_bytes, context):
    require(sha(baseline_bytes)==BASELINE_SHA and sha(raw_bytes)==COLLECTION_SHA,'collector bytes changed')
    baseline=json.loads(baseline_bytes);raw=json.loads(raw_bytes);previous=context['population']
    require(baseline['archive_sha256']==raw['archive_sha256']==ARCHIVE_SHA and
            baseline['prior_formal_sha256']==PRIOR_SHA and
            baseline['prior_local_recheck_sha256']==context['prior']['local_collector_sha256']['recheck'] and
            raw['first_audit_sha256']==BASELINE_SHA and raw['import_inventory_sha256']==INVENTORY_SHA and
            raw['sample_html'] is False and raw['selected_source_count']==2139, 'collector provenance changed')
    base={r['host']:r for r in baseline['results']}; records={r['host']:r for r in raw['results']}
    require(len(base)==len(baseline['results'])==943 and len(records)==len(raw['results'])==943 and
            set(base)==set(records)==set(previous), 'collector host population changed')
    result=[]
    for host in sorted(previous):
        prior=previous[host];record=records[host];old=prior['latest_head'];b=base[host];new=record['recheck']
        require(b['observed_at']==old['observed_at'] and b['classification']==old['classification'] and
                record['previous']=={'observed_at':b['observed_at'],'error':b['error'],'classification':b['classification']} and
                record['record_indices']==prior['record_indices'] and
                sorted(record['selected_source_ids'])==sorted(x['source_id'] for x in prior['selected_sources']) and
                new['host']==host and new['classification']==retry.classification(new),
                'collector source or observation mismatch')
        status=new.get('status');verdict=record.get('dns_verdict','not_checked')
        dns=[_dns_observation(row) for row in record.get('dns_observations',[])]
        require((not dns and verdict=='not_checked') or (dns and verdict==_dns_verdict(dns)), 'collector DNS verdict mismatch')
        result.append({'host':host,'record_indices':prior['record_indices'],'selected_sources':prior['selected_sources'],
                       'prior_head':{'observed_at':old['observed_at'],'classification':old['classification']},
                       'latest_head':{'observed_at':new['observed_at'],'http_status':status,'classification':new['classification']},
                       'dns':{'verdict':verdict,'observations':dns}})
    counts=summary(result)
    require(raw['summary']['hosts']==counts['hosts'] and raw['summary']['source_ids_covered']==counts['selected_source_ids'] and
            raw['summary']['recheck_classifications']==counts['latest_classifications'] and
            raw['summary']['dns_verdicts']==counts['dns_verdicts'], 'collector summary mismatch')
    return {'schema_version':1,'generated_at_utc':raw['generated_at'],
            'method':{'http':'HTTPS HEAD /; no redirects or HTML GET','dns':'Windows DnsQuery_W A/AAAA, bypass cache and hosts',
                      'timeout_seconds':raw['timeout_seconds'],'body_saved':False,'ip_addresses_saved':False,
                      'redirect_targets_saved':False},
            'input_references':references(),'local_collector_sha256':{'baseline':BASELINE_SHA,'recheck':COLLECTION_SHA},
            'limitations':['HTTP status and lack of status are time-limited observations, not safety or permanent availability conclusions.',
                           'All requests share this client and network; later DNS checks may share caches.',
                           'DNS failures and unspecified addresses are not automatically classed as permanent source failure.',
                           'The raw local collectors and error strings are not retained in the repository; new observations cannot be independently replayed offline.',
                           'Source identity refers to the archived selected record, not personal installation or settings.'],
            'summary':counts,'results':result}


def verify(evidence,context,*,pinned=True):
    if pinned and CANONICAL_SHA is not None:require(sha(canonical(evidence))==CANONICAL_SHA,'evidence changed')
    require(evidence['schema_version']==1 and evidence['input_references']==references() and
            evidence['local_collector_sha256']=={'baseline':BASELINE_SHA,'recheck':COLLECTION_SHA}, 'evidence provenance changed')
    rows=evidence['results'];by_host={r['host']:r for r in rows};old=context['population']
    require(len(rows)==len(by_host)==943 and set(by_host)==set(old),'evidence population changed')
    for host,row in by_host.items():
        before=old[host];head=row['latest_head'];previous=before['latest_head'];dns=row['dns']
        require(row['record_indices']==before['record_indices'] and row['selected_sources']==before['selected_sources'] and
                row['prior_head']=={'observed_at':previous['observed_at'],'classification':previous['classification']},
                'evidence host, ID or prior observation changed')
        require((head['http_status']==200 and head['classification']=='http_200') or
                (head['http_status'] is None and head['classification'] in FAILURES), 'HEAD status/classification changed')
        observations=dns['observations']
        require((not observations and dns['verdict']=='not_checked') or
                (observations and dns['verdict']==_dns_verdict(observations)), 'DNS verdict changed')
    actual=summary(rows)
    require(actual==evidence['summary'] and (actual['hosts'],actual['selected_source_ids'],
            actual['http_status_recorded'],actual['http_status_unrecorded'],actual['http_200'])==(943,908,4,939,4),
            'summary changed')
    return actual


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--build',action='store_true');args=parser.parse_args()
    context=inputs()
    if args.build:
        evidence=build(BASELINE.read_bytes(),COLLECTION.read_bytes(),context);verify(evidence,context,pinned=False)
        OUTPUT.write_text(json.dumps(evidence,ensure_ascii=False,separators=(',',':'))+'\n',encoding='utf8')
        print(json.dumps({'path':str(OUTPUT),'sha256':sha(OUTPUT.read_bytes()),'canonical_sha256':sha(canonical(evidence))}))
    else:
        raw=OUTPUT.read_bytes();result=verify(json.loads(raw),context)
        print(json.dumps({'sha256':sha(raw),'verified_summary':result,'raw_network_observations_reconstructed':False},ensure_ascii=False))


if __name__=='__main__':main()
