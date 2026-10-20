#!/usr/bin/env python3
"""Assemble the private-sharing edition from an already built app and runtime.

All inputs are explicit. Never reads the developer's application data, accounts,
Desktop libraries or login credentials. The output directory must be new.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
IGNORE = shutil.ignore_patterns('__pycache__', '*.pyc', '.DS_Store', '.git', '.build*')
MACHO = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}

def assemble(args):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    app = output / 'Research OS.app'
    shutil.copytree(args.app, app, symlinks=True, ignore=IGNORE)
    resources = app / 'Contents/Resources'
    # Always use the current service sources; no bootstrap connections are shared.
    shutil.rmtree(resources / 'service')
    shutil.copytree(ROOT / 'service', resources / 'service', ignore=IGNORE)
    (resources / 'service/initial-connections.json').write_text('[]\n')
    shutil.rmtree(app / 'Contents/PlugIns', ignore_errors=True)
    runtime = resources / 'python'
    shutil.copytree(args.runtime, runtime, symlinks=True, ignore=IGNORE)
    # Console-script shebangs from pip contain the build machine's absolute path.
    # Keep only the relocatable interpreter; modules remain usable through -m.
    for entry in (runtime / 'bin').iterdir():
        if entry.name not in {'python', 'python3', 'python3.12'}:
            entry.unlink()
    for path in runtime.rglob('*'):
        if path.is_symlink():
            resolved = path.resolve()
            if not resolved.is_relative_to(runtime.resolve()):
                raise RuntimeError('Runtime symlink escapes the bundle: ' + str(path))
    source_dir = output / 'Source'; source_dir.mkdir()
    for name in ('README.txt',):
        shutil.copy2(ROOT / 'Distribution' / name, output / 'Read me first.txt')
    for name in ('AGPL-3.0.txt', 'LICENSE-NOTICE.txt'):
        shutil.copy2(ROOT / 'Distribution' / name, source_dir / name)
    shutil.copytree(args.dependency_sources, source_dir / 'Dependency sources')
    # Explicit allowlist: never ship the developer README, validation logs or caches.
    with zipfile.ZipFile(source_dir / 'ResearchOS2-source.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in ('Sources', 'Resources', 'service', 'Scripts', 'Widget', 'Tests', 'Distribution', 'Design',
                     'Package.swift', 'build_app.sh', 'requirements.txt', 'PDFChat-LICENSE', 'Install Dependencies.command'):
            item = ROOT / name
            paths = item.rglob('*') if item.is_dir() else [item]
            for path in paths:
                if not path.is_file() or any(p in {'__pycache__', '.DS_Store'} for p in path.parts) or path.suffix == '.pyc':
                    continue
                relative = path.relative_to(ROOT)
                archive.write(path, str(Path('ResearchOS2') / relative))
        archive.write(ROOT / 'Distribution/BUILDING.md', 'ResearchOS2/README.md')
        archive.write(ROOT / 'Distribution/AGPL-3.0.txt', 'ResearchOS2/LICENSE')
    (output / 'Applications').symlink_to('/Applications')
    shutil.copy2(ROOT / 'Resources/ResearchOSBlue.icns', output / '.VolumeIcon.icns')
    # Re-sign nested native components after copying; preserve no ad hoc app-group entitlements.
    for path in sorted(runtime.rglob('*'), key=lambda p: len(p.parts), reverse=True):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as file:
            magic = file.read(4)
        if magic in MACHO:
            subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    manifest = {
        'version': plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'],
        'architecture': 'arm64', 'minimum_macos': '14.0', 'signing': 'ad-hoc; not notarized',
        'python': '3.12.15+20261013',
        'python_archive_sha256': '9866e11cf2ae9caa1e671383786f248859a52dd8bfb702fb4c0dc2c65f1d36de',
        'dependencies': (ROOT / 'requirements.txt').read_text().splitlines(),
        'codex': 'not bundled; optional official download 0.163.0',
        'source_sha256': hashlib.sha256((source_dir / 'ResearchOS2-source.zip').read_bytes()).hexdigest(),
    }
    (output / 'Build manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Distribution folder: ' + str(output))

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--runtime', required=True, type=Path)
    parser.add_argument('--dependency-sources', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    assemble(parser.parse_args())
