"""Explicit, per-user installation from a pinned OpenAI release; never reads credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import sys
import subprocess
import tarfile
import tempfile
import urllib.request

VERSION = '0.163.0'
URL = 'https://github.com/openai/codex/releases/download/rust-v0.163.0/codex-package-aarch64-apple-darwin.tar.gz'
SHA256 = 'b0344fc2e41f15e0071147e5869008047b8ff4bf2c4a8897975d3bae3f103b34'

def install(destination):
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise RuntimeError('This installer requires an Apple Silicon Mac.')
    destination.mkdir(parents=True, exist_ok=True)
    versions = destination.parent / 'codex-versions'
    versions.mkdir(exist_ok=True)
    target = versions / VERSION
    if not (target / 'bin/codex').is_file():
        with tempfile.TemporaryDirectory(prefix='.download-', dir=versions) as scratch:
            scratch = Path(scratch)
            archive = scratch / 'codex.tar.gz'
            # Use macOS's TLS trust store; no Python certificate setup is required.
            command = ['/usr/bin/curl', '--fail', '--location', '--proto', '=https',
                       '--proto-redir', '=https', '--connect-timeout', '15',
                       '--max-time', '600', '--retry', '2', '--output', str(archive)]
            proxy = urllib.request.getproxies().get('https')
            if proxy:
                command.extend(['--proxy', proxy])
            try:
                subprocess.run(command + [URL], check=True)
            except subprocess.CalledProcessError:
                raise RuntimeError('Download failed. Check your connection to GitHub and retry, or use the manual installation instructions.') from None
            digest = hashlib.sha256()
            with archive.open('rb') as downloaded:
                while chunk := downloaded.read(1024 * 1024):
                    digest.update(chunk)
            if digest.hexdigest() != SHA256:
                raise RuntimeError('Download checksum mismatch. Nothing was installed. Please retry.')
            unpacked = scratch / 'unpacked'; unpacked.mkdir()
            with tarfile.open(archive) as bundle:
                bundle.extractall(unpacked, filter='data')
            manifests = list(unpacked.glob('codex-package.json')) + list(unpacked.glob('*/codex-package.json'))
            if len(manifests) != 1:
                raise RuntimeError('Unexpected Codex package layout.')
            package = manifests[0].parent
            info = json.loads(manifests[0].read_text())
            if info.get('version') != VERSION or info.get('entrypoint') != 'bin/codex':
                raise RuntimeError('Unexpected Codex package version or entry point.')
            executable = package / 'bin/codex'
            if not executable.is_file():
                raise RuntimeError('Codex executable is missing.')
            executable.chmod(executable.stat().st_mode | 0o111)
            # Do not replace a prior version directory or any system installation.
            if target.exists():
                raise RuntimeError('An incomplete Codex installation exists. See ' + str(target))
            shutil.move(str(package), target)
    link = destination / 'codex'
    if link.exists() and not link.is_symlink():
        raise RuntimeError('An existing file was preserved at ' + str(link))
    temporary = destination / ('.codex-' + str(os.getpid()))
    try:
        temporary.symlink_to(os.path.relpath(target / 'bin/codex', destination))
        temporary.replace(link)
    finally:
        temporary.unlink(missing_ok=True)
    print('Codex ' + VERSION + ' installed. Sign in with your own account.', flush=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--destination', required=True, type=Path)
    try:
        install(parser.parse_args().destination)
    except Exception as error:
        print(str(error), file=sys.stderr, flush=True)
        sys.exit(1)
