"""Build an isolated, lazily loaded iOS 17.4 StikJIT core without new app extensions."""
import argparse
import plistlib
import shutil
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--work', type=Path, required=True)
args = parser.parse_args()
work = args.work.resolve()
source = work / 'StikJIT'
framework = work / 'stikdebug-products/SideStoreStikDebugCore.framework'
assert not framework.exists(), 'Preserve the prior component build'
framework.mkdir(parents=True)
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
command = ['xcrun', '--sdk', 'iphoneos', 'swiftc', '-emit-library', '-O', '-swift-version', '5', '-sdk', sdk,
           '-target', 'arm64-apple-ios17.4', '-module-name', 'SideStoreStikDebugCore',
           '-I', str(source / 'idevice'), '-I', str(source / 'iokit'),
           '-L', str(source / 'idevice'), '-Xlinker', '-hidden-lidevice_ffi',
           '-Xlinker', '-dead_strip', '-Xlinker', '-install_name',
           '-Xlinker', '@rpath/SideStoreStikDebugCore.framework/SideStoreStikDebugCore']
for name in ['Foundation', 'JavaScriptCore', 'Network', 'Security', 'CFNetwork', 'SystemConfiguration', 'IOKit']:
    command += ['-framework', name]
command += [str(path) for path in sorted((source / 'Sources').glob('*.swift'))]
command += [str(work / 'SSStikDebugCore.swift'), '-o', str(framework / 'SideStoreStikDebugCore')]
subprocess.run(command, check=True)
for script in (source / 'Resources').glob('*.js'):
    shutil.copy2(script, framework / script.name)
shutil.copy2(source / 'LICENSE', framework / 'LICENSE-StikJIT.txt')
(framework / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'org.sidestore.StikDebugCore', 'CFBundleExecutable': 'SideStoreStikDebugCore',
    'CFBundleName': 'SideStoreStikDebugCore', 'CFBundlePackageType': 'FMWK',
    'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1', 'MinimumOSVersion': '17.4',
    'CFBundleSupportedPlatforms': ['iPhoneOS']}, fmt=plistlib.FMT_BINARY))
subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(framework)], check=True)
print('StikDebug core compiled and signed:', framework)
