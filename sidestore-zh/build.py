"""Track both upstreams, apply patch queues, build and verify a combined IPA."""
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

BASE = Path(__file__).resolve().parent
LOCK = json.loads((BASE / 'inputs.lock.json').read_text())
ARTIFACT = 'LiveContainer+SideStore-zh-Hans.ipa'
PACKAGE_LOCK = 'AltStore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def read_json(path):
    return json.loads(path.read_text())


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')


def run(command, cwd=None, log=None):
    print('+', ' '.join(map(str, command)), flush=True)
    if log:
        if log.exists():
            number = 1
            while log.with_name(f'{log.stem}.previous-{number}{log.suffix}').exists():
                number += 1
            log.rename(log.with_name(f'{log.stem}.previous-{number}{log.suffix}'))
        with log.open('w') as stream:
            result = subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            print('\n'.join(log.read_text(errors='replace').splitlines()[-80:]))
            raise subprocess.CalledProcessError(result.returncode, command)
    else:
        subprocess.run(command, cwd=cwd, check=True)


def git(source, *args):
    return subprocess.check_output(['git', '-C', str(source), *args], text=True).strip()


def recipe_files():
    for path in sorted(BASE.rglob('*')):
        rel = path.relative_to(BASE)
        if path.is_file() and not any(p in {'.build', '.last-success', '.git', '.DS_Store', '__pycache__'} for p in rel.parts):
            yield path, 'sidestore-zh/' + rel.as_posix()
    yield BASE.parent / '.github/workflows/build-zh.yml', '.github/workflows/build-zh.yml'


def check(root, args):
    require(not (root / 'work').exists(), 'Preserve this generation; choose a new --build-root')
    root.mkdir(parents=True, exist_ok=True)
    sources = json.loads(json.dumps(LOCK['sources']))
    for name, entry in sources.items():
        if 'ref' in entry and not args.pinned:
            response = subprocess.check_output(
                ['git', 'ls-remote', '--exit-code', entry['url'], entry['ref']], text=True).split()
            require(len(response) == 2 and len(response[0]) == 40, f'Cannot resolve {name}')
            entry['commit'] = response[0]
    files = {name: digest(path) for path, name in recipe_files()}
    fingerprint = hashlib.sha256(json.dumps({'sources': sources, 'recipe': files}, sort_keys=True).encode()).hexdigest()
    previous = BASE / '.last-success/state.json'
    changed = not previous.exists() or read_json(previous).get('fingerprint') != fingerprint
    should_build = args.force or os.environ.get('GITHUB_EVENT_NAME') != 'schedule' or changed
    candidate = {'sources': sources, 'recipe': files, 'fingerprint': fingerprint,
                 'mode': 'pinned' if args.pinned else 'upstream', 'should_build': should_build}
    write_json(root / 'candidate.json', candidate)
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            stream.write('should_build=' + str(should_build).lower() + '\n')
    print('Source commits:', {k: v['commit'] for k, v in sources.items()})
    print('Build required:', should_build, '| fingerprint:', fingerprint)


def checkout(url, commit, target):
    run(['git', 'init', '-q', str(target)])
    run(['git', 'remote', 'add', 'origin', str(url)], cwd=target)
    run(['git', 'fetch', '--depth=1', 'origin', commit], cwd=target)
    run(['git', 'checkout', '--detach', 'FETCH_HEAD'], cwd=target)
    require(git(target, 'rev-parse', 'HEAD') == commit, f'Wrong source revision: {target.name}')


def apply_patch(source, path, log):
    direct = subprocess.run(['git', 'apply', '--check', str(path)], cwd=source, capture_output=True)
    if direct.returncode == 0:
        run(['git', 'apply', str(path)], cwd=source, log=log)
    else:
        # Three-way application needs a consistent index and the old base blobs.
        run(['git', 'add', '-A'], cwd=source)
        run(['git', 'apply', '--3way', str(path)], cwd=source, log=log)


def snapshot(source):
    names = subprocess.check_output(['git', '-C', str(source), 'ls-files', '-z', '--cached',
                                     '--others', '--exclude-standard']).decode().split('\0')
    return {name: digest(source / name) for name in sorted(set(names)) if name and (source / name).is_file()}


