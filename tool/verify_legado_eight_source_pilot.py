"""Verify the redacted eight-source evidence offline; no network or local samples."""
import bz2
import hashlib
import ipaddress
import json
from pathlib import Path
import re
import subprocess
from functools import lru_cache

ROOT=Path(__file__).resolve().parents[1]
OUTPUT=ROOT/'docs/implementation/legado-eight-source-pilot-20261116.json'
COMMIT='dfb4c9cb71fd6de1607bcbf8ca427ef4361ca307'
LEDGER='docs/implementation/legado-source-ledger-20261115.json'
LEDGER_SHA='cca374595f6d9fb79477032d5268737051fd813bed996131b205dbccaaeb4f17'
ARCHIVE='assets/catalogs/books/legado/catalog.json.bz2'
ARCHIVE_SHA='012a0e0d6e6adc8d303c32b578510e14b562088b3e965cb01a1a647b5e7e034d'
INVENTORY='docs/implementation/legado-import-inventory-20261115.json'
INVENTORY_SHA='ad4e347888cad71812ee7da9477f027baf0bee5bceb1d4247fc69d6c4df8764c'
RISK='lib/features/books/domain/book_source_risk.dart'
LATER_RISK_SHA='96d56f4a01b80073ea52269320b7a3a22461aff7fa9a60ca25495c6744c35efc'
CANONICAL_SHA='f6cf238328f3e74352d4b946e2c0752bda111a74550dea7ae6cbafaa65b531b6'
COLLECTED={
 'observations-redacted.json':'ee40a792323876481050f04b9f88dbfaebc16f88489bb0a85b3f88199c4da887',
 'focused-gulong-redacted.json':'0fd75fbb6fd2a489ff9a831afb26c01aa3e0ab15f3c2355eee9bc5a4cf0ca604',
 'focused-shubang-redacted.json':'936f2ebb5c57309dedc7be8c587c0190043e1ca85b9fb1fccb67b68ae38f4643',
 'focused-sanyou-redacted.json':'91fd0ea652cb5bed56075898b9a447de53509eb27a0f8ebd6ac6099a910de4d6',
 'discovery-407-redacted.json':'0e117d036c9233ab53e9fa00e699713467de9af923139597d1cd86eabc94a019',
}
SOURCES={
 407:('fa42526b9412d5c4431acbd60ab169b7e68e7b2fe008da412e8b8da8310bc877','m.dmxso.com'),
 1399:('c7f3f35a20b48cf4fb02cb92f6714b08c96d97adb6bfd50a24adc0d3d21d7b20','www.wucuoxs.com'),
 3134:('bc379d9cf7ee312a6d9813e14830fdc689be5b2371fa025529586fc3a67aec1d','www.3uxiaoshuo.com'),
 4371:('22fd5687b4cd8b42ce1d69d0701148e989f39833d7d94b1e1dae73795084e242','www.bsxiaoshuo.com'),
 3954:('0e51322b309496dd36b4388cc7dcbc156c06e32bff52d1d6a9878794877003d0','m.gulongbbs.com'),
 1056:('981adf7639a1c61e23ad4104e4e11b3553439b9ea22599c1b429881ace889402','www.shubang.net'),
 3817:('52a7d590143c8fd5168b42ff3681a8bd473d0cbd3b53810d527047294a9e8ba8','wenxue.bkneng.com'),
 4491:('5ff498ddb51371e132e6b35fa505eaa7ddb0b989213814eda0a79cf3cd119747','www.zzrx.net'),
}
MISSING_RISK_DEPENDENCIES=[
 'lib/features/books/domain/com_rdap_legacy_quarantine.dart',
 'lib/features/books/domain/iqiyi_legacy_quarantine.dart',
 'lib/features/books/domain/moe_rdap_legacy_quarantine.dart',
 'lib/features/books/domain/net_rdap_legacy_quarantine.dart',
 'lib/features/books/domain/novel_242_legacy_quarantine.dart',
 'lib/features/books/domain/redirected_legacy_quarantine.dart',
 'lib/features/books/domain/taotaoshu_legacy_quarantine.dart',
 'lib/features/books/domain/top_rdap_legacy_quarantine.dart',
]


