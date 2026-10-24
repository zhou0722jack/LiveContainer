import hashlib
import argparse
import json
import plistlib
import stat
import struct
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK, OUT = ROOT / 'work', ROOT / 'outputs'
parser = argparse.ArgumentParser()
parser.add_argument('--ipa', default='LiveContainer-3.8.10+SideStore-20261016.ipa')
parser.add_argument('--source-ipa', default='ss-nightly.ipa')
parser.add_argument('--stage', default='merged')
parser.add_argument('--report', default='verification.json')
args = parser.parse_args()
ipa = OUT / args.ipa
checks = {}

def check(name, condition):
    assert condition, name
    checks[name] = 'PASS'

def macho(data):
    header = struct.unpack_from('<8I', data)
    assert header[0] == 0xfeedfacf
    commands, cursor = [], 32
    for _ in range(header[4]):
        cmd, size = struct.unpack_from('<II', data, cursor)
        assert size >= 8 and cursor + size <= 32 + header[5]
        commands.append((cmd, data[cursor:cursor + size]))
        cursor += size
    assert cursor == 32 + header[5]
    return header, commands

with zipfile.ZipFile(ipa) as package, zipfile.ZipFile(WORK / 'lc-nightly.ipa') as old, zipfile.ZipFile(WORK / args.source_ipa) as new:
    check('zip_crc', package.testzip() is None)
    names = package.namelist()
    check('no_duplicate_entries', len(names) == len(set(names)))
    check('safe_paths', all(n.startswith('Payload/') and '..' not in Path(n).parts for n in names))
    top = 'Payload/LiveContainer.app/'
    guest = top + 'Frameworks/SideStoreApp.framework/'
    widget = top + 'PlugIns/LiveWidgetExtension.appex/'
    host_info = plistlib.loads(package.read(top + 'Info.plist'))
    guest_info = plistlib.loads(package.read(guest + 'Info.plist'))
    widget_info = plistlib.loads(package.read(widget + 'Info.plist'))
    old_info = plistlib.loads(old.read(top + 'Info.plist'))
    new_info = plistlib.loads(new.read('Payload/SideStore.app/Info.plist'))
    check('host_version_matches_build', host_info['CFBundleShortVersionString'] == old_info['CFBundleShortVersionString'])
    check('guest_version_matches_build', guest_info['CFBundleShortVersionString'] == new_info['CFBundleShortVersionString'])
    check('widget_identity', widget_info['CFBundleIdentifier'] == 'com.kdt.livecontainer.LiveWidget'
          and widget_info['CFBundleExecutable'] == 'LiveWidgetExtension')
    unchanged_host_files = 0
    allowed = [guest, widget, top + 'Metadata.appintents/',
               top + 'Intents.intentdefinition', top + 'ViewApp.intentdefinition']
    for n in old.namelist():
        if n.endswith('/') or any(n.startswith(p) for p in allowed):
            continue
        check('host_byte_identity:' + n, package.read(n) == old.read(n))
        unchanged_host_files += 1
    check('host_main_binary_unchanged', package.read(top + 'LiveContainer') == old.read(top + 'LiveContainer'))
    check('integration_framework_unchanged', package.read(top + 'Frameworks/SideStoreSupport.framework/SideStoreSupport')
          == old.read(top + 'Frameworks/SideStoreSupport.framework/SideStoreSupport'))
    core = top + 'Frameworks/SideStoreStikDebugCore.framework/'
    core_info = plistlib.loads(package.read(core + 'Info.plist'))
    core_binary = package.read(core + 'SideStoreStikDebugCore')
    check('stikdebug_core_dylib', macho(core_binary)[0][3] == 6)
    check('stikdebug_core_ios174', core_info.get('MinimumOSVersion') == '17.4')
    check('stikdebug_core_class', b'SSStikDebugCore' in core_binary)
    check('stikdebug_helper_entry', b'SSStikDebugHelperMain' in core_binary)
    check('stikdebug_container_handoff', b'SSBuiltInJITPendingContainer' in core_binary)
    ui_binary = package.read(top + 'Frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI')
    check('livecontainer_builtin_jit_coordinator', b'LCBuiltInJIT' in ui_binary)
    check('livecontainer_builtin_jit_handoff', b'SSBuiltInJITPendingContainer' in ui_binary)
    shared_binary = package.read(top + 'Frameworks/LiveContainerShared.framework/LiveContainerShared')
    check('stikdebug_main_process_entry', b'SSStikDebugStartMainProcess' in core_binary)
    check('livecontainer_main_jit_bootstrap', b'SSStikDebugStartMainProcess' in shared_binary)
    check('livecontainer_fullscreen_jit_handoff', b'SSBuiltInJITFullScreenLaunch' in shared_binary
          and b'SSBuiltInJITFullScreenLaunch' in ui_binary)
    check('stikdebug_universal_script', len(package.read(core + 'universal.js')) > 100)
    check('stikdebug_licenses', b'AFFERO GENERAL PUBLIC LICENSE' in package.read(top + 'LICENSE-StikDebug.txt')
          and b'Mozilla Public License' in package.read(core + 'LICENSE-StikJIT.txt'))
    check('stikdebug_source_provenance', b'github.com/StikDebug/StikJIT/tree/' in package.read(top + 'StikDebug-SOURCE.txt'))
    check('stikdebug_ui_compiled', b'Frameworks/SideStoreStikDebugCore.framework/SideStoreStikDebugCore' in package.read(guest + 'SideStore'))
    check('stikdebug_pip_log_compiled', b'SSStikDebugPiPController' in package.read(guest + 'SideStore'))
    check('stikdebug_pip_system_framework', any(b'/AVKit.framework/AVKit' in data
          for _, data in macho(package.read(guest + 'SideStore'))[1]))
    check('stikdebug_pip_background_mode', 'audio' in host_info.get('UIBackgroundModes', [])
          and 'audio' in guest_info.get('UIBackgroundModes', []))
    check('stikdebug_host_identifier_unchanged', host_info['CFBundleIdentifier'] == 'com.kdt.livecontainer')
    check('stikdebug_no_new_extensions', {name for name in names if name.endswith('.appex/Info.plist')} == {
        top + 'PlugIns/' + name + '.appex/Info.plist' for name in ['LiveProcess', 'LiveWidgetExtension', 'ShareExtension', 'LaunchAppExtension']})
    check('stikdebug_no_builtin_vpn', not any('LocalVPN.appex/' in name for name in names))
    check('stikdebug_not_strongly_linked', not any(b'SideStoreStikDebugCore.framework' in data for _, data in macho(package.read(guest + 'SideStore'))[1]))
    for name in ['Intents.intentdefinition', 'ViewApp.intentdefinition']:
        check('intent_definition_matches_guest:' + name,
              package.read(top + name) == new.read('Payload/SideStore.app/' + name))
        current = plistlib.loads(package.read(top + name))
        if top + name in old.namelist():
            previous = plistlib.loads(old.read(top + name))
            for key in ['INIntentDefinitionSystemVersion', 'INIntentDefinitionToolsVersion', 'INIntentDefinitionToolsBuildVersion']:
                previous.pop(key, None)
                current.pop(key, None)
            check('intent_definition_semantics_unchanged:' + name, previous == current)
    copied_guest_files = 0
    for n in new.namelist():
        if n.endswith('/'):
            continue
        rel = n.removeprefix('Payload/SideStore.app/')
        if rel == 'SideStore':
            continue
        if rel.startswith('PlugIns/AltWidgetExtension.appex/'):
            sub = rel.removeprefix('PlugIns/AltWidgetExtension.appex/')
            if sub in ['AltWidgetExtension', 'Info.plist', '_CodeSignature/CodeResources']:
                continue
            dest = widget + sub
        else:
            dest = guest + rel
        check('guest_byte_identity:' + rel, package.read(dest) == new.read(n))
        copied_guest_files += 1
    for n in names:
        if n.endswith('/Info.plist'):
            plistlib.loads(package.read(n))
    check('all_info_plists_parse', True)
    check('sidestore_app_group', 'group.com.SideStore.SideStore' in host_info['ALTAppGroups'])
    check('sidestore_url_scheme', any('sidestore' in x.get('CFBundleURLSchemes', []) for x in host_info['CFBundleURLTypes']))
    lcinfo = plistlib.loads(package.read(guest + 'LCAppInfo.plist'))
    check('guest_config_matches_source', lcinfo == plistlib.loads((WORK / 'LiveContainer/.github/sidelc/LCAppInfo.plist').read_bytes()))
    actions = package.read(top + 'Metadata.appintents/extract.actionsdata')
    json.loads(actions)
    check('refresh_intent_redirects', b'16SideStoreSupport20RefreshAllAppsIntentV' in actions
          and b'16SideStoreSupport26RefreshAllAppsWidgetIntentV' in actions
          and b'9SideStore20RefreshAllAppsIntentV' not in actions)
    binary = package.read(guest + 'SideStore')
    header, commands = macho(binary)
    check('guest_arm64_dylib', header[1] == 0x100000c and header[3] == 6)
    segments = [c for cmd, c in commands if cmd == 0x19]
    check('no_pagezero', all(c[8:24].rstrip(b'\0') != b'__PAGEZERO' for c in segments))
    check('dylib_install_name', any(cmd == 0xd and b'@executable_path/SideStore.dylib\0' in c for cmd, c in commands))
    for cmd, c in commands:
        if cmd == 0x80000034:
            dataoff, datasize = struct.unpack_from('<II', c, 8)
            starts_offset = struct.unpack_from('<I', binary, dataoff + 4)[0]
            starts = dataoff + starts_offset
            count = struct.unpack_from('<I', binary, starts)[0]
            check('chained_fixups_segment_count', count == len(segments))
            for i, segment in enumerate(segments):
                offset = struct.unpack_from('<I', binary, starts + 4 + 4 * i)[0]
                if offset:
                    segment_offset = struct.unpack_from('<Q', binary, starts + offset + 8)[0]
                    vmaddr = struct.unpack_from('<Q', segment, 24)[0]
                    check('chained_fixups_mapping:' + str(i), segment_offset == vmaddr - 0x100000000)
        if cmd == 0x2c:
            check('guest_not_encrypted', struct.unpack_from('<I', c, 16)[0] == 0)
    # Release binaries strip full Swift symbols; type-name strings remain.
    # This checks retained names only, not runtime _typeByName success.
    check('guest_refresh_type_names_present', b'RefreshAllAppsIntent\0' in binary
          and b'RefreshAllAppsWidgetIntent\0' in binary)
    check('no_nested_appex_in_guest', not any(n.startswith(guest + 'PlugIns/') and '.appex/' in n for n in names))
    for rel in ['LiveContainer', 'Frameworks/SideStoreApp.framework/SideStore',
                'PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension']:
        check('executable_mode:' + rel, bool((package.getinfo(top + rel).external_attr >> 16) & stat.S_IXUSR))