def validate_source(work, allow_generated=False):
    manifest = read_json(work / 'source-manifest.json')
    candidate = read_json(work.parent / 'candidate.json')
    if 'StikJIT' in candidate['sources']:
        for name in ['SSStikDebugCore.swift', 'StikAppMetadataReader.swift', 'SSStikDebugBridge.h', 'SSStikDebugBridge.m']:
            require(digest(work / name) == candidate['recipe']['sidestore-zh/custom/StikDebug/' + name],
                    'StikDebug integration source changed: ' + name)
    for name, entry in read_json(work.parent / 'candidate.json')['sources'].items():
        source = work / name
        require(git(source, 'rev-parse', 'HEAD') == entry['commit'], f'Wrong {name} revision')
        require(git(source, 'submodule', 'status', '--recursive') == manifest[name]['submodules'],
                f'{name} submodule state changed')
        for rel, expected in manifest[name]['files'].items():
            if allow_generated and name == 'SideStore' and rel == 'AltStore/Resources/SideBackup.ipa':
                continue
            require(digest(source / rel) == expected, f'Source changed: {name}/{rel}')


def prepare(root, args):
    if not (root / 'candidate.json').exists():
        check(root, args)
    require(not (root / 'work').exists(), 'Preserve the prior generation; choose a new --build-root')
    candidate = read_json(root / 'candidate.json')
    require(candidate['recipe'] == {name: digest(path) for path, name in recipe_files()},
            'Recipe changed; run check in a fresh build root')
    work = root / 'work'
    work.mkdir()
    (root / 'outputs').mkdir()
    for script in (BASE / 'scripts').glob('*.py'):
        shutil.copy2(script, work / script.name)
    for name, entry in candidate['sources'].items():
        url = args.source_mirror / name if args.source_mirror else entry['url']
        checkout(url, entry['commit'], work / name)
        bases = set(LOCK['sources'][name].get('patch_bases', []))
        if name == 'SideStore':
            bases.add(LOCK['sources'][name]['commit'])
        for commit in sorted(bases - {entry['commit']}):
            run(['git', 'fetch', '--depth=1', 'origin', commit], cwd=work / name)
        if args.source_mirror:
            for record in git(work / name, 'ls-tree', '-r', 'HEAD').splitlines():
                mode, kind, tail = record.split(' ', 2)
                if mode == '160000':
                    commit, rel = tail.split('\t', 1)
                    mirror = args.source_mirror / name / rel
                    if (mirror / '.git').exists():
                        checkout(mirror, commit, work / name / rel)
                    else:
                        run(['git', 'submodule', 'update', '--init', '--recursive', '--depth=1', '--', rel], cwd=work / name)
        else:
            run(['git', 'submodule', 'update', '--init', '--recursive', '--depth=1'], cwd=work / name)
    source = work / 'SideStore'
    apply_patch(source, BASE / 'patches/SideStore-zh.patch', work / 'patch-translation.log')
    strings = source / 'AltStore/zh-Hans.lproj/Localizable.strings'
    strings.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(BASE / 'resources/Localizable.strings', strings)
    if candidate['mode'] == 'pinned':
        shutil.copy2(BASE / 'Package.resolved', source / PACKAGE_LOCK)
    require((source / PACKAGE_LOCK).exists(), 'Upstream dependency lock missing; review before building')
    run([sys.executable, str(work / 'audit_zh.py')])
    series = read_json(BASE / 'custom/series.json')
    require(set(series) == {'LiveContainer', 'SideStore'}, 'Unexpected custom patch project')
    for name, paths in series.items():
        for index, rel in enumerate(paths):
            patch = (BASE / 'custom' / rel).resolve()
            require(patch.is_relative_to((BASE / 'custom').resolve()) and patch.suffix == '.patch', 'Invalid custom patch path')
            apply_patch(work / name, patch, work / f'patch-{name}-{index}.log')
    shutil.copy2(BASE / 'custom/StikDebug/SSStikDebugCore.swift', work / 'SSStikDebugCore.swift')
    shutil.copy2(BASE / 'custom/StikDebug/StikAppMetadataReader.swift', work / 'StikAppMetadataReader.swift')
    for name in ['SSStikDebugBridge.h', 'SSStikDebugBridge.m']:
        shutil.copy2(BASE / 'custom/StikDebug' / name, work / name)
    shutil.copy2(BASE / 'custom/StikDebug/LCBuiltInJIT.swift',
                 work / 'LiveContainer/LiveContainerSwiftUI/Utilities/LCBuiltInJIT.swift')
    for name in ['SideStoreStikDebugView.swift', 'StikDebugLogSession.swift',
                 'StikDebugLogVideoRenderer.swift', 'SideStoreJITLogPictureInPicture.swift']:
        shutil.copy2(BASE / 'custom/StikDebug' / name, source / 'SideStore/Views/Settings/Diagnostics' / name)
    manifest = {name: {'files': snapshot(work / name),
                       'submodules': git(work / name, 'submodule', 'status', '--recursive')}
                for name in candidate['sources']}
    write_json(work / 'source-manifest.json', manifest)
    run(['xcrun', 'clang', str(work / 'dylibify/main.m'), '-framework', 'Foundation',
         '-fobjc-arc', '-o', str(work / 'dylibify-tool')])
    write_json(work / 'build-provenance.json', {**candidate, 'device_installation': 'UNRUN',
               'login_refresh_guest_launch': 'UNRUN', 'ui_visual_validation': 'UNRUN'})
    (work / 'prepared.ok').touch()
    print('Prepared:', root)


