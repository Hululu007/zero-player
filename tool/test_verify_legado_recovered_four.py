import copy
import json
import unittest

from tool import verify_legado_recovered_four as recovered
from tool import verify_legado_unresolved_943 as later


class RecoveredFourEvidenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.context,cls.head,cls.prior=recovered.inputs()
        cls.amsi=json.loads(recovered.OUTPUT.read_text(encoding='utf8'))
        cls.head_evidence=json.loads(later.OUTPUT.read_text(encoding='utf8'))

    def test_originals(self):
        self.assertEqual(later.verify(self.head_evidence,self.context)['http_status_unrecorded'],939)
        result=recovered.verify(self.amsi,self.context,self.head,self.prior)
        self.assertEqual(result,{'hosts':4,'html_not_detected':3,'connection_failure':1,'inline_not_detected':4})

    def test_head_population_id_or_dns_tampering_rejected(self):
        changed=copy.deepcopy(self.head_evidence);changed['results'][0]['host']='other.example'
        with self.assertRaisesRegex(ValueError,'evidence changed'):later.verify(changed,self.context)
        changed=copy.deepcopy(self.head_evidence);changed['results'][0]['record_indices']=[0]
        with self.assertRaisesRegex(ValueError,'evidence host'):later.verify(changed,self.context,pinned=False)
        changed=copy.deepcopy(self.head_evidence)
        target=next(r for r in changed['results'] if r['dns']['observations'])
        target['dns']['verdict']='not_checked'
        with self.assertRaisesRegex(ValueError,'DNS verdict'):later.verify(changed,self.context,pinned=False)

    def test_engine_controls_failure_and_sources_remain_distinct(self):
        changed=copy.deepcopy(self.amsi);changed['amsi']['controls']['eicar']['amsi_result']=1
        with self.assertRaises(ValueError):recovered.verify(changed,self.context,self.head,self.prior,pinned=False)
        changed=copy.deepcopy(self.amsi)
        failed=next(r for r in changed['amsi']['results'] if 'amsi' not in r)
        failed['failure']='not_detected'
        with self.assertRaisesRegex(ValueError,'unscanned'):recovered.verify(changed,self.context,self.head,self.prior,pinned=False)
        changed=copy.deepcopy(self.amsi);changed['amsi']['results'][0]['selected_source_ids']=['0'*64]
        with self.assertRaisesRegex(ValueError,'identity'):recovered.verify(changed,self.context,self.head,self.prior,pinned=False)

    def test_followup_and_privacy_tampering_rejected(self):
        changed=copy.deepcopy(self.amsi)
        changed['registry_and_old_path_followup']['old_paths'][0]['http_status']=200
        with self.assertRaisesRegex(ValueError,'old-path'):recovered.verify(changed,self.context,self.head,self.prior,pinned=False)
        changed=copy.deepcopy(self.amsi);changed['shared_template']['fresh_root_gets'][0]['sample_sha256']='0'*64
        with self.assertRaisesRegex(ValueError,'shared-template'):recovered.verify(changed,self.context,self.head,self.prior,pinned=False)
        changed=copy.deepcopy(self.amsi);changed['additional']='192.0.2.1'
        with self.assertRaisesRegex(ValueError,'IP address'):recovered.verify(changed,self.context,self.head,self.prior,pinned=False)


if __name__=='__main__':unittest.main()