for rel in ['Frameworks/SideStoreApp.framework/SideStore', 'PlugIns/LiveWidgetExtension.appex', 'Frameworks/SideStoreStikDebugCore.framework']:
    result = subprocess.run(['codesign', '--verify', '--strict', '--verbose=2',
                             str(WORK / args.stage / 'Payload/LiveContainer.app' / rel)], capture_output=True, text=True)
    check('adhoc_signature:' + rel, result.returncode == 0)

report = {
    'artifact': ipa.name,
    'bytes': ipa.stat().st_size,
    'sha256': hashlib.sha256(ipa.read_bytes()).hexdigest(),
    'versions': {'LiveContainer': host_info['CFBundleShortVersionString'], 'SideStore': guest_info['CFBundleShortVersionString']},
    'input_sha256': {name: hashlib.sha256((WORK / name).read_bytes()).hexdigest()
                    for name in ['lc-nightly.ipa', args.source_ipa]},
    'unchanged_host_files': unchanged_host_files,
    'copied_guest_files': copied_guest_files,
    'host_baseline': 'Locally compiled source archive with SideStore integration plist keys; byte identity covers packaging only.',
    'checks': checks,
    'device_installation': 'UNRUN',
    'apple_id_login_and_2fa': 'UNRUN',
    'refresh_and_guest_launch': 'UNRUN',
    'stikdebug_device_pairing_ddi_jit': 'UNRUN',
    'stikdebug_container_search_and_helper_jit': 'UNRUN',
    'stikdebug_ordinary_fullscreen_main_process_jit': 'UNRUN',
    'sidestore_quick_jit_system_pip_log_ui': 'UNRUN',
    'distribution_signing': 'Requires iloader to re-sign with user account. Ad-hoc signatures are not device installation authorization.'
}
(OUT / args.report).write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({k: v for k, v in report.items() if k != 'checks'}, indent=2))
print('static checks passed:', len(checks))
