#!/bin/zsh
set -eu
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
RUNTIME="$HOME/Library/Application Support/Research OS 2/runtime"
PYTHON="${RESEARCHOS_PYTHON:-$(command -v python3 || true)}"
if [[ -z "$PYTHON" ]]; then
  echo 'Install Python 3.10+ first (python.org or brew install python@3.12).'
  exit 1
fi
"$PYTHON" -c 'import sys; assert sys.version_info >= (3,10), "Python 3.10+ is required"'
"$PYTHON" -m venv "$RUNTIME"
"$RUNTIME/bin/python3" -m pip install -r requirements.txt
if ! command -v codex >/dev/null; then
  echo 'Install Codex with: brew install --cask codex. Then sign in with ChatGPT inside the app.'
else
  codex --version
fi
echo 'Dependencies are ready. Reopen Research OS 2.app. Optional OCR for scanned PDFs: brew install tesseract'
