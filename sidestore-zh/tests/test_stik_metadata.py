"""Run the actual Swift metadata reader against heterogeneous device records."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class StikMetadataTests(unittest.TestCase):
    def test_unsupported_metadata_and_invalid_siblings_do_not_abort_listing(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'metadata-tests'
            subprocess.run(['xcrun', 'swiftc', '-parse-as-library',
                str(ROOT / 'custom/StikDebug/StikAppMetadataReader.swift'),
                str(ROOT / 'tests/StikAppMetadataTests.swift'), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)


if __name__ == '__main__':
    unittest.main()
