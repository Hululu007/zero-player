"""Build or verify four recovered-host AMSI and static follow-up observations."""
import argparse
from collections import Counter
from datetime import datetime
import ipaddress
import json
from pathlib import Path
import re

try:
    from . import verify_legado_unresolved_943 as headcheck
    from .verify_legado_recovered_amsi import _scan_result
except ImportError:
    import verify_legado_unresolved_943 as headcheck
    from verify_legado_recovered_amsi import _scan_result

ROOT=headcheck.ROOT
OUTPUT=ROOT/'docs/implementation/legado-recovered-four-amsi-20261116.json'
HEAD=ROOT/'docs/implementation/legado-unresolved-943-recheck-20261116.json'
HEAD_SHA='9925c34398debb413de438d0ac6a709c8b41f1abc7be26365bec1319ce0e23e0'
PRIOR_AMSI=ROOT/'docs/implementation/legado-recovered-amsi-20261116.json'
PRIOR_AMSI_SHA='050c6913ab5dacd607c68a369206e46ac30bdd226f6729ef6a5c1cb5c3bc6dcc'
BASELINE=ROOT/'build/book-source-recovered-four-baseline.json'
BASELINE_SHA='9d7d6c776218cfba31aa8c2ba0cb68b7d1dc12d2296b2efb54b0c4118429e21e'
COLLECTION=ROOT/'build/book-source-recovered-four-amsi.json'
COLLECTION_SHA='8fc2d9f982efa25e8dfaf0c26b7ab0803d5b0c3abb10f53c5bb6babaa46672d5'
FOLLOWUP=ROOT/'build/legado_recovered_four_audit_20261116/followup-redacted.json'
FOLLOWUP_SHA='07e4b31f7b7cccf841551bac48729291f675daf14e81e6bdbb12a98776a89728'
TEMPLATE='2a3a28951d5ad48ee8c6bf8ae5bf9667f11e452837ed6c6de3c9d889d05622d7'
CANONICAL_SHA='cafaa10e42cf468d5967edcf29e97f0cac7ffcb6018f5d7ec6f9cfbe1ab317d3'
HOSTS={
 'm.wcxsw.com':(1347,'842d8d69430d3ce91907eff2887f470e68d146284c59171fe349a5b30fd63cc4'),
 'p.jiugangbi.com':(4837,'4e92fa59a858e6a620045f20862de78e1dbf752e8d9d2b58221421326df8add2'),
 'www.mumumh.com':(3466,'09e92e62859b1171da90310ed28f1985e224e4d9dbf371720d4a00e8bc63862a'),
 'www.nidedizhi1.com':(4560,'546ed179fed46c6cc05454b5fd6d827f12badb8bdce82eadc0b233f1bcbed62b'),
}


def require(value,reason):
    if not value:raise ValueError(reason)


def when(value):
    value=datetime.fromisoformat(value.replace('Z','+00:00'))
    require(value.utcoffset() is not None,'timestamp lacks timezone')
    return value


def inputs():
    context=headcheck.inputs();head_bytes=HEAD.read_bytes();prior_bytes=PRIOR_AMSI.read_bytes()
    require(headcheck.sha(head_bytes)==HEAD_SHA and headcheck.sha(prior_bytes)==PRIOR_AMSI_SHA,'historical evidence changed')
    head=json.loads(head_bytes);headcheck.verify(head,context)
    prior=json.loads(prior_bytes)
    previous=next(r for r in prior['results'] if r['host']=='roum26.xyz')
    require(previous['sample_sha256']==TEMPLATE and previous['sample_bytes']==4730,'prior shared sample changed')
    return context,head,previous


def baseline(head):
    rows=[{'host':r['host'],'record_indices':r['record_indices']} for r in head['results']
          if r['latest_head']['http_status']==200]
    require(len(rows)==4 and {r['host'] for r in rows}==set(HOSTS),'HEAD-200 population changed')
    return {'archive_sha256':headcheck.ARCHIVE_SHA,'results':rows}


def root_observations(previous):
    # Transcribed from the read-only tool output. No response bodies were saved.
    return {'sample_sha256':TEMPLATE,'sample_bytes':4730,'prior_different_host':{
      'evidence':'legado-recovered-amsi-20261116.json','host':'roum26.xyz',
      'observed_at':previous['sample_observed_at'],'sample_sha256':previous['sample_sha256']},
      'fresh_root_gets':[
        {'host':'www.mumumh.com','observed_at':'2026-11-16T01:01:35.772673+00:00','http_status':200,'sample_sha256':TEMPLATE},
        {'host':'www.nidedizhi1.com','observed_at':'2026-11-16T01:01:40.941939+00:00','http_status':200,'sample_sha256':TEMPLATE},
        {'host':'www.mumumh.com','observed_at':'2026-11-16T01:02:16.078536+00:00','http_status':200,'sample_sha256':TEMPLATE}],
      'static_summary':{'title_empty':True,'heading_contains_domain_expiry_notice':True,
                        'heading_mentions_namecheap_auctions':True,'script_tags':3,
                        'external_scripts_not_fetched':2,'same_host_anchors':0,'external_anchors_not_followed':8},
      'limitations':['Same bytes across three hosts in one network do not identify the source of the page or establish common ownership.',
                     'The expired-registration heading is page text and conflicts with the two matching registry objects; it is not a registry finding.',
                     'Page bodies and the transient root comparison collector were not retained; observations cannot be independently reconstructed offline.']}


