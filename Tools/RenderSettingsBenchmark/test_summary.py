"""計測値が揃っていても、検証失敗を成功扱いしない。"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent


def successful_log():
    """実測ログに依存しない固定の入力。外れ値を含め、平均値との取り違えも検出する。"""
    lines = []
    for sample, elapsed in enumerate([10, 11, 12, 13, 14, 15, 16, 17, 1000]):
        for layout, duration in [('false', elapsed), ('true', 100)]:
            lines.append(f'RENDER_BENCH layout={layout} sample={sample} rows=500 ms={duration}')
    lines.extend([
        '✔ Test measureRows(layout:) with 2 test cases passed after 0.1 seconds.',
        '** TEST SUCCEEDED **',
    ])
    return '\n'.join(lines) + '\n'


class SummaryTests(unittest.TestCase):
    def run_summary(self, log):
        with tempfile.NamedTemporaryFile(mode='w') as source:
            source.write(log)
            source.flush()
            return subprocess.run(
                [sys.executable, str(ROOT / 'summarize.py'), source.name],
                capture_output=True, text=True, check=False,
            )

    def test_successful_run(self):
        for marker in ['** TEST SUCCEEDED **', '** TEST EXECUTE SUCCEEDED **']:
            with self.subTest(marker=marker):
                result = self.run_summary(successful_log().replace('** TEST SUCCEEDED **', marker))
                self.assertEqual(result.returncode, 0, result.stderr)
                summary = json.loads(result.stdout)
                self.assertEqual(summary['configuration'], {
                    'rows_per_sample': 500,
                    'samples': 9,
                    'median_ms': 14,
                    'range_ms': [10, 1000],
                })
                layout = summary['configuration_and_layout']
                self.assertEqual(layout['median_ms'], 100)
                self.assertEqual(layout['range_ms'], [100, 100])

    def test_rejects_failed_or_interrupted_run_with_complete_measurements(self):
        valid = successful_log()
        for marker in ['** TEST FAILED **', '** TEST INTERRUPTED **', '** TEST EXECUTE FAILED **', '** TEST EXECUTE INTERRUPTED **', '']:
            with self.subTest(marker=marker):
                result = self.run_summary(valid.replace('** TEST SUCCEEDED **', marker))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')

    def test_rejects_missing_measurement_test_success(self):
        log = '\n'.join(line for line in successful_log().splitlines() if 'Test measureRows(' not in line)
        result = self.run_summary(log)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_rejects_duplicate_or_missing_measurements(self):
        valid = successful_log()
        first = next(line for line in valid.splitlines() if 'RENDER_BENCH' in line)
        for log in [valid + first, valid.replace(first, ''), valid + first.replace('sample=0', 'sample=9'), valid.replace('rows=500', 'rows=100')]:
            with self.subTest(log=log[:80]):
                result = self.run_summary(log)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
