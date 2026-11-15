"""Offline tests for static text extraction used in the targeted recheck."""

import unittest

from tool import recheck_two_book_homes as audit


class StaticTextTests(unittest.TestCase):
    def test_hidden_script_and_description_are_separate_from_visible_text(self):
        html = ('<html><head><title>写真</title><meta name="description" content="普通写真">'
                '<meta name><script>在线博彩 成人漫画</script></head><body>'
                '<div hidden>在线博彩</div><div style="display:none">成人漫画</div>'
                '<div>美女写真</div></body></html>').encode()
        result = audit.inspect_html(html)
        self.assertEqual(result['title'], '写真')
        self.assertEqual(result['descriptions'], ['普通写真'])
        self.assertEqual(result['visible_text_clues']['adult_explicit'], [])
        self.assertEqual(result['visible_text_clues']['gambling'], [])
        self.assertTrue(result['visible_text_clues']['photography_or_sexy'])

    def test_gambling_and_adult_words_include_context_as_clues(self):
        result = audit.inspect_html('<body>请远离赌博平台，成年人应谨慎</body>'.encode())
        clues = result['visible_text_clues']['gambling']
        self.assertEqual(clues[0]['word'], '赌博平台')
        self.assertIn('远离', clues[0]['excerpt'])


if __name__ == '__main__':
    unittest.main()