def build(amsi_bytes,baseline_bytes,followup_bytes,head,previous):
    require(headcheck.sha(amsi_bytes)==COLLECTION_SHA and headcheck.sha(baseline_bytes)==BASELINE_SHA and
            headcheck.sha(followup_bytes)==FOLLOWUP_SHA,'collector bytes changed')
    expected=baseline(head)
    reconstructed=json.dumps(expected,ensure_ascii=False).encode()+b'\r\n'
    require(reconstructed==baseline_bytes and headcheck.sha(reconstructed)==BASELINE_SHA,'AMSI sampling baseline mismatch')
    amsi=json.loads(amsi_bytes);followup=json.loads(followup_bytes)
    require(amsi['archive_sha256']==headcheck.ARCHIVE_SHA and amsi['prior_audit_sha256']==BASELINE_SHA and
            amsi['import_inventory_sha256']==headcheck.INVENTORY_SHA,'AMSI provenance mismatch')
    return {'schema_version':1,
            'input_references':{'head':{'path':'docs/implementation/legado-unresolved-943-recheck-20261116.json','sha256':HEAD_SHA},
                                'archive':{'path':headcheck.ARCHIVE,'sha256':headcheck.ARCHIVE_SHA},
                                'import_inventory':{'path':headcheck.INVENTORY,'sha256':headcheck.INVENTORY_SHA},
                                'prior_amsi':{'path':'docs/implementation/legado-recovered-amsi-20261116.json','sha256':PRIOR_AMSI_SHA}},
            'local_collector_sha256':{'amsi_baseline':BASELINE_SHA,'amsi_results':COLLECTION_SHA,'followup':FOLLOWUP_SHA},
            'amsi':amsi,'shared_template':root_observations(previous),'registry_and_old_path_followup':followup,
            'limitations':['Three bounded HTML scans and one connection failure do not establish full-host or whole-site safety.',
                           'The raw EICAR control was detected, while HTML-wrapped and inline-script test controls were missed; scanner non-detection is not a security verdict.',
                           'Installed AMSI providers may use their existing cloud protection or sample submission; the tool did not submit credentials or bookcase data.',
                           'Registry responses and old discovery paths are time-limited; JS search and POST search were not attempted and other categories were not tested.',
                           'Registry status_indicators are a predefined subset; an empty list does not establish that the domain has no other registry statuses.',
                           'The HTML bodies, registry response bodies, registration contacts, network IPs and transient collectors are not retained; offline checks verify retained metadata and identities, not authenticity of the historical network observations.']}


def _verify_amsi(data,head):
    expected=baseline(head);rows=data['results'];by_head={r['host']:r for r in head['results']}
    require(data['total_hosts']==data['requested_hosts']==len(rows)==4 and data['offset']==0 and
            data['workers']==2 and data['max_html_bytes']==32768 and data['max_inline_scripts_per_page']==6 and
            data['max_inline_script_bytes']==8192 and {r['host'] for r in rows}==set(HOSTS), 'AMSI bounds or hosts changed')
    wire=json.dumps(expected,ensure_ascii=False).encode()+b'\r\n'
    require(headcheck.sha(wire)==data['prior_audit_sha256']==BASELINE_SHA,'AMSI baseline changed')
    controls=data['controls']
    for key in ('negative','eicar','html_wrapped_eicar','inline_script_with_eicar'):_scan_result(controls[key])
    require(controls['passed'] is True and [controls[k]['classification'] for k in
            ('negative','eicar','html_wrapped_eicar','inline_script_with_eicar')]==
            ['not_detected','detected','not_detected','not_detected'],'AMSI control results changed')
    counts=Counter();scripts=Counter();truncated=0
    require(len({r['host'] for r in rows})==4,'duplicate AMSI host')
    for row in rows:
        host=row['host'];index,ident=HOSTS[host];prior=by_head[host]
        require(row['record_indices']==[index] and row['selected_source_ids']==[ident] and
                prior['selected_sources']==[{'source_id':ident,'record_index':index}] and
                when(row['started_at'])>=when(prior['latest_head']['observed_at']) and
                when(row['sample_observed_at'])>=when(row['started_at']), 'AMSI identity or time mismatch')
        if 'amsi' not in row:
            require(row.get('failure')=='connection_error' and 'http_status' not in row,'unscanned result changed')
            counts['connection_error']+=1;continue
        require(row['http_status']==200 and row['content_type']=='text/html' and row['truncated'] is False and
                0<row['sample_bytes']<=32768 and re.fullmatch(r'[0-9a-f]{64}',row['sample_sha256']), 'invalid HTML sample')
        _scan_result(row['amsi']);counts[row['amsi']['classification']]+=1;truncated+=row['truncated']
        inline=row['inline_scripts'];selected=inline['samples']
        require(inline['inline_scripts_selected']==len(selected) and
                inline['nonempty_inline_scripts_observed']==len(selected)+inline['inline_scripts_omitted'], 'inline count mismatch')
        for item in selected:
            require(0<item['sample_bytes']<=8192 and item['truncated'] is False and
                    re.fullmatch(r'[0-9a-f]{64}',item['sample_sha256']), 'invalid inline sample')
            _scan_result(item['amsi']);scripts[item['amsi']['classification']]+=1
    require(dict(counts)==data['outcomes']=={'not_detected':3,'connection_error':1} and
            dict(scripts)==data['inline_script_outcomes']=={'not_detected':4} and truncated==0,'AMSI summary mismatch')
    return {'hosts':4,'html_not_detected':3,'connection_failure':1,'inline_not_detected':4}


