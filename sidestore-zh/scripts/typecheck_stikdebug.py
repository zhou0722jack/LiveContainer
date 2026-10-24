"""Check prepared StikDebug UI, including the actual upstream UIKit Button class."""
import argparse
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
command = ['xcrun', '--sdk', 'iphoneos', 'swiftc', '-typecheck', '-swift-version', '5', '-sdk', sdk,
           '-target', 'arm64-apple-ios15.0']
ui = args.source / 'SideStore/Views/Settings/Diagnostics/SideStoreStikDebugView.swift'
command += [str(ui), str(ui.with_name('StikDebugLogSession.swift')),
            str(args.source / 'SideStore/Views/Settings/Diagnostics/ExperimentalFeaturesView.swift'),
            str(args.source / 'AltStore/Components/Button.swift'), str(root / 'tests/StikDebugUIStubs.swift')]
subprocess.run(command, check=True)
host = root / 'custom/StikDebug/LCBuiltInJIT.swift'
subprocess.run(['xcrun', '--sdk', 'iphoneos', 'swiftc', '-typecheck', '-swift-version', '5',
               '-sdk', sdk, '-target', 'arm64-apple-ios15.0', '-import-objc-header',
               str(root / 'tests/LCBuiltInJITSDK.h'), str(host)], check=True)
