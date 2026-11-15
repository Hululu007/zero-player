import unittest

from tool.audit_legado_response_eval import candidate_fields


class ResponseEvalScanTest(unittest.TestCase):
    def test_recurses_and_hashes_code_without_treating_metadata_as_a_rule(self):
        record = {
            'ruleContent': {'content': '@js: eval(String(result))'},
            'bookSourceComment': 'eval(result)',
            'ruleSearch': {'bookList': 'result without an evaluation'},
            'ruleToc': {'chapterList': 'eval(source.bookSourceComment)'},
            'ruleExplore': {'bookList': 'data = java.getString("$.x"); eval(data)'},
        }
        fields = candidate_fields(record)
        self.assertEqual(
            {row['field'] for row in fields},
            {'ruleContent.content', 'bookSourceComment', 'ruleExplore.bookList'},
        )
        metadata = next(row for row in fields if row['field'] == 'bookSourceComment')
        self.assertTrue(metadata['metadata'])
        self.assertEqual(len(metadata['sha256']), 64)


if __name__ == '__main__':
    unittest.main()