def build(root):
    work = root / 'work'
    require((work / 'prepared.ok').exists(), 'Run prepare first')
    validate_source(work)
    for path in ['SideStore-zh-final.xcarchive', 'LiveContainer-final.xcarchive']:
        require(not (work / path).exists(), 'Preserve prior archives')
    common = ['-project', str(work / 'SideStore/AltStore.xcodeproj'), '-scheme', 'SideStore',
              '-sdk', 'iphoneos', '-clonedSourcePackagesDirPath', str(work / 'spm-zh'),
              '-onlyUsePackageVersionsFromResolvedFile']
    run(['xcodebuild', '-resolvePackageDependencies', *common], log=work / 'resolve-zh.log')
    validate_source(work)
    signing = ['CODE_SIGNING_REQUIRED=NO', 'CODE_SIGNING_ALLOWED=NO', 'DEVELOPMENT_TEAM=XYZ0123456', 'ARCHS=arm64']
    run([sys.executable, str(work / 'build_stikdebug.py'), '--work', str(work)], log=work / 'build-stikdebug.log')
    run(['xcodebuild', 'archive', *common, '-destination', 'generic/platform=iOS',
         '-configuration', 'Release', '-archivePath', str(work / 'SideStore-zh-final'),
         '-derivedDataPath', str(work / 'derived-zh'), '-disableAutomaticPackageResolution',
         '-jobs', '4', *signing, 'ORG_IDENTIFIER=com.SideStore'], log=work / 'build-zh-release.log')
    run(['xcodebuild', 'archive', '-project', str(work / 'LiveContainer/LiveContainer.xcodeproj'),
         '-scheme', 'LiveContainer', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS',
         '-configuration', 'Release', '-archivePath', str(work / 'LiveContainer-final'),
         '-derivedDataPath', str(work / 'derived-lc'), '-jobs', '4', *signing], log=work / 'build-lc-release.log')
    validate_source(work, allow_generated=True)
    provenance = read_json(work / 'build-provenance.json')
    provenance['toolchain'] = subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
    provenance['iphoneos_sdk'] = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip()
    provenance['source_manifest_sha256'] = digest(work / 'source-manifest.json')
    provenance['build_recipe'] = {name: digest(path) for path, name in recipe_files()}
    write_json(work / 'build-provenance.json', provenance)
    (work / 'archive.ok').touch()
    print('Both source archives passed.')


def make_host_baseline(work):
    source = work / 'LiveContainer-final.xcarchive/Products/Applications/LiveContainer.app'
    host = work / 'lc-base/Payload/LiveContainer.app'
    shutil.copytree(source, host, symlinks=True)
    core = work / 'stikdebug-products/SideStoreStikDebugCore.framework'
    require(core.exists(), 'StikDebug component missing; run build first')
    shutil.copytree(core, host / 'Frameworks/SideStoreStikDebugCore.framework', symlinks=True)
    for name in ['LICENSE-StikDebug', 'LICENSE-StikJIT']:
        shutil.copy2(BASE / 'custom/StikDebug' / name, host / (name + '.txt'))
    (host / 'StikDebug-SOURCE.txt').write_text(
        'Unofficial SideStore integration. StikJIT source: https://github.com/StikDebug/StikJIT/tree/' +
        read_json(work.parent / 'candidate.json')['sources']['StikJIT']['commit'] + '\n' +
        'StikDebug reference: https://github.com/StikDebug/StikDebug/tree/17b1e1d90d602a228de663a10efa987a9f9e547b\n' +
        'Integration source and build recipe: source-recipe.zip in this Actions artifact.\n')
    path = host / 'Info.plist'
    info = plistlib.loads(path.read_bytes())
    groups = info.setdefault('ALTAppGroups', [])
    if 'group.com.SideStore.SideStore' not in groups:
        groups.append('group.com.SideStore.SideStore')
    schemes = info.setdefault('CFBundleURLTypes', [])
    for suffix in ['sidestore', 'sidestore-' + info['CFBundleIdentifier']]:
        if not any(suffix in entry.get('CFBundleURLSchemes', []) for entry in schemes):
            schemes.append({'CFBundleURLName': info['CFBundleIdentifier'] + '.' + suffix,
                            'CFBundleURLSchemes': [suffix]})
    for key in ['INIntentsSupported', 'NSUserActivityTypes']:
        values = info.setdefault(key, [])
        for intent in ['RefreshAllIntent', 'ViewAppIntent']:
            if intent not in values:
                values.append(intent)
    path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    settings = host / 'Settings.bundle/Root.plist'
    data = plistlib.loads(settings.read_bytes())
    if not any(p.get('Key') == 'LCOpenSideStore' for p in data['PreferenceSpecifiers']):
        data['PreferenceSpecifiers'].insert(3, {'Type': 'PSToggleSwitchSpecifier', 'Title': 'Open SideStore',
                                               'Key': 'LCOpenSideStore', 'DefaultValue': False})
    settings.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_BINARY))
    run(['zip', '-qry', str(work / 'lc-nightly.ipa'), 'Payload'], cwd=host.parents[1])


