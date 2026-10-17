"""Execute the packet implementation used by the extension, without a device."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


class LocalVPNPacketTests(unittest.TestCase):
    def test_packet_reflection_and_checksums(self):
        base = Path(__file__).resolve().parents[1]
        if os.uname().sysname != 'Darwin':
            self.skipTest('Swift / Xcode check runs on the macOS build runner')
        with tempfile.TemporaryDirectory() as folder:
            binary = str(Path(folder) / 'packet-tests')
            subprocess.run(['xcrun', 'swiftc', str(base / 'custom/LocalVPN/LocalVPNPacket.swift'),
                            str(base / 'tests/LocalVPNPacketTests.swift'), '-o', binary], check=True)
            subprocess.run([binary], check=True)
