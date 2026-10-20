from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


INVALID_FILENAME_CHARS = re.compile(r'[/:\\\n\r\t]+')
EXTRA_SPACES = re.compile(r"\s+")


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def sanitize_filename(name: str, fallback: str = "untitled") -> str:
    value = INVALID_FILENAME_CHARS.sub(" ", name or "")
    value = EXTRA_SPACES.sub(" ", value).strip(" .")
    if not value:
        value = fallback
    if len(value) > 180:
        value = value[:180].rstrip(" .")
    while len(value.encode("utf-8")) > 220:
        value = value[:-1]
    return value


def relative_to_root(path: Path, root: Path) -> Path:
    try:
        return path.resolve().relative_to(root.resolve())
    except ValueError:
        return Path(path.name)


def yaml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def estimate_tokens(text: str) -> int:
    if not text:
        return 0
    cjk = len(re.findall(r"[\u4e00-\u9fff]", text))
    non_cjk = len(text) - cjk
    return max(1, cjk + non_cjk // 4)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def write_text_no_overwrite(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise FileExistsError(f"Refusing to overwrite existing file: {path}")
    path.write_text(text, encoding="utf-8")


def parse_front_matter(text: str) -> tuple[dict[str, str], str]:
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---\n", 4)
    if end == -1:
        return {}, text
    raw = text[4:end].strip()
    body = text[end + 5 :]
    data: dict[str, str] = {}
    for line in raw.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        value = value.strip().strip('"')
        data[key.strip()] = value
    return data, body


def markdown_title(path: Path, text: str | None = None) -> str:
    content = text if text is not None else read_text(path)
    metadata, body = parse_front_matter(content)
    if metadata.get("title"):
        return metadata["title"]
    for line in body.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return path.stem


def save_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))
