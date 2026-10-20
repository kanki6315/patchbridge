#!/usr/bin/env python3
"""Build, archive, verify and upload Patchbridge for Mac. Upload is the default."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(*args, capture=False):
    result = subprocess.run(list(map(str, args)), cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def verify_app(app, team, bundle, version, build):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    for key, expected in [('CFBundleIdentifier', bundle), ('CFBundleVersion', build),
                          ('CFBundleShortVersionString', version)]:
        if info.get(key) != expected:
            raise ValueError(f'Exported {key} differs from the requested release.')
    run('codesign', '--verify', '--deep', '--strict', app)
    for binary, required in [(app, {'com.apple.security.app-sandbox', 'com.apple.security.device.usb',
                                     'com.apple.security.device.bluetooth', 'com.apple.security.files.user-selected.read-write'}),
                             (app / 'Contents/MacOS/patchbridge-helper', {'com.apple.security.app-sandbox', 'com.apple.security.inherit'})]:
        entitlements = plistlib.loads(run('codesign', '-d', '--entitlements', ':-', binary, capture=True).encode())
        if any(entitlements.get(key) is not True for key in required) or entitlements.get('com.apple.security.get-task-allow'):
            raise ValueError('Exported sandbox entitlements are missing or permit debugging.')
        if binary != app and set(entitlements) != required:
            raise ValueError('The helper must have only sandbox and inheritance entitlements.')
        signature = subprocess.run(['codesign', '-dvv', str(binary)], capture_output=True, text=True, check=True)
        if f'TeamIdentifier={team}' not in signature.stderr:
            raise ValueError('Exported code signing team does not match the release team.')
    nested = [app, app / 'Contents/MacOS/patchbridge-helper', app / 'Contents/Frameworks/Python',
              *sorted((app / 'Contents/Resources').rglob('*.so'))]
    for binary in nested:
        signature = subprocess.run(['codesign', '-dvv', str(binary)], capture_output=True, text=True, check=True).stderr
        if f'TeamIdentifier={team}' not in signature or not any(
                authority in signature for authority in ('Authority=Apple Distribution:', 'Authority=3rd Party Mac Developer Application:')):
            raise ValueError('Every embedded binary must use this team’s App Store distribution signature.')
    if not (app / 'Contents/embedded.provisionprofile').is_file():
        raise ValueError('Exported app is missing its distribution provisioning profile.')


def archive_helper_symbols(archive, symbols):
    binary = archive / 'Products/Applications/Patchbridge.app/Contents/MacOS/patchbridge-helper'
    dwarf = symbols / 'Contents/Resources/DWARF/patchbridge-helper'
    def uuids(path):
        return set(re.findall(r'UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)',
                              run('xcrun', 'dwarfdump', '--uuid', path, capture=True)))
    expected = uuids(binary)
    if not expected or uuids(dwarf) != expected:
        raise ValueError('Helper dSYM UUIDs do not match the archived helper.')
    if 'DW_TAG_compile_unit' not in run('xcrun', 'dwarfdump', '--debug-info', dwarf, capture=True):
        raise ValueError('Helper dSYM contains no debug information.')
    destination = archive / 'dSYMs' / symbols.name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(symbols, destination)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-tests', action='store_true')
    parser.add_argument('--no-upload', action='store_true', help='Export and verify locally without uploading or tagging')
    parser.add_argument('--allow-dirty', action='store_true', help='Permit uncommitted changes; never create a tag')
    parser.add_argument('--build')
    args = parser.parse_args(argv)
    now = dt.datetime.now(dt.timezone.utc)
    build = args.build or f'{(now.date() - dt.date(2026, 1, 1)).days + 1}.{now.hour}.{now.minute}'
    if not re.fullmatch(r'[1-9][0-9]{0,3}(\.[0-9]{1,2}){0,2}', build):
        raise ValueError('Build must use up to 4/2/2 digits with a positive first component.')
    config = (ROOT / 'ios/project.yml').read_text()
    def setting(name):
        match = re.search(r'^\s+' + name + r':\s*[\"\']?([A-Za-z0-9.-]+)', config, re.M)
        if not match:
            raise ValueError(f'{name} missing from ios/project.yml')
        return match.group(1)
    team = os.environ.get('DEVELOPMENT_TEAM') or setting('DEVELOPMENT_TEAM')
    version, bundle = setting('MARKETING_VERSION'), setting('PRODUCT_BUNDLE_IDENTIFIER')
    dirty = bool(run('git', 'status', '--porcelain', '--', '.', capture=True))
    if dirty and not args.allow_dirty:
        raise ValueError('Commit changes, or pass --allow-dirty (no tag will be made).')
    commit = run('git', 'rev-parse', 'HEAD', capture=True)
    tag = f'macos/v{version}-{build}'
    if not args.no_upload and not dirty and run('git', 'tag', '--list', tag, capture=True):
        raise ValueError(f'Tag {tag} already exists; choose another build.')
    out = ROOT / 'build/release-macos' / f'{version}-{build}'
    if out.exists():
        raise ValueError(f'Output {out} already exists; choose another build. Prior release evidence is retained.')
    os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    if not Path(os.environ['DEVELOPER_DIR']).is_dir():
        raise ValueError('DEVELOPER_DIR must point to Xcode.')
    auth, upload_auth = [], []
    key_id = os.environ.get('ASC_KEY_ID')
    if not key_id and any(os.environ.get(k) for k in ('ASC_ISSUER_ID', 'ASC_KEY_PATH')):
        raise ValueError('ASC_ISSUER_ID / ASC_KEY_PATH require ASC_KEY_ID.')
    key = None
    if key_id:
        issuer = os.environ.get('ASC_ISSUER_ID')
        key = Path(os.environ.get('ASC_KEY_PATH', str(Path.home() / f'.appstoreconnect/private_keys/AuthKey_{key_id}.p8'))).expanduser()
        if not issuer or not key.is_file():
            raise ValueError('API-key authentication requires ASC_ISSUER_ID and an existing ASC_KEY_PATH.')
        auth = ['-authenticationKeyPath', key, '-authenticationKeyID', key_id, '-authenticationKeyIssuerID', issuer]
        upload_auth = ['--api-key', key_id, '--api-issuer', issuer, '--p8-file-path', key]
    elif not args.no_upload:
        user, password_key = os.environ.get('MAC_ASC_USERNAME'), os.environ.get('MAC_ASC_PASSWORD_KEYCHAIN')
        if bool(user) != bool(password_key):
            raise ValueError('Set both MAC_ASC_USERNAME and MAC_ASC_PASSWORD_KEYCHAIN, or neither to use the Apple ID signed into Xcode.')
        if user:
            upload_auth = ['--username', user, '--password', f'@keychain:{password_key}']
    out.mkdir(parents=True)
    (out / 'release-source.json').write_text(json.dumps(
        dict(commit=commit, dirty=dirty, version=version, build=build), indent=2) + '\n')
    print(f'Patchbridge Mac {version} ({build}); upload={not args.no_upload}', flush=True)
    # Existing packager validates the isolated runtime closure before it can enter an archive.
    run(sys.executable, 'tools/package_mac.py')
    payload = out / 'Payload.app'
    shutil.copytree(ROOT / 'dist/Patchbridge.app', payload)
    symbols = out / 'patchbridge-helper.dSYM'
    shutil.copytree(ROOT / 'dist/dSYMs/patchbridge-helper.dSYM', symbols)
    if not args.skip_tests:
        run(sys.executable, 'tools/check_mac_package.py')
        env = dict(os.environ, PATCHBRIDGE_TEST_BUNDLE='1', PYTHON_BIN=sys.executable)
        subprocess.run(['sh', 'tools/check_offline.sh'], cwd=ROOT, env=env, check=True)
    project_dir = ROOT / 'mac'
    run('xcodegen', 'generate', '--spec', 'mac/project.yml')
    if not dirty and run('git', 'status', '--porcelain', '--', '.', capture=True):
        raise ValueError('Checkout changed before archive; review changes before releasing.')
    archive = out / 'Patchbridge.xcarchive'
    run('xcodebuild', 'archive', '-project', project_dir / 'PatchbridgeMac.xcodeproj', '-scheme', 'Patchbridge',
        '-configuration', 'Release', '-destination', 'generic/platform=macOS', '-archivePath', archive,
        '-derivedDataPath', out / 'DerivedData', '-allowProvisioningUpdates', *auth,
        f'PATCHBRIDGE_ROOT={ROOT}', f'PATCHBRIDGE_PAYLOAD={payload}', f'DEVELOPMENT_TEAM={team}',
        f'PRODUCT_BUNDLE_IDENTIFIER={bundle}', f'MARKETING_VERSION={version}', f'CURRENT_PROJECT_VERSION={build}',
        f'CODE_SIGN_ENTITLEMENTS={ROOT / "mac/Patchbridge.entitlements"}')
    archive_helper_symbols(archive, symbols)
    # The prebuilt Python framework and protobuf wheel have no recoverable DWARF.
    # Preserve our real dSYMs locally; don't request an incomplete symbol upload.
    options = dict(method='app-store-connect', destination='export', teamID=team, signingStyle='automatic',
                   uploadSymbols=False, manageAppVersionAndBuildNumber=False)
    if key:
        profile = run(sys.executable, 'asc_profile.py', '--platform', 'mac', '--key-id', key_id,
                      '--issuer-id', issuer, '--key-path', key, '--team', team, '--bundle-id', bundle,
                      '--name', 'Patchbridge Mac App Store', capture=True)
        options.update(signingStyle='manual', signingCertificate='Apple Distribution',
                       installerSigningCertificate='Mac Installer Distribution', provisioningProfiles={bundle: profile})
    options_path = out / 'ExportOptions.plist'
    options_path.write_bytes(plistlib.dumps(options))
    export = out / 'export'
    run('xcodebuild', '-exportArchive', '-archivePath', archive, '-exportPath', export,
        '-exportOptionsPlist', options_path, *([] if key else ['-allowProvisioningUpdates', *auth]))
    packages = list(export.glob('*.pkg'))
    if len(packages) != 1:
        raise ValueError('Expected exactly one exported installer package.')
    package = packages[0]
    run('pkgutil', '--check-signature', package)
    expanded = out / 'verified-package'
    run('pkgutil', '--expand-full', package, expanded)
    apps = list(expanded.rglob('*.app'))
    if len(apps) != 1:
        raise ValueError('Expected exactly one app in the installer.')
    verify_app(apps[0], team, bundle, version, build)
    if not args.no_upload:
        if run('git', 'rev-parse', 'HEAD', capture=True) != commit or (not dirty and run('git', 'status', '--porcelain', '--', '.', capture=True)):
            raise ValueError('Checkout changed during release; no upload or tag created.')
        if upload_auth:
            run('xcrun', 'altool', '--upload-app', '-f', package, *upload_auth)
        else:
            # Xcode can use its signed-in Apple ID; altool cannot. Verify a local
            # export first, then let Xcode export/upload the same archive.
            upload_options = out / 'UploadOptions.plist'
            upload_options.write_bytes(plistlib.dumps(dict(options, destination='upload')))
            run('xcodebuild', '-exportArchive', '-archivePath', archive,
                '-exportPath', out / 'upload', '-exportOptionsPlist', upload_options,
                '-allowProvisioningUpdates')
        if not dirty:
            if run('git', 'rev-parse', 'HEAD', capture=True) != commit or run('git', 'status', '--porcelain', '--', '.', capture=True):
                raise ValueError('Upload completed but checkout changed; no tag created.')
            run('git', 'tag', '-a', tag, commit, '-m', f'Patchbridge Mac {version} ({build})')
        print('Uploaded. Apple processing/acceptance remains pending; no Git tags were pushed.')
    else:
        print(f'Verified package: {package}. Nothing uploaded or tagged.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