def require(value,reason):
    if not value:raise ValueError(reason)


def sha(value):return hashlib.sha256(value).hexdigest()
def canonical(value):return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode('utf8')


@lru_cache(maxsize=None)
def git_blob(path):
    return subprocess.check_output(['git','show',f'{COMMIT}:{path}'],cwd=ROOT,stderr=subprocess.DEVNULL)


def selected_indices(rows,inventory):
    parsed={item['index']:item for item in inventory['raw_parseable']}
    selected={};versions={}
    for references in inventory['pack_references'].values():
        for index in references:
            source=parsed.get(index)
            if source is None:continue
            raw=str(rows[index].get('lastUpdateTime',''))
            stamp=int(raw) if re.fullmatch(r'[+-]?\d+',raw) else 0
            ident=source['id']
            if ident not in versions or stamp>versions[ident]:
                selected[ident]=index;versions[ident]=stamp
    for chosen in inventory['selected_sources']:
        actual=parsed[selected[chosen['id']]]
        require(all(actual[k]==chosen[k] for k in ('id','name','group','host','kind')),
                'inventory selection changed')
    return selected


def inputs():
    archive=(ROOT/ARCHIVE).read_bytes();inventory=(ROOT/INVENTORY).read_bytes();ledger=git_blob(LEDGER)
    require(sha(archive)==ARCHIVE_SHA and sha(inventory)==INVENTORY_SHA and sha(ledger)==LEDGER_SHA,
            'historical ledger, archive or inventory changed')
    rows=json.loads(bz2.decompress(archive))['records']; imported=json.loads(inventory);historical=json.loads(ledger)
    require(historical['input_sha256'][ARCHIVE]==ARCHIVE_SHA and imported['archive_sha256']==ARCHIVE_SHA,
            'historical archive association changed')
    selected=selected_indices(rows,imported)
    sources={r['source_id']:r for r in historical['sources']}
    return {'rows':rows,'selected':selected,'sources':sources}


def historical_snapshot(recorded):
    result=[]
    for path,digest in sorted(recorded.items()):
        if not path.startswith(('lib/','tool/','assets/')):continue
        blob=git_blob(path);exact=sha(blob)==digest
        crlf=(b'\r\n' not in blob and sha(blob.replace(b'\n',b'\r\n'))==digest)
        require(exact or crlf,'recorded file does not match historical source: '+path)
        result.append({'path':path,'sample_bytes_sha256':digest,'git_blob_sha256':sha(blob),
                       'checkout_bytes':'identical' if exact else 'git_lf_to_crlf'})
    require(len(result)==38,'recorded historical file count changed')
    return result


