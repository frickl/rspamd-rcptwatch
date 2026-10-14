"""Run only against an isolated Redis instance, never production Redis."""
import os
from pathlib import Path
import unittest
try:
    import redis
except ImportError:
    redis = None
SCRIPT = (Path(__file__).resolve().parents[1] / 'redis' / 'record.lua').read_text()

@unittest.skipUnless(redis is not None and os.getenv('OUTGUARD_TEST_REDIS_URL'),
                     'Install redis-py and set OUTGUARD_TEST_REDIS_URL for an isolated Redis')
class TestRedis(unittest.TestCase):
    def setUp(self):
        self.r = redis.Redis.from_url(os.environ['OUTGUARD_TEST_REDIS_URL'], decode_responses=True)
        self.prefix = 'outguard:test:'
        self.clear()

    def tearDown(self):
        self.clear()

    def clear(self):
        for k in self.r.scan_iter(match=self.prefix + '*'):
            self.r.delete(k)

    def record(self, user, *hashes, limit=2):
        base = self.prefix + user
        return self.r.eval(SCRIPT, 4, base + ':z', base + ':h', base + ':alert',
                           self.prefix + 'metrics', 21600, limit, 21600, *hashes)

    def test_repeated_recipients_and_cooldown(self):
        self.assertEqual(self.record('a', 'r1'), [1, 1, 0, 1])
        self.assertEqual(self.record('a', 'r1'), [1, 0, 0, 2])
        self.assertEqual(self.record('a', 'r2', 'r3'), [3, 2, 1, 1])
        self.assertEqual(self.record('a', 'r4'), [4, 1, 0, 1])
        self.assertEqual(int(self.r.hget(self.prefix+'a:h', 'r1')), 2)
        self.assertEqual(self.r.hget(self.prefix+'metrics', 'alerts'), '1')
        self.assertEqual(self.record('b', 'r1'), [1, 1, 0, 1])

    def test_stale_recipient_removed(self):
        self.record('a', 'r1')
        self.r.zadd(self.prefix + 'a:z', {'r1': 1})
        self.assertEqual(self.record('a', 'r2'), [1, 1, 0, 1])
        self.assertIsNone(self.r.hget(self.prefix + 'a:h', 'r1'))

    def test_deduplicated_input_contract(self):
        # Rspamd callback deduplicates recipient hashes BEFORE calling Redis.
        self.assertEqual(self.record('a', 'r1', 'r2'), [2, 2, 0, 1])
