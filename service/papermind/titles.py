"""Local, evidence-checked title extraction. Filenames are not paper identities."""
from __future__ import annotations

import html
import re
import unicodedata
from dataclasses import dataclass


@dataclass(frozen=True)
class TitleResult:
    title: str
    source: str
    verified: bool


def clean_title(text: str) -> str:
    text = unicodedata.normalize("NFKC", html.unescape(text))
    text = text.replace("\u00ad", "").replace("\x00", "")
    return " ".join(text.split()).strip(" †‡*")


def title_key(text: str) -> str:
    return "".join(c for c in clean_title(text).casefold() if c.isalnum())


def is_bad_title(title: str | None, file_stem: str = "") -> bool:
    # Equality to an already-correct filename is NOT an error.
    value = clean_title(title or "")
    if not 5 <= len(value) <= 500:
        return True
    if value.casefold() in {"untitled", "download", "fulltext", "manuscript", "article", "paper", "pdf"}:
        return True
    if re.fullmatch(r"\d{4}\.\d{4,5}(v\d+)?", value) or value.lower().endswith((".pdf", ".doc", ".docx")):
        return True
    if re.search(r"(?:\d+\.\.\d+|Microsoft Word|SpringerNature_|doi:|https?://)", value, re.I):
        return True
    return sum(c.isalpha() for c in value) / len(value) < 0.4


def _noise(text: str) -> bool:
    return bool(re.match(
        r"^(?:abstract\b|introduction\b|\d+\.?\s+introduction\b|[■▪]|access$|"
        r"research article$|review(?: article)?$|analysis$|perspectives$|"
        r"article$|open access$|check for updates|published as|accepted|"
        r"contents lists|journal homepage|www\.|https?://|arxiv:|"
        r"(?:international )?journal of |nature reviews |communications (?:chemistry|biology)$|"
        r"chemical society reviews$|chem soc rev$|chemical$|science$)", text, re.I))


def layout_titles(page) -> list[tuple[float, str]]:
    """Join spatially adjacent title lines, including PDF small-cap spans."""
    lines = []
    for block in page.get_text("dict")["blocks"]:
        for line in block.get("lines", []):
            if abs(line.get("dir", (1, 0))[1]) > 0.1:
                continue
            spans = line["spans"]
            if not spans or not any(s["text"].strip() for s in spans):
                continue
            text = clean_title("".join(s["text"] for s in spans))
            x0, y0, x1, y1 = line["bbox"]
            if not text or not any(c.isalpha() for c in text) or y0 > page.rect.height * 0.65:
                continue
            size = max(s["size"] for s in spans if s["text"].strip())
            lines.append((y0, x0, y1, x1, size, text))
    lines.sort()
    merged = []
    for line in lines:
        if merged and abs(line[0] - merged[-1][0]) < 2 and abs(line[4] - merged[-1][4]) < 1 and 0 <= line[1] - merged[-1][3] < line[4] * 2:
            prev = merged.pop()
            merged.append((min(prev[0], line[0]), prev[1], max(prev[2], line[2]), line[3], max(prev[4], line[4]), prev[5] + " " + line[5]))
        else:
            merged.append(line)
    lines = merged
    candidates = []
    for i, first in enumerate(lines):
        if first[4] < 11 or _noise(first[5]):
            continue
        group = [first]
        for nxt in lines[i + 1:]:
            prev = group[-1]
            if nxt[0] - prev[2] > first[4] * 1.1:
                break
            if min(nxt[3], prev[3]) < max(nxt[1], prev[1]):
                continue
            if abs(nxt[4] - first[4]) > first[4] * .13 or _noise(nxt[5]):
                break
            # Do not join columns, author superscripts, or adjacent journal badges.
            if nxt[0] < prev[2] - first[4] * .5:
                break
            group.append(nxt)
            if len(group) >= 8:
                break
        title = clean_title(" ".join(x[5] for x in group))
        title = re.sub(r"(?<=\w)-\s+(?=\w)", "-", title)
        if is_bad_title(title) or len(title.split()) < 3:
            continue
        score = first[4] + min(len(title), 160) / 35 - first[0] / page.rect.height * 3
        candidates.append((score, title))
    return sorted(candidates, reverse=True)


def identify_title(doc, filename: str) -> TitleResult:
    meta = clean_title((doc.metadata or {}).get("title") or "")
    pages = [doc[i] for i in range(min(3, len(doc)))]
    evidence = [title_key(re.sub(r"(?m)^\s*\d+\s*$", "", p.get_text())) for p in pages]
    meta_supported = not is_bad_title(meta) and any(title_key(meta) in t for t in evidence)
    candidates = []
    for page in pages:
        candidates.extend(layout_titles(page))
        # Later pages are for covers only, not for choosing large section headings.
        if len(page.get_text().strip()) > 500 and candidates:
            break
    candidates.sort(reverse=True)
    if meta_supported:
        # Reject short / truncated metadata when the heading supplies its continuation.
        for _, title in candidates[:1]:
            if len(meta.split()) < 4 and title_key(title).startswith(title_key(meta)) and len(title_key(title)) > len(title_key(meta)) * 1.12:
                return TitleResult(title, "first-page-layout", True)
        return TitleResult(meta, "pdf-metadata-checked-against-text", True)
    if candidates:
        title = candidates[0][1]
        # Repair line-end word splits only when the filename independently agrees
        # with the entire extracted title and supplies the unsplit spelling.
        if title_key(title) == title_key(filename):
            words = set(re.findall(r"[A-Za-z]+(?:-[A-Za-z]+)*", filename.casefold()))
            title = re.sub(r"([A-Za-z]+)-([A-Za-z]+)",
                           lambda m: m[1] + m[2] if (m[1] + m[2]).casefold() in words else m[0], title)
        return TitleResult(title, "first-page-layout", True)
    return TitleResult(clean_title(filename), "filename-needs-review", False)
