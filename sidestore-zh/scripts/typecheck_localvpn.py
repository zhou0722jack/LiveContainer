"""Compile the prepared VPN UI/controller with the selected SDK and iOS 15 target."""
import argparse
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True)
args = parser.parse_args()
base = Path(__file__).resolve().parents[1]
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
subprocess.run(['xcrun', 'swiftc', '-typecheck', '-swift-version', '5', '-sdk', sdk,
                '-target', 'arm64-apple-ios15.0', str(base / 'tests/LocalVPNUIStubs.swift'),
                str(args.source / 'SideStore/Core/DeviceApi/BuiltInLocalVPN.swift'),
                str(args.source / 'SideStore/Views/Settings/Diagnostics/ExperimentalFeaturesView.swift')], check=True)
print('LocalVPN UI/controller SDK check passed; full app archive remains required.')
