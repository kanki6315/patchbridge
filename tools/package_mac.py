#!/usr/bin/env python3
"""Bundle the source-built Python/USB dependency closure; startup stays stopped. No downloads."""
import base64
import csv
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import sysconfig

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'dist' / 'Patchbridge.app'
QC_COMMIT = 'f634ecd3dcf426090b90bc4cc176e4b500494b9e'
QC_SOURCE = ROOT / 'vendor' / 'qc-mcp'
# Generated locally from Cortex Control and kept out of Git (vendor/qc-mcp/VENDORED.md).
# The digest is upstream's file at QC_COMMIT, so a different schema fails the build.
QC_DESCRIPTORS = {'qc_descriptors-4.1.pb': 'eed223846169c1beb7a62b76c288d04d541fd1d5fd1853d0a2d8f68660f530c7'}
PROTOBUF_VERSION = '7.36.2'
# Built by tools/build_runtime.py with debug information and matching dSYMs.
RUNTIME = ROOT / 'build/runtime'
PREFIX = RUNTIME / 'Library/Frameworks/Python.framework/Versions/3.14'
SITE = PREFIX / 'lib/python3.14/site-packages'
PROTOBUF_EXTENSION = 'google/_upb/_message.cpython-314-darwin.so'


def bundle_usb(resources):
    # The vendored qc-mcp at QC_COMMIT with Patchbridge's local changes; nothing is fetched.
    package = QC_SOURCE / 'src' / 'qc_mcp'
    destination = resources / 'Helper' / 'qc_mcp'
    (destination / 'descriptors').mkdir(parents=True)
    for name in ['__init__.py', 'transport.py', 'protocol.py', 'backend.py', 'iohid.py', 'preset.py', 'directory.py']:
        shutil.copy2(package / name, destination / name)
    for name, digest in QC_DESCRIPTORS.items():
        source = package / 'descriptors' / name
        if not source.is_file():
            raise SystemExit(f'Missing {name}; generate it as vendor/qc-mcp/VENDORED.md describes.')
        if hashlib.sha256(source.read_bytes()).hexdigest() != digest:
            raise SystemExit(f'{name} differs from the schema qc-mcp {QC_COMMIT[:7]} shipped.')
        shutil.copy2(source, destination / 'descriptors' / name)
    shutil.copy2(QC_SOURCE / 'LICENSE', resources / 'Licenses' / 'qc-mcp-LICENSE.txt')
    dist = SITE / f'protobuf-{PROTOBUF_VERSION}.dist-info'
    if f'Version: {PROTOBUF_VERSION}\n' not in (dist / 'METADATA').read_text():
        raise SystemExit('Unexpected protobuf version.')
    records = {row[0]: row[1:] for row in csv.reader((dist / 'RECORD').read_text().splitlines())}
    for package in ('google/protobuf', 'google/_upb'):
        for source in (SITE / package).rglob('*'):
            if not source.is_file() or '__pycache__' in source.parts:
                continue
            relative = source.relative_to(SITE).as_posix()
            digest, size = records[relative]
            actual = base64.urlsafe_b64encode(hashlib.sha256(source.read_bytes()).digest()).rstrip(b'=').decode()
            if digest != 'sha256=' + actual or int(size) != source.stat().st_size:
                raise SystemExit(f'Protobuf wheel RECORD mismatch: {relative}')
            target = resources / 'Helper' / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    native = resources / 'Helper' / PROTOBUF_EXTENSION
    if output('lipo', '-archs', native).split() != ['arm64']:
        thin = native.with_suffix('.arm64')
        run('lipo', native, '-thin', 'arm64', '-output', thin)
        thin.replace(native)
    run('install_name_tool', '-id', '@rpath/' + native.name, native)
    shutil.copy2(dist / 'licenses/LICENSE', resources / 'Licenses/protobuf-LICENSE.txt')



def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def output(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True)


