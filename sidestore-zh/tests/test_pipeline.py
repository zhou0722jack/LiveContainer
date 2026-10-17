"""Behavior checks for upstream maintenance, without Xcode or personal data."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('pipeline', Path(__file__).resolve().parents[1] / 'build.py')
pipeline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pipeline)


class PipelineTests(unittest.TestCase):
    def test_schedule_skips_only_successful_unchanged_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            recipe = base / 'recipe.txt'
            recipe.write_text('version 1')
            args = argparse.Namespace(pinned=True, force=False)
            lock = {'sources': {'SideStore': {'commit': 'a' * 40}}}
            env = {'GITHUB_EVENT_NAME': 'schedule', 'GITHUB_OUTPUT': ''}
            with patch.object(pipeline, 'BASE', base), patch.object(pipeline, 'LOCK', lock), \
                 patch.object(pipeline, 'recipe_files', lambda: [(recipe, 'recipe.txt')]), \
                 patch.dict(os.environ, env), contextlib.redirect_stdout(io.StringIO()):
                pipeline.check(base / 'first', args)
                first = pipeline.read_json(base / 'first/candidate.json')
                self.assertTrue(first['should_build'])
                (base / '.last-success').mkdir()
                pipeline.write_json(base / '.last-success/state.json', {'fingerprint': first['fingerprint']})
                pipeline.check(base / 'same', args)
                self.assertFalse(pipeline.read_json(base / 'same/candidate.json')['should_build'])
                recipe.write_text('version 2')
                pipeline.check(base / 'changed', args)
                self.assertTrue(pipeline.read_json(base / 'changed/candidate.json')['should_build'])
                recipe.write_text('version 1')
                os.environ['GITHUB_EVENT_NAME'] = 'workflow_dispatch'
                pipeline.check(base / 'manual', args)
                self.assertTrue(pipeline.read_json(base / 'manual/candidate.json')['should_build'])

    def make_patch_repo(self, directory, conflict):
        root = Path(directory)
        source = root / 'repo'
        subprocess.run(['git', 'init', '-q', str(source)], check=True)
        subprocess.run(['git', '-C', str(source), 'config', 'user.name', 'Fixture'], check=True)
        subprocess.run(['git', '-C', str(source), 'config', 'user.email', 'fixture@example.invalid'], check=True)
        path = source / 'ui.txt'
        lines = [f'context line {n}\n' for n in range(20)]
        lines[6] = 'English UI\n'
        path.write_text(''.join(lines))
        subprocess.run(['git', '-C', str(source), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(source), 'commit', '-qm', 'fixture base'], check=True)
        translated = lines.copy()
        translated[6] = '中文界面\n'
        path.write_text(''.join(translated))
        patch_file = root / 'translation.patch'
        patch_file.write_bytes(subprocess.check_output(['git', '-C', str(source), 'diff', '--binary']))
        updated = lines.copy()
        updated[6 if conflict else 3] = 'Conflicting upstream UI\n' if conflict else 'Upstream feature\n'
        path.write_text(''.join(updated))
        subprocess.run(['git', '-C', str(source), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(source), 'commit', '-qm', 'fixture upstream'], check=True)
        return source, patch_file

    def test_three_way_keeps_nonconflicting_upstream_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            source, patch_file = self.make_patch_repo(directory, conflict=False)
            direct = subprocess.run(['git', 'apply', '--check', str(patch_file)], cwd=source, capture_output=True)
            self.assertNotEqual(direct.returncode, 0)
            pipeline.apply_patch(source, patch_file, Path(directory) / 'patch.log')
            text = (source / 'ui.txt').read_text()
            self.assertIn('Upstream feature', text)
            self.assertIn('中文界面', text)

    def test_conflicting_translation_stops_and_keeps_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            source, patch_file = self.make_patch_repo(directory, conflict=True)
            log = Path(directory) / 'patch.log'
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(subprocess.CalledProcessError):
                pipeline.apply_patch(source, patch_file, log)
            self.assertIn('ui.txt', pipeline.git(source, 'diff', '--name-only', '--diff-filter=U'))
            self.assertTrue(log.exists())


if __name__ == '__main__':
    unittest.main()
