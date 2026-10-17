"""Check the actual minimal UIKit controller against the selected iOS SDK."""
import argparse
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True)
args = parser.parse_args()
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
root = Path(__file__).resolve().parents[1]
subprocess.run(['xcrun', 'swiftc', '-typecheck', '-swift-version', '5', '-sdk', sdk,
                '-target', 'arm64-apple-ios15.0', str(args.source / 'AltStore/TabBarController.swift'),
                str(root / 'tests/MinimalUIStubs.swift')], check=True)
print('Minimal controller SDK typecheck passed; full archives and device tests remain required.')