def copy_symbols(binary, original, symbols):
    """Pair a bundled runtime binary with the dSYM made when it was built."""
    source = RUNTIME / 'dSYMs' / (original.name + '.dSYM')
    def uuids(path):
        return set(re.findall(r'UUID: (\S+) \((\S+)\)', output('xcrun', 'dwarfdump', '--uuid', path)))
    if not source.is_dir() or uuids(source / 'Contents/Resources/DWARF' / original.name) != uuids(binary):
        raise SystemExit(f'No matching dSYM for {binary.name}; rebuild with tools/build_runtime.py.')
    shutil.copytree(source, symbols / source.name)


def build_helper(launcher, runtime, minimum, symbols):
    """Keep the object alive until dsymutil has collected its DWARF."""
    symbols.mkdir(parents=True, exist_ok=True)
    obj = symbols / 'patchbridge-helper.o'
    dsym = symbols / 'patchbridge-helper.dSYM'
    if dsym.exists():
        shutil.rmtree(dsym)
    run('xcrun', 'clang', '-g', '-arch', 'arm64', f'-mmacosx-version-min={minimum}',
        '-I' + sysconfig.get_path('include'), '-c', ROOT / 'mac/helper_launcher.c',
        '-o', obj)
    run('xcrun', 'clang', '-arch', 'arm64', f'-mmacosx-version-min={minimum}',
        obj, runtime, '-o', launcher)
    run('xcrun', 'dsymutil', launcher, '-o', dsym)
    obj.unlink()


def verify_app_store_stdlib(stdlib):
    """Reject cached runtimes without CPython's official App Store patch."""
    parser = stdlib / 'urllib' / 'parse.py'
    if not parser.is_file() or b'itms-services' in parser.read_bytes().lower():
        raise SystemExit('Python lacks the App Store compliance patch; rebuild with tools/build_runtime.py.')


