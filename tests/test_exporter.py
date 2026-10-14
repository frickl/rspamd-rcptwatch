import unittest
from prometheus.export_textfile import render

class TestExporter(unittest.TestCase):
    def test_values_no_personal_labels(self):
        text = render({'messages': '7', 'recipients': '21', 'alerts': '1'}, True)
        self.assertIn('outguard_messages_total 7', text)
        self.assertIn('outguard_new_relationships_total 0', text)
        self.assertIn('outguard_redis_up 1', text)
        self.assertNotIn('auth_user', text)
