"""Exercise the real Objective-C container scanner and handoff with temporary app folders."""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ContainerBridgeTests(unittest.TestCase):
    def test_native_container_scanning_and_handoff(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'container-tests'
            subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', '-fmodules',
                '-I', str(ROOT / 'custom/StikDebug'), str(ROOT / 'custom/StikDebug/SSStikDebugBridge.m'),
                str(ROOT / 'tests/StikContainerBridgeTests.m'), '-framework', 'Foundation', '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)


if __name__ == '__main__':
    unittest.main()
