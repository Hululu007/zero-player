import copy
import json
import unittest
from pathlib import Path
from unittest.mock import patch

from tool import verify_legado_eight_source_pilot as verifier


class EightSourcePilotEvidenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.context=verifier.inputs()
        cls.draft=json.loads(verifier.OUTPUT.read_text(encoding='utf8'))

    def test_original_evidence(self):
        result=verifier.verify(self.draft,self.context)
        self.assertEqual(result['sources'],8)
        self.assertEqual(result['one_work_chain_samples'],2)
        self.assertFalse(result['later_complete_runtime_reconstructable'])
        later=result['later_risk_single_file_git_match']
        self.assertEqual(later['matching_git_commit'],verifier.LATER_RISK_MATCHING_COMMIT)
        self.assertEqual(later['sha256'],verifier.LATER_RISK_SHA)
        self.assertTrue(later['matching_object_identified_after_sampling'])
        self.assertIsNone(later['complete_runtime_git_commit'])
        self.assertFalse(later['complete_runtime_reconstructed'])

    def test_later_risk_single_git_file_tampering_rejected(self):
        with patch.object(verifier,'git_blob_at',return_value=b'changed file'):
            with self.assertRaisesRegex(ValueError,'later risk single-file Git object mismatch'):
                verifier.verify_later_risk_single_file()

    def test_identity_and_sampled_rules_tampering_rejected(self):
        changed=copy.deepcopy(self.draft);changed['sources'][0]['id']='0'*64
        with self.assertRaisesRegex(ValueError,'historical source identity'):
            verifier.verify(changed,self.context,pinned=False)
        changed=copy.deepcopy(self.draft);changed['sources'][0]['sampled_rules']['search_sha256']='0'*64
        with self.assertRaisesRegex(ValueError,'evidence changed'):
            verifier.verify(changed,self.context)
        changed=copy.deepcopy(self.draft);changed['sources'][0]['raw_field_sha256']['ruleBookInfo']='0'*64
        with self.assertRaisesRegex(ValueError,'raw rule field'):
            verifier.verify(changed,self.context,pinned=False)

    def test_404_and_reading_observations_not_promoted(self):
        changed=copy.deepcopy(self.draft)
        next(x for x in changed['initial']['observations'] if x['index']==407)['steps'][0]['observation']['http_status']=200
        with self.assertRaisesRegex(ValueError,'historical 404'):
            verifier.verify(changed,self.context,pinned=False)
        changed=copy.deepcopy(self.draft)
        next(x for x in changed['followups'] if x['index']==3954)['steps'][-1]['analysis']['content_characters']=9999
        with self.assertRaisesRegex(ValueError,'bounded reading observation'):
            verifier.verify(changed,self.context,pinned=False)

    def test_source_scope_and_privacy_cannot_be_silently_weakened(self):
        changed=copy.deepcopy(self.draft)
        changed['sampled_source_snapshots']['later']['uncaptured_risk_direct_dependencies'].pop()
        with self.assertRaisesRegex(ValueError,'later scope'):
            verifier.verify(changed,self.context,pinned=False)
        changed=copy.deepcopy(self.draft);changed['extra']='192.0.2.1'
        with self.assertRaisesRegex(ValueError,'IP address'):
            verifier.verify(changed,self.context,pinned=False)
        changed=copy.deepcopy(self.draft);changed['extra']='https://example.invalid/?token=x'
        with self.assertRaisesRegex(ValueError,'URL, query'):
            verifier.verify(changed,self.context,pinned=False)

    def test_offline_without_build_artifacts(self):
        original=Path.read_bytes
        def read_without_build(path):
            if 'build' in path.parts:
                raise AssertionError('unexpected dependency on build artifacts')
            return original(path)
        with patch.object(Path,'read_bytes',read_without_build), \
             patch('socket.create_connection',side_effect=AssertionError('network access')):
            data=json.loads(verifier.OUTPUT.read_bytes())
            result=verifier.verify(data,verifier.inputs())
        self.assertEqual(result['sources'],8)


if __name__=='__main__':unittest.main()
