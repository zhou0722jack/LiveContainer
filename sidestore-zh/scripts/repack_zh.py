"""Integrate translated SideStore into the locally compiled LC host baseline."""
import hashlib
import json
import plistlib
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK, OUT = ROOT / 'work', ROOT / 'outputs'
STAGE = WORK / 'merged-zh'
SOURCE = WORK / 'SideStore-zh-final.xcarchive/Products/Applications/SideStore.app'
assert '** ARCHIVE SUCCEEDED **' in (WORK / 'build-zh-release.log').read_text()
assert SOURCE.exists() and not STAGE.exists()
shutil.copytree(WORK / 'lc-base', STAGE, symlinks=True)
host = STAGE / 'Payload/LiveContainer.app'
guest = host / 'Frameworks/SideStoreApp.framework'
if guest.exists():
    shutil.rmtree(guest)
shutil.copytree(SOURCE, guest, symlinks=True)
converted = guest / 'SideStore.dylib'
with (WORK / 'dylibify-zh.log').open('w') as log:
    subprocess.run([str(WORK / 'dylibify-tool'), str(guest / 'SideStore'), str(converted)],
                   stdout=log, stderr=subprocess.STDOUT, check=True)
converted.replace(guest / 'SideStore')
shutil.copy2(WORK / 'LiveContainer/.github/sidelc/LCAppInfo.plist', guest)
widget = host / 'PlugIns/LiveWidgetExtension.appex'
if widget.exists():
    shutil.rmtree(widget)
shutil.move(str(guest / 'PlugIns/AltWidgetExtension.appex'), widget)
(widget / 'AltWidgetExtension').rename(widget / 'LiveWidgetExtension')
info_path = widget / 'Info.plist'
info = plistlib.loads(info_path.read_bytes())
info['CFBundleIdentifier'] = 'com.kdt.livecontainer.LiveWidget'
info['CFBundleExecutable'] = 'LiveWidgetExtension'
info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
for name in ['Intents.intentdefinition', 'ViewApp.intentdefinition']:
    shutil.copy2(guest / name, host / name)
if (host / 'Metadata.appintents').exists():
    shutil.rmtree(host / 'Metadata.appintents')
shutil.copytree(guest / 'Metadata.appintents', host / 'Metadata.appintents')
actions = host / 'Metadata.appintents/extract.actionsdata'
data = actions.read_text()
for old, new in [('9SideStore20RefreshAllAppsIntentV', '16SideStoreSupport20RefreshAllAppsIntentV'),
                 ('9SideStore26RefreshAllAppsWidgetIntentV', '16SideStoreSupport26RefreshAllAppsWidgetIntentV')]:
    assert old in data, old
    data = data.replace(old, new)
json.loads(data)
actions.write_text(data)
empty = WORK / 'empty-entitlements-zh.plist'
empty.write_bytes(plistlib.dumps({}))
subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none',
                '--entitlements', str(empty), str(guest / 'SideStore')], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none',
                '--entitlements', str(WORK / 'LiveContainer/.github/sidelc/LiveWidgetExtension_adhoc.xml'),
                str(widget)], check=True)
ipa = OUT / 'LiveContainer+SideStore-zh-Hans.ipa'
assert not ipa.exists()
subprocess.run(['zip', '-qry', str(ipa), 'Payload', '-x', '*/.DS_Store', '*/._*', '*/__MACOSX/*'], cwd=STAGE, check=True)
print(ipa)
print(ipa.stat().st_size, hashlib.sha256(ipa.read_bytes()).hexdigest())
