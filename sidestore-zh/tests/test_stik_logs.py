"""Exercise the actual copyable log document without device JIT."""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class StikLogTests(unittest.TestCase):
    def test_log_results_and_task_isolation(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'log-tests'
            subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-parse-as-library',
                str(ROOT / 'custom/StikDebug/StikDebugLogSession.swift'),
                str(ROOT / 'tests/StikDebugLogTests.swift'), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)


if __name__ == '__main__':
    unittest.main()