def package(root):
    work, out = root / 'work', root / 'outputs'
    require((work / 'archive.ok').exists(), 'Run build first')
    validate_source(work, allow_generated=True)
    for log in ['build-zh-release.log', 'build-lc-release.log']:
        require('** ARCHIVE SUCCEEDED **' in (work / log).read_text(), 'Archive failed: ' + log)
    require(not (work / 'lc-base').exists(), 'Preserve previous staging generation')
    make_host_baseline(work)
    source = work / 'SideStore-zh-final.xcarchive/Products/Applications/SideStore.app'
    payload = work / 'source-ipa/Payload'
    payload.mkdir(parents=True)
    shutil.copytree(source, payload / 'SideStore.app', symlinks=True)
    run(['zip', '-qry', str(work / 'ss-zh-local.ipa'), 'Payload'], cwd=payload.parent)
    run([sys.executable, str(work / 'repack_zh.py')])
    run([sys.executable, str(work / 'verify_package.py'), '--ipa', ARTIFACT,
         '--source-ipa', 'ss-zh-local.ipa', '--stage', 'merged-zh', '--report', 'verification-zh.json'])
    with zipfile.ZipFile(out / ARTIFACT) as archive:
        prefix = 'Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/'
        table = plistlib.loads(archive.read(prefix + 'zh-Hans.lproj/Localizable.strings'))
        require(table['My Apps'] == '我的应用', 'Missing Chinese resources')
        binary = archive.read(prefix + 'SideStore')
        for text in ['欢迎使用 SideStore', '配对文件管理', 'Anisette 客户端配置']:
            require(text.encode() in binary, 'Missing compiled text: ' + text)
    for name in ['build-provenance.json', 'zh-source-audit.json', 'source-manifest.json']:
        shutil.copy2(work / name, out / name)
    report = read_json(out / 'verification-zh.json')
    report['translation_entries'] = len(table)
    report['ui_visual_validation'] = 'UNRUN'
    provenance = read_json(work / 'build-provenance.json')
    provenance['package_recipe'] = {name: digest(path) for path, name in recipe_files()}
    write_json(out / 'build-provenance.json', provenance)
    write_json(out / 'verification-zh.json', report)
    (out / 'SHA256SUMS.txt').write_text(f'{digest(out / ARTIFACT)}  {ARTIFACT}\n')
    with zipfile.ZipFile(out / 'source-recipe.zip', 'w', zipfile.ZIP_DEFLATED) as recipe:
        for path, name in recipe_files():
            recipe.write(path, name)
        recipe.write(work / 'SideStore' / PACKAGE_LOCK, 'resolved-build/Package.resolved')
        recipe.write(out / 'build-provenance.json', 'resolved-build/build-provenance.json')
    print('Package and static checks passed:', out / ARTIFACT)


def mark_success(root):
    require((root / 'outputs/verification-zh.json').exists(), 'No verified output')
    state = BASE / '.last-success'
    state.mkdir(exist_ok=True)
    write_json(state / 'state.json', {'fingerprint': read_json(root / 'candidate.json')['fingerprint']})


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('step', choices=['check', 'prepare', 'build', 'package', 'mark-success'])
    parser.add_argument('--build-root', type=Path, default=BASE / '.build')
    parser.add_argument('--pinned', action='store_true', help='Use historical pinned source commits')
    parser.add_argument('--force', action='store_true', help='Build unchanged scheduled inputs')
    parser.add_argument('--source-mirror', type=Path, help='Use existing local Git repositories')
    args = parser.parse_args()
    for name, expected in LOCK['files'].items():
        require(digest(BASE / name) == expected, 'Recipe hash mismatch: ' + name)
    root = args.build_root.resolve()
    if args.step == 'check':
        check(root, args)
    elif args.step == 'prepare':
        prepare(root, args)
    elif args.step == 'build':
        build(root)
    elif args.step == 'package':
        package(root)
    else:
        mark_success(root)