def main():
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        raise SystemExit('This offline recipe requires Apple silicon macOS.')
    if Path(sys.base_prefix).resolve() != PREFIX.resolve():
        python = PREFIX / 'bin/python3.14'
        if not python.is_file():
            raise SystemExit('Build the runtime first: /opt/homebrew/bin/python3 tools/build_runtime.py')
        os.execv(python, [str(python), '-I', __file__, *sys.argv[1:]])
    runtime = PREFIX / 'Python'
    stdlib = Path(sysconfig.get_path('stdlib'))
    if not runtime.is_file():
        raise SystemExit('Expected a local framework CPython build; no runtime will be downloaded.')
    verify_app_store_stdlib(stdlib)
    minimum = re.search(r'\bminos\s+(\S+)', output('otool', '-l', runtime)).group(1)
    symbols = ROOT / 'dist/dSYMs'
    for generated in (APP, symbols):
        if generated.exists():
            shutil.rmtree(generated)  # Only the fixed generated outputs, never caller-supplied paths.
    symbols.mkdir(parents=True)
    contents = APP / 'Contents'
    executables = contents / 'MacOS'
    resources = contents / 'Resources'
    frameworks = contents / 'Frameworks'
    for directory in (executables, resources, frameworks):
        directory.mkdir(parents=True, exist_ok=True)
    shutil.copy2(runtime, frameworks / 'Python')
    run('install_name_tool', '-id', '@rpath/Python', frameworks / 'Python')
    shutil.copytree(stdlib, resources / 'Python' / 'lib', ignore=shutil.ignore_patterns(
        '__pycache__', '*.pyc', 'site-packages', 'lib-dynload', 'test', 'tests', 'idlelib', 'tkinter', 'ensurepip', 'config-*'))
    extensions = resources / 'Python' / 'lib-dynload'
    extensions.mkdir(parents=True)
    # Direct USB closure; optional OpenSSL/LZMA/Zstd modules are unnecessary.
    for name in ('_json', '_uuid', 'math', '_ctypes', '_struct', 'zlib', 'pyexpat',
                 '_elementtree', '_pickle', '_posixsubprocess', 'fcntl', 'select', 'grp',
                 'binascii', '_bz2', '_sha1', '_sha2', '_sha3', '_md5', '_blake2', '_random'):
        matches = list((stdlib / 'lib-dynload').glob(name + '.*.so'))
        if len(matches) != 1:
            raise SystemExit(f'Missing or ambiguous runtime extension: {name}')
        shutil.copy2(matches[0], extensions / matches[0].name)
    helper = resources / 'Helper' / 'patchbridge'
    helper.mkdir(parents=True)
    for name in ('__init__.py', 'adapter.py', 'helper.py', 'simulator.py', 'usb.py', 'metadata.py', 'offline_usb_check.py', 'read_only.py', 'captured.py', 'tuner.py'):
        shutil.copy2(ROOT / 'src' / 'patchbridge' / name, helper / name)
    (resources / 'Licenses').mkdir()
    shutil.copy2(stdlib / 'LICENSE.txt', resources / 'Licenses' / 'Python-LICENSE.txt')
    bundle_usb(resources)
    launcher = executables / 'patchbridge-helper'
    build_helper(launcher, runtime, minimum, symbols)
    run('install_name_tool', '-change', str(runtime), '@loader_path/../Frameworks/Python', launcher)
    # The linker may use the framework's LC_ID_DYLIB rather than its supplied path.
    original_id = output('otool', '-D', runtime).splitlines()[1].strip()
    if original_id != str(runtime):
        run('install_name_tool', '-change', original_id, '@loader_path/../Frameworks/Python', launcher)
    run('xcrun', 'swiftc', '-target', f'arm64-apple-macosx{minimum}', '-module-cache-path',
        '/private/tmp/patchbridge-package-module-cache', '-framework', 'AppKit',
        ROOT / 'swift' / 'Sources' / 'PatchbridgeCore' / 'HelperClient.swift',
        ROOT / 'swift' / 'Sources' / 'PatchbridgeCore' / 'Diagnostics.swift',
        ROOT / 'swift' / 'Sources' / 'PatchbridgeCore' / 'DeviceSession.swift',
        ROOT / 'swift' / 'Sources' / 'PatchbridgeCore' / 'SharedUSBSession.swift',
        ROOT / 'swift' / 'Sources' / 'PatchbridgeCore' / 'DeviceIdentity.swift',
        ROOT / 'swift' / 'Sources' / 'PatchbridgeCore' / 'MacBridgeModel.swift',
        ROOT / 'swift' / 'Sources' / 'PatchbridgeCore' / 'GenericEditor.swift',
        ROOT / 'swift' / 'Sources' / 'PatchbridgeCore' / 'MacDesktopServices.swift',
        ROOT / 'swift' / 'Sources' / 'PatchbridgeCore' / 'Chunks.swift',
        ROOT / 'swift' / 'Sources' / 'PatchbridgeCore' / 'BLEPeripheral.swift',
        ROOT / 'swift' / 'Sources' / 'PatchbridgeCore' / 'CentralRouter.swift',
        ROOT / 'swift' / 'Sources' / 'PatchbridgeCore' / 'LiveBridgeBackend.swift',
        ROOT / 'swift' / 'Sources' / 'PatchbridgeCore' / 'KeepAwake.swift',
        ROOT / 'mac' / 'main.swift', '-o', executables / 'Patchbridge')
    plist = {'CFBundleExecutable': 'Patchbridge', 'CFBundleIdentifier': 'com.arjunakankipati.patchbridge',
             'CFBundleName': 'Patchbridge', 'CFBundlePackageType': 'APPL',
             'CFBundleVersion': '1', 'CFBundleShortVersionString': '0.4.0',
             'LSMinimumSystemVersion': minimum, 'NSHighResolutionCapable': True,
             'NSBluetoothAlwaysUsageDescription': 'Connect your iPhone to this Mac to view and edit your Quad Cortex over USB.'}
    icon_plist = resources / 'icon-info.plist'
    run('xcrun', 'actool', ROOT / 'ios/Patchbridge/AppIcon.icon', '--compile', resources,
        '--platform', 'macosx', '--minimum-deployment-target', minimum, '--app-icon', 'AppIcon',
        '--output-partial-info-plist', icon_plist)
    plist.update(plistlib.loads(icon_plist.read_bytes()))
    icon_plist.unlink()
    (contents / 'Info.plist').write_bytes(plistlib.dumps(plist))
    copy_symbols(frameworks / 'Python', runtime, symbols)
    for extension in extensions.glob('*.so'):
        copy_symbols(extension, stdlib / 'lib-dynload' / extension.name, symbols)
    native = resources / 'Helper' / PROTOBUF_EXTENSION
    copy_symbols(native, SITE / PROTOBUF_EXTENSION, symbols)
    binaries = [frameworks / 'Python', *extensions.glob('*.so'), native, launcher, executables / 'Patchbridge']
    for binary in binaries:
        for line in output('otool', '-L', binary).splitlines()[1:]:
            dependency = line.strip().split(' (')[0]
            system = dependency.startswith(('/System/Library/', '/usr/lib/'))
            bundled_python = (binary == frameworks / 'Python' and dependency == '@rpath/Python') or (
                binary == launcher and dependency == '@loader_path/../Frameworks/Python')
            protobuf_id = binary == native and dependency == '@rpath/' + native.name
            if not (system or bundled_python or protobuf_id):
                raise SystemExit(f'External or unresolved runtime dependency: {binary}: {dependency}')
        run('codesign', '--force', '--sign', '-', binary)
    build_inputs = [ROOT / 'tools/package_mac.py', ROOT / 'tools/build_runtime.py', *sorted((ROOT / 'mac').glob('*')),
                    *sorted((ROOT / 'src/patchbridge').glob('*.py')),
                    *sorted((ROOT / 'swift/Sources/PatchbridgeCore').glob('*.swift')),
                    *sorted((ROOT / 'ios/Patchbridge/AppIcon.icon').rglob('*'))]
    manifest = {'build_inputs': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in build_inputs if p.is_file()}, 'python': sys.version, 'runtime': json.loads((RUNTIME / 'runtime-manifest.json').read_text()),
                'architecture': 'arm64', 'minimum_macos': minimum,
                'adapter': 'usb; simulation selectable; startup stopped', 'bundled_usb': {'qc_mcp_commit': QC_COMMIT, 'protobuf': PROTOBUF_VERSION, 'hardware_enabled': True}, 'signing': 'ad-hoc; not notarized',
                'files': {str(p.relative_to(contents)): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in sorted(contents.rglob('*')) if p.is_file()}}
    (resources / 'build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    run('codesign', '--force', '--sign', '-', APP)
    run('codesign', '--verify', '--deep', '--strict', APP)
    env = {'PATH': '/usr/bin:/bin', 'HOME': '/private/tmp', 'LANG': 'en_US.UTF-8',
           'PYTHONHOME': '/nonexistent', 'PYTHONPATH': '/nonexistent'}
    subprocess.run([str(executables / 'Patchbridge'), '--self-test'], env=env, cwd='/private/tmp', check=True, timeout=20)
    checked = subprocess.run([str(launcher), '--verify-usb-fixtures', str(ROOT)], env=env,
                             cwd='/private/tmp', text=True, capture_output=True, timeout=20)
    if checked.returncode:
        raise SystemExit(checked.stderr)
    print(checked.stdout)
    print(f'Built {APP} with dSYMs in {symbols}\nLocal arm64 macOS {minimum}+ bridge package. Starts stopped; live USB/Bluetooth requires Start bridge and phone approval.')


if __name__ == '__main__':
    main()
