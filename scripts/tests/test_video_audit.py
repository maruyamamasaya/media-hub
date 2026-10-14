import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('video_audit', Path(__file__).parents[1] / 'audit-video-storage.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class VideoAuditTests(unittest.TestCase):
    def test_audio_inclusive_units_and_storage_break_even(self):
        totals = {'durationSeconds': 600, 'measuredBytes': 1_500_000_000}
        result = audit.estimate(totals, 3, 1/6, 150, .10, .025, .114)
        self.assertAlmostEqual(result['additionalStorageGiB'] * audit.GIB, 247_500_000)
        self.assertAlmostEqual(result['deliveryGiB'] * audit.GIB, 247_500_000)
        self.assertGreater(result['netMonthlySavingsJPY'], 0)

    def test_small_original_can_cost_more(self):
        result = audit.estimate({'durationSeconds': 600, 'measuredBytes': 60_000_000}, 3, 1, 150, .10, .025, .114)
        self.assertLess(result['netMonthlySavingsJPY'], 0)

    def test_missing_duration_is_not_free_savings(self):
        result = audit.estimate({'durationSeconds': 0, 'measuredBytes': 0}, 3, 10, 150, .10, .025, .114)
        self.assertIsNone(result['netMonthlySavingsJPY'])
        self.assertIsNone(audit.positive_number('NaN'))
