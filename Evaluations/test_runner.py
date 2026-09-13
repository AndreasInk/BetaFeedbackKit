"""Harness regressions; these tests never run a model."""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
import unittest

from run_image_evals import owned_process, assess_calibration, make_reports, comparison_summary, load_frozen_corpus, CORPUS, ROOT, CONTROLS


class RunnerTests(unittest.TestCase):
    def test_timeout_retains_log_and_terminates_owned_process(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'process.log'
            code, timed_out = owned_process(
                ['python3', '-c', 'import time; print("started",flush=True); time.sleep(30)'],
                os.environ.copy(), log, .15)
            self.assertTrue(timed_out)
            self.assertNotEqual(code, 0)
            self.assertIn('started', log.read_text())

    def test_timeout_stops_child_in_a_different_session(self):
        with tempfile.TemporaryDirectory() as directory:
            heartbeat = Path(directory)/'heartbeat'
            child = 'from pathlib import Path; import time; p=Path('+repr(str(heartbeat))+');\nwhile True: p.write_text(str(time.time())); time.sleep(.02)'
            parent = 'import subprocess,time; subprocess.Popen(["python3","-c",'+repr(child)+'],start_new_session=True); time.sleep(30)'
            _, timed_out = owned_process(['python3','-c',parent],os.environ.copy(),Path(directory)/'log',.5)
            self.assertTrue(timed_out)
            self.assertTrue(heartbeat.exists())
            last = heartbeat.read_text()
            time.sleep(.15)
            self.assertEqual(last,heartbeat.read_text())

    def test_normal_parent_exit_stops_reparented_child(self):
        with tempfile.TemporaryDirectory() as directory:
            heartbeat = Path(directory)/'heartbeat'
            child = 'from pathlib import Path; import time; p=Path('+repr(str(heartbeat))+');\nwhile True: p.write_text(str(time.time())); time.sleep(.02)'
            parent = 'import subprocess,time; subprocess.Popen(["python3","-c",'+repr(child)+'],start_new_session=True); time.sleep(.4)'
            code, timed_out = owned_process(['python3','-c',parent],os.environ.copy(),Path(directory)/'log',2)
            self.assertFalse(timed_out)
            self.assertEqual(code,0)
            last = heartbeat.read_text()
            time.sleep(.15)
            self.assertEqual(last,heartbeat.read_text())

    def test_comparison_uses_only_matched_cases_and_counts_partial_generations(self):
        def row(case,variant,score,status='completed'):
            value = {'job':f'{case}:vague:{variant}','variant':variant,'question':'What happened?',
                     'decisionMatches':True,'status':status}
            if status == 'completed':
                value['judge'] = dict.fromkeys(['usefulness','grounding','ease','askStop'],score)
                value['judge']['hardFailure'] = False
            return value
        records = [row('a','baseline',2),row('a','candidate',3),row('b','baseline',4),
                   row('b','candidate',None,'judging')]
        manifest = {'jobs':[r['job'] for r in records]}
        result = comparison_summary(manifest,records)
        self.assertEqual(result['matchedDecisionPairs'],2)
        self.assertEqual(result['matchedJudgePairs'],1)
        self.assertEqual(result['variants']['baseline']['matchedJudgeMeans']['usefulness'],2)
        self.assertEqual(result['variants']['baseline']['unmatchedJudgments'],1)
        self.assertEqual(result['variants']['candidate']['generated'],2)
        self.assertEqual(result['variants']['candidate']['judged'],1)
        self.assertEqual(result['variants']['candidate']['planned'],2)
        manifest['invalidJobs'] = ['a:vague:candidate']
        self.assertEqual(comparison_summary(manifest,records)['matchedJudgePairs'],0)

    def test_report_uses_saved_corpus_and_rejects_tampering(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            data = b'{"pairs": [{"id": "original"}]}'
            (out/'corpus.json').write_bytes(data)
            manifest = {'sourceHashes': {str(CORPUS.relative_to(ROOT)): hashlib.sha256(data).hexdigest()}}
            self.assertEqual(load_frozen_corpus(out, manifest)['pairs'][0]['id'], 'original')
            (out/'corpus.json').write_text('{"pairs": []}')
            with self.assertRaises(ValueError):
                load_frozen_corpus(out, manifest)

    def test_missing_calibration_is_never_a_pass(self):
        result = assess_calibration([])
        self.assertFalse(result['passed'])
        self.assertIn('advisory', result['authority'])
        self.assertGreaterEqual(len(result['failures']), len(CONTROLS))

    def test_refresh_preserves_human_ratings_and_missing_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            corpus = {'pairs':[{'id':'example','vague':'Unclear','sufficient':'Rename label'}]}
            manifest = {'jobs':['example:vague:baseline'],'attempts':[], 'blindSeed':42}
            make_reports(out,manifest,corpus)
            review = json.loads((out/'blind-review.json').read_text())
            self.assertIsNone(review[0]['A'])
            self.assertIsNone(review[0]['B'])
            review[0]['reason'] = 'My real review'
            (out/'blind-review.json').write_text(json.dumps(review))
            (out/'example--vague--baseline.json').write_text(json.dumps({
                'job':'example:vague:baseline','variant':'baseline','status':'judging',
                'question':'What was unclear?','decisionMatches':True,'imageFile':'example-model-input.png'}))
            make_reports(out,manifest,corpus)
            updated = json.loads((out/'blind-review.json').read_text())[0]
            self.assertEqual(updated['reason'], 'My real review')
            self.assertIn('What was unclear?', [updated['A'],updated['B']])


if __name__ == '__main__':
    unittest.main()