def verify(draft,context,*,pinned=True):
    if pinned and CANONICAL_SHA is not None:require(sha(canonical(draft))==CANONICAL_SHA,'evidence changed')
    refs=draft['inputs'];require(draft['status']=='formal_initial_git_bound_later_policy_digest_unbound' and
        refs['archive_path']==ARCHIVE and refs['archive_sha256']==ARCHIVE_SHA and
        refs['inventory_path']==INVENTORY and refs['inventory_sha256']==INVENTORY_SHA and
        refs['historical_ledger_path']==LEDGER and refs['historical_git_commit']==COMMIT and
        refs['historical_ledger_sha256']==LEDGER_SHA and
        refs['local_redacted_intermediate_sha256']==COLLECTED,'draft input reference changed')
    method=draft['method']
    require(method['public_dns_validation_and_ip_pinning'] is True and
        method['tls_verification'] is True and method['follow_redirect'] is False and
        method['execute_scripts'] is False and method['send_credentials'] is False and
        method['submit_post'] is False and method['load_subresources'] is False and
        method['body_limit_bytes']==524288 and method['worker_hard_deadline_seconds']==15,
        'sampling method changed')
    initial=draft['sampled_source_snapshots']['initial']['tracked_files']
    reconstructed=historical_snapshot({x['path']:x['sample_bytes_sha256'] for x in initial})
    require(initial==reconstructed,'historical recorded source snapshot changed')
    later=draft['sampled_source_snapshots']['later']
    require(later['git_commit'] is None and later['full_runtime_snapshot_reconstructable'] is False and
        later['uncaptured_risk_direct_dependencies']==MISSING_RISK_DEPENDENCIES and
        later['recorded_tracked_files_sha256'][RISK]==LATER_RISK_SHA,'later scope or dependency limit changed')
    old={x['path']:x['sample_bytes_sha256'] for x in initial};current=later['recorded_tracked_files_sha256']
    require(set(old)==set(current) and all(old[k]==current[k] for k in old if k!=RISK) and old[RISK]!=current[RISK],
            'recorded source difference changed')
    sources={s['index']:s for s in draft['sources']};require(len(draft['sources'])==len(sources)==8 and set(sources)==set(SOURCES),'draft source set changed')
    for index,(ident,host) in SOURCES.items():
        item=sources[index];row=context['rows'][index];prior=context['sources'][ident]
        require(item['id']==ident and item['host']==host and context['selected'][ident]==index and
            prior['selected_record_index']==index and prior['endpoint_host']==host and
            item['endpoint_sha256']==prior['endpoint_sha256'] and
            item['historical_legado_canonical_sha256']==prior['normalized_legado_canonical_sha256'] and
            item['raw_record_canonical_sha256']==prior['selected_raw_record_canonical_sha256']==sha(canonical(row)),
            'historical source identity or fingerprint changed')
        fields=item['raw_field_sha256']
        require(set(fields)=={'searchUrl','ruleSearch','ruleBookInfo','ruleToc','ruleContent'},
                'raw rule field set changed')
        for key,digest in fields.items():
            value=row.get(key);require(digest==sha(value.encode() if isinstance(value,str) else canonical(value)),
                                      'raw rule field changed')
    first={x['index']:x for x in draft['initial']['observations']}
    require(len(draft['initial']['observations'])==len(first)==8 and set(first)==set(SOURCES) and len(draft['followups'])==4,'observation coverage changed')
    for index,item in first.items():
        require((item['id'],item['host'])==SOURCES[index] and len(item['steps'])==1,'first sample identity changed')
    require([first[i]['steps'][0]['observation']['http_status'] for i in (407,3817,4491)]==[404]*3,
            'historical 404 observations changed')
    require([first[i]['steps'][0]['observation']['http_status'] for i in (1399,3134,4371,3954,1056)]==[200]*5,
            'historical 200 observations changed')
    later={x['index']:x for x in draft['followups']};require(set(later)=={3954,1056,3134,407},'follow-up coverage changed')
    for index,observation in later.items():
        require((observation['id'],observation['host'])==SOURCES[index], 'follow-up source identity changed')
    for index,counts in [(3954,(11,8,32,3025)),(1056,(8,8,75,2001))]:
        result=later[index];steps=result['steps'];search=steps[0]['analysis']
        detail=next(x['analysis'] for x in steps if x['observation']['phase']=='detail')
        toc=next((x['analysis'] for x in steps if x['observation']['phase']=='toc'),detail)
        content=next(x['analysis'] for x in steps if x['observation']['phase']=='content')
        require(result['outcome']=='one_content_sample' and all(x['observation']['http_status']==200 for x in steps) and
                (search['book_count'],search['query_matches'],toc['toc_chapter_count'],content['content_characters'])==counts,
                'bounded reading observation changed')
    require([x['observation']['http_status'] for x in later[407]['steps']]==[404,404] and
            later[3134]['steps'][0]['analysis']['book_count']==0,'focused discovery or search changed')
    wire=canonical(draft).decode('utf8')
    require('?' not in wire and not re.search(r'https?://|<script',wire,re.I),'URL, query or page script retained')
    for v in re.findall(r'(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)',wire):
        try:ipaddress.ip_address(v)
        except ValueError:continue
        raise ValueError('IP address retained')
    return {'sources':8,'initial_404':3,'one_work_chain_samples':2,'network_requests':0,
            'later_complete_runtime_reconstructable':False}


def main():
    raw=OUTPUT.read_bytes()
    result=verify(json.loads(raw),inputs())
    print(json.dumps({'sha256':sha(raw),'verified_summary':result,
                      'network_pages_reconstructed':False,
                      'temporary_collectors_required':False},ensure_ascii=False))


if __name__=='__main__':main()
