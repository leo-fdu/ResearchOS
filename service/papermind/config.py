import os
from pathlib import Path
PAPER_ROOT = Path(os.environ.get("PAPERMIND_ROOT", str(Path.home()/"Desktop/paper"))).expanduser()
PDF_ROOT = PAPER_ROOT/"pdf"
MARKDOWN_ROOT = PAPER_ROOT/"markdown"
def ensure_directories():
    PDF_ROOT.mkdir(parents=True,exist_ok=True)
    MARKDOWN_ROOT.mkdir(parents=True,exist_ok=True)
