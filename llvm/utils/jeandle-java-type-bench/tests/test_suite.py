"""Exercise orchestration with simulated processes; this does not measure performance."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]

class SuiteTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)/'suite'
        shutil.copytree(ROOT, self.root, ignore=shutil.ignore_patterns('opt-inputs', '__pycache__'))
        self.cli('prepare.py', [])
        self.versions = self.root/'versions.local.json'
        binary = str(Path(sys.executable).resolve())
        self.versions.write_text(json.dumps({v: {'opt': binary, 'replay': binary} for v in ('base', 'new')}))
        self.cpu = 0
        self.mismatch = False
        self.short = False
        self.commands = []

    def cli(self, name, args):
        with patch.object(sys, 'argv', [name, *map(str, args)]), contextlib.redirect_stdout(io.StringIO()):
            return runpy.run_path(str(self.root/name), run_name='__main__')

    def fake_run(self, cmd, **kwargs):
        self.commands.append(cmd)
        if len(cmd) == 5 and cmd[2] == 'cached':
            batches = int(cmd[3])
            data = dict(queries=32*batches, checksum=22*32*batches,
                        cpu_s=.36, wall_s=.36, final_hits=0, facts_hits=0)
            return subprocess.CompletedProcess(cmd, 0, json.dumps(data), '')
        self.cpu += .01 if self.short else .35
        output = b''
        if '-S' in cmd:
            output = b'unchanged optimized IR\n'
            if self.mismatch and '-jeandle-verify-java-type-cache=true' in cmd:
                output = b'different IR\n'
        return subprocess.CompletedProcess(cmd, 0, output, b'')

    def timing(self, out):
        with patch('os.sched_getaffinity', return_value={0}, create=True), \
             patch('os.sched_setaffinity', create=True), \
             patch('resource.getrusage', side_effect=lambda _: SimpleNamespace(ru_utime=self.cpu, ru_stime=0)), \
             patch('subprocess.run', side_effect=self.fake_run):
            self.cli('run.py', ['--versions', self.versions, '--cpu', 0, '--out', out,
                                '--repeats', 5, '--aa-repeats', 5, '--warmups', 1])

    def test_all_ten_and_short_sample_gate(self):
        self.short = True
        out = self.root/'results-test'
        self.timing(out)
        self.cli('audit.py', [out])
        report = json.loads((out/'audit.json').read_text())
        self.assertEqual(report['formal_samples'], 200)
        self.assertFalse(report['sample_duration_ok'])
        summary = json.loads((out/'summary.json').read_text())
        self.assertEqual(len(summary), 10)
        self.assertTrue(all(x['comparisons']['base->new']['verdict'] == 'inconclusive' for x in summary))
        for cmd in self.commands:
            if '-disable-output' in cmd:
                self.assertFalse(any('verify' in x or 'stats' in x or 'print<' in x for x in cmd))
        # Input tampering must be detected by the independent audit.
        (self.root/'inputs/same.ll').write_text('tampered')
        with self.assertRaises(AssertionError):
            self.cli('audit.py', [out])

    def test_ir_mismatch_prevents_success(self):
        self.mismatch = True
        out = self.root/'results-mismatch'
        with self.assertRaisesRegex(AssertionError, 'verification changed IR'):
            self.timing(out)
        self.assertFalse((out/'SUCCESS').exists())

    def test_frozen_corpus_and_prepare_overwrite_guard(self):
        hashes = json.loads((self.root/'inputs/SHA256.json').read_text())
        for name, expected in hashes.items():
            self.assertEqual(hashlib.sha256((self.root/'inputs'/name).read_bytes()).hexdigest(), expected)
        with self.assertRaisesRegex(RuntimeError, 'already exists'):
            self.cli('prepare.py', [])

if __name__ == '__main__':
    unittest.main()