def _verify_followup(followup,head,context):
    require(followup['method']['source_scripts_executed'] is False and followup['method']['post_sent'] is False and
            followup['method']['body_saved'] is False and followup['method']['ip_saved'] is False,'follow-up method changed')
    negative=followup['negative_control_domain']
    require(re.fullmatch(r'zp-rdap-[0-9a-f]{20}\.com',negative) is not None,'invalid registry control')
    rounds=followup['registry_rounds'];require(len(rounds)==2,'registry round count changed')
    for n,run in enumerate(rounds,1):
        controls=run['controls'];candidates=run['candidates']
        require(run['round']==n and run['controls_passed'] is True and len(controls)==len(candidates)==2 and
                [(r['domain'],r['classification']) for r in controls]==
                [('google.com','matching_domain_object'),(negative,'http_404_empty_body')] and
                {r['domain'] for r in candidates}=={'mumumh.com','nidedizhi1.com'} and
                all(r['http_status']==200 and r['classification']=='matching_domain_object' and
                    r['rdap_object_matches'] is True for r in candidates),'registry observations changed')
    paths=followup['old_paths'];require(len(paths)==4,'old-path sample count changed')
    observed={(p['round'],p['host']):p for p in paths}
    for host,path in [('www.mumumh.com','/rank'),('www.nidedizhi1.com','/sort/3/1/')]:
        index,ident=HOSTS[host]
        for n in (1,2):
            item=observed[(n,host)]
            require(item['source_id']==ident and item['path']==path and item['http_status']==404 and
                    item['failure']=='http_status' and item['sample_sha256'] is None, 'old-path observation changed')
    import bz2
    raw=json.loads(bz2.decompress((ROOT/headcheck.ARCHIVE).read_bytes()))['records']
    require('人气榜::/rank' in raw[3466]['exploreUrl'] and
            '言情小说::/sort/3/{{page}}/' in raw[4560]['exploreUrl'] and
            '<js>' in raw[3466]['searchUrl'] and 'POST' in raw[4560]['searchUrl'],
            'historical paths or unexecuted search modes changed')


def verify(evidence,context,head,previous,*,pinned=True):
    if pinned and CANONICAL_SHA is not None:
        require(headcheck.sha(headcheck.canonical(evidence))==CANONICAL_SHA,'evidence changed')
    require(evidence['schema_version']==1 and evidence['input_references']['head']['sha256']==HEAD_SHA and
            evidence['input_references']['prior_amsi']['sha256']==PRIOR_AMSI_SHA and
            evidence['input_references']['archive']['sha256']==headcheck.ARCHIVE_SHA and
            evidence['input_references']['import_inventory']['sha256']==headcheck.INVENTORY_SHA, 'evidence references changed')
    report=_verify_amsi(evidence['amsi'],head);_verify_followup(evidence['registry_and_old_path_followup'],head,context)
    require(evidence['shared_template']==root_observations(previous),'shared-template observation changed')
    wire=headcheck.canonical(evidence).decode('utf8')
    require('?' not in wire and '<script' not in wire.lower() and not re.search(r'https?://',wire,re.I), 'page code or URL query retained')
    for text in re.findall(r'(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)',wire):
        try:ipaddress.ip_address(text)
        except ValueError:continue
        raise ValueError('IP address retained')
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--build',action='store_true');args=parser.parse_args()
    context,head,previous=inputs()
    if args.build:
        data=build(COLLECTION.read_bytes(),BASELINE.read_bytes(),FOLLOWUP.read_bytes(),head,previous)
        verify(data,context,head,previous,pinned=False)
        OUTPUT.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
        print(json.dumps({'path':str(OUTPUT),'sha256':headcheck.sha(OUTPUT.read_bytes()),'canonical_sha256':headcheck.sha(headcheck.canonical(data))}))
    else:
        raw=OUTPUT.read_bytes();result=verify(json.loads(raw),context,head,previous)
        print(json.dumps({'sha256':headcheck.sha(raw),'verified_summary':result,'raw_pages_reconstructed':False},ensure_ascii=False))


if __name__=='__main__':main()
