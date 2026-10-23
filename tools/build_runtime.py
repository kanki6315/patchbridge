#!/usr/bin/env python3
"""Build the bundled CPython and protobuf from pinned sources, keeping dSYMs for crash symbols.

Downloads only the pinned, hash-checked files below (cached under build/runtime-src/downloads)
and builds in a clean environment without Homebrew. Output: build/runtime.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/runtime'
SOURCES = ROOT / 'build/runtime-src'
PYTHON_VERSION = '3.14.6'
PROTOBUF_VERSION = '7.36.2'
MINIMUM_MACOS = '26.0'  # Intentional floor; see docs/MAC_PACKAGING.md.
PINNED = {
    f'Python-{PYTHON_VERSION}.tar.xz': (
        f'https://www.python.org/ftp/python/{PYTHON_VERSION}/Python-{PYTHON_VERSION}.tar.xz',
        '143b1dddefaec3bd2e21e3b839b34a2b7fb9842272883c576420d605e9f30c63'),
    f'protobuf-{PROTOBUF_VERSION}.tar.gz': (
        'https://files.pythonhosted.org/packages/d9/89/5b8517baa72f84a67b8a307ba953c91057af618bf40bf676f3c03551f8f0/protobuf-7.36.2.tar.gz',
        '497d0463ff3316681da6c0b9e8d06cb465d61abce00b613ab42226175644d1bb'),
    # Build backend for protobuf's setup.py; not bundled.
    'setuptools-84.2.1-py3-none-any.whl': (
        'https://files.pythonhosted.org/packages/ef/55/6dc6d6bb953bdfc52519a0059592c52b6e3b8ad51cf8256dffceb55b0610/setuptools-84.2.1-py3-none-any.whl',
        'ca140b45d5325a9478f880e351484f62fef15f336462e449ca0c03c873d589c2'),
    'wheel-0.48.0-py3-none-any.whl': (
        'https://files.pythonhosted.org/packages/2e/29/69cfbb602cd91690c55d38ba9fe53e6a7e76a6fa647bf38f19c138d25449/wheel-0.48.0-py3-none-any.whl',
        '3217dcc807155e45db462d7ef2431f5ddda0d7273b700d05a67b271ceb1287ab'),
}
# No Homebrew, pkg-config or user Python configuration can leak into the build.
ENV = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(Path.home()), 'LANG': 'en_US.UTF-8',
       'MACOSX_DEPLOYMENT_TARGET': MINIMUM_MACOS, 'CC': '/usr/bin/clang',
       **{k: os.environ[k] for k in ('DEVELOPER_DIR',) if k in os.environ}}


def run(*args, cwd=None, env=ENV):
    subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, check=True)


def output(*args):
    return subprocess.check_output([str(arg) for arg in args], env=ENV, text=True)


def fetch(name):
    url, digest = PINNED[name]
    path = SOURCES / 'downloads' / name
    if not path.is_file():
        path.parent.mkdir(parents=True, exist_ok=True)
        partial = path.with_suffix('.partial')
        with urllib.request.urlopen(url) as response, partial.open('wb') as file:
            shutil.copyfileobj(response, file)
        partial.replace(path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise SystemExit(f'SHA-256 mismatch for {name}; delete it and retry.')
    return path


def uuids(path):
    return set(re.findall(r'UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)', output('xcrun', 'dwarfdump', '--uuid', path)))


def symbolize(binary, dsyms):
    """dsymutil needs the build tree's object files, so this runs before anything is cleaned."""
    dsym = dsyms / (binary.name + '.dSYM')
    run('xcrun', 'dsymutil', binary, '-o', dsym)
    dwarf = dsym / 'Contents/Resources/DWARF' / binary.name
    if not uuids(binary) or uuids(dwarf) != uuids(binary):
        raise SystemExit(f'dSYM UUIDs do not match {binary.name}.')
    if 'DW_TAG_compile_unit' not in output('xcrun', 'dwarfdump', '--debug-info', dwarf):
        raise SystemExit(f'No debug information for {binary.name}.')
    return {binary.name: sorted(uuid for uuid, _ in uuids(binary))}


def main():
    if sys.platform != 'darwin' or os.uname().machine != 'arm64':
        raise SystemExit('The bundled runtime is built on Apple silicon macOS.')
    archives = {name: fetch(name) for name in PINNED}
    work = SOURCES / 'work'
    for directory in (work, OUT):
        if directory.exists():
            shutil.rmtree(directory)  # Only these fixed generated directories.
    work.mkdir(parents=True)
    for name in (f'Python-{PYTHON_VERSION}.tar.xz', f'protobuf-{PROTOBUF_VERSION}.tar.gz'):
        run('tar', '-xf', archives[name], '-C', work)
    cpython = work / f'Python-{PYTHON_VERSION}'
    # A */Library/Frameworks location keeps the apps and bin links under OUT too.
    # No LTO or PGO: object files stay ordinary so dsymutil can read their DWARF.
    # The macOS 27 SDK declares dup3/pipe2, which macOS 26 lacks and CPython calls unguarded.
    run('./configure', f'--enable-framework={OUT}/Library/Frameworks', '--with-ensurepip=install',
        '--with-pkg-config=no', '--without-static-libpython', '--with-app-store-compliance',
        'ac_cv_func_dup3=no', 'ac_cv_func_pipe2=no', cwd=cpython)
    run('make', f'-j{os.cpu_count()}', cwd=cpython)
    run('make', 'altinstall', cwd=cpython)
    prefix = OUT / 'Library/Frameworks/Python.framework/Versions/3.14'
    python = prefix / 'bin/python3.14'
    if output('otool', '-l', prefix / 'Python').count(f'minos {MINIMUM_MACOS}') != 1:
        raise SystemExit(f'Runtime is not built for macOS {MINIMUM_MACOS}.')
    for name in ('setuptools-84.2.1-py3-none-any.whl', 'wheel-0.48.0-py3-none-any.whl'):
        run(python, '-m', 'pip', 'install', '--no-index', '--no-deps', '--disable-pip-version-check', '--no-cache-dir', archives[name])
    protobuf = work / f'protobuf-{PROTOBUF_VERSION}'
    wheels = work / 'wheels'
    # An in-tree build keeps protobuf's objects under its build/ directory for dsymutil.
    run(python, '-m', 'pip', 'wheel', '--no-index', '--no-deps', '--no-build-isolation',
        '--disable-pip-version-check', '--no-cache-dir', '-w', wheels, protobuf)
    run(python, '-m', 'pip', 'install', '--no-index', '--no-deps', '--disable-pip-version-check', '--no-cache-dir',
        *wheels.glob(f'protobuf-{PROTOBUF_VERSION}-*.whl'))
    dsyms = OUT / 'dSYMs'
    dsyms.mkdir()
    site = prefix / 'lib/python3.14/site-packages'
    binaries = [prefix / 'Python', *sorted((prefix / 'lib/python3.14/lib-dynload').glob('*.so')),
                *site.glob('google/_upb/*.so')]
    symbols = {}
    for binary in binaries:
        symbols.update(symbolize(binary, dsyms))
    manifest = {'python': PYTHON_VERSION, 'protobuf': PROTOBUF_VERSION, 'architecture': 'arm64',
                'minimum_macos': MINIMUM_MACOS, 'app_store_compliance': True,
                'sources': {name: digest for name, (_, digest) in PINNED.items()}, 'dsym_uuids': symbols}
    (OUT / 'runtime-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Built {python}\n{len(symbols)} binaries with matching dSYMs in {dsyms}')


if __name__ == '__main__':
    main()
