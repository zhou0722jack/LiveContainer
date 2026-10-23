"""Verify the integration's packaging and support boundaries before expensive archives."""
import importlib.util
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('stik_pipeline', ROOT / 'build.py')
pipeline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pipeline)


class StikPackagingTests(unittest.TestCase):
    def test_host_keeps_identifiers_and_extension_count(self):
        with tempfile.TemporaryDirectory() as folder:
            work = Path(folder) / 'work'
            source = work / 'LiveContainer-final.xcarchive/Products/Applications/LiveContainer.app'
            (source / 'Settings.bundle').mkdir(parents=True)
            (source / 'Frameworks').mkdir()
            (source / 'PlugIns').mkdir()
            for name in ['LiveProcess', 'ShareExtension', 'LaunchAppExtension']:
                extension = source / 'PlugIns' / (name + '.appex')
                extension.mkdir()
                (extension / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.kdt.livecontainer.' + name}))
            (source / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.kdt.livecontainer'}))
            (source / 'Settings.bundle/Root.plist').write_bytes(plistlib.dumps({'PreferenceSpecifiers': []}))
            core = work / 'stikdebug-products/SideStoreStikDebugCore.framework'
            core.mkdir(parents=True)
            (core / 'SideStoreStikDebugCore').write_bytes(b'component fixture')
            pipeline.write_json(work.parent / 'candidate.json', {'sources': {'StikJIT': {'commit': 'a' * 40}}})
            with patch.object(pipeline, 'run') as run:
                pipeline.make_host_baseline(work)
            host = work / 'lc-base/Payload/LiveContainer.app'
            self.assertEqual(plistlib.loads((host / 'Info.plist').read_bytes())['CFBundleIdentifier'], 'com.kdt.livecontainer')
            self.assertEqual({p.name for p in (host / 'PlugIns').iterdir()}, {p.name for p in (source / 'PlugIns').iterdir()})
            self.assertEqual((host / 'Frameworks/SideStoreStikDebugCore.framework/SideStoreStikDebugCore').read_bytes(), b'component fixture')
            self.assertIn('a' * 40, (host / 'StikDebug-SOURCE.txt').read_text())
            self.assertFalse(any(call.args[0][0] == 'codesign' for call in run.call_args_list))

    def test_failed_core_build_cannot_be_packaged(self):
        with tempfile.TemporaryDirectory() as folder:
            work = Path(folder) / 'work'
            source = work / 'LiveContainer-final.xcarchive/Products/Applications/LiveContainer.app'
            source.mkdir(parents=True)
            with self.assertRaisesRegex(RuntimeError, 'StikDebug component missing'):
                pipeline.make_host_baseline(work)


if __name__ == '__main__':
    unittest.main()
