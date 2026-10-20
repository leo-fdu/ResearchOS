# Research OS shared edition

Native macOS 14+ app. This release targets Apple Silicon. Full application source,
resources, build scripts and dependency source archives accompany the distribution.
See LICENSE and Distribution/LICENSE-NOTICE.txt for licensing.

## Build the app

Install full Xcode. From this directory, run `./build_app.sh`.
`RESEARCHOS_BUILD_ROOT` selects a scratch directory, and `RESEARCHOS_APP_OUTPUT`
selects the output `.app` path. The script performs an ad hoc signature.

For source development, Python 3.10+ and `Install Dependencies.command` are also
supported. The shared edition includes its own Python runtime instead.

## Reproduce the shared runtime

Download this upstream archive and verify SHA-256 before extracting:
https://github.com/astral-sh/python-build-standalone/releases/download/20261013/cpython-3.12.15%2B20261013-aarch64-apple-darwin-install_only_stripped.tar.gz

SHA-256: `9866e11cf2ae9caa1e671383786f248859a52dd8bfb702fb4c0dc2c65f1d36de`

Extract into a build directory, then run:

```sh
python/bin/python3 -m pip install --only-binary=:all: --no-compile -r requirements.txt
```

Keep upstream Python and dependency license files. Obtain the matching PyMuPDF
and PyMuPDF4LLM source archives from PyPI (or use the copies provided alongside
this source archive). The matching MuPDF source archive is supplied separately.

```sh
python3 Scripts/package_share.py --app '/path/to/Research OS.app' \
  --runtime '/path/to/python' --dependency-sources '/path/to/Dependency sources' \
  --output '/path/to/new-staging-directory'
hdiutil create -volname 'Research OS' -srcfolder '/path/to/new-staging-directory' \
  -ov -format UDZO '/path/to/Research-OS-2.0.17-AppleSilicon.dmg'
```

The packaging script excludes workspace databases and developer caches, clears
bootstrap folders, removes the unsupported WidgetKit extension, strips runtime
console scripts with absolute build paths, signs nested native libraries and
emits a manifest. Retain the Source folder when redistributing the DMG.

The included Codex installer is opt-in and pins OpenAI's 0.163.0 release and its
SHA-256. Existing Homebrew/system installations take precedence. No Codex account
or token is part of the package. Scanned-page OCR needs optional Tesseract.

## Signing boundary

The supplied package has no Developer ID signature and is not notarized. For a
public release, configure your own Developer ID identity and hardened runtime,
sign the nested code appropriately, submit with Apple's notarytool, and staple
the accepted ticket. Do not describe ad hoc signatures as Apple notarization.
