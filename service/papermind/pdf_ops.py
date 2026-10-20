from __future__ import annotations

import hashlib
import fcntl
import json
import os
import re
import shutil
import subprocess
import tempfile
import unicodedata
import multiprocessing
from concurrent.futures import ProcessPoolExecutor
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote

from .config import MARKDOWN_ROOT, PDF_ROOT, ensure_directories
from .titles import TitleResult, identify_title, is_bad_title, title_key, clean_title
from .utils import now_iso, relative_to_root, sanitize_filename, yaml_string

EXTRACTOR_VERSION = "papermind-2"


@dataclass
class OrganizeResult:
    processed: int = 0
    skipped: int = 0
    warnings: int = 0
    stopped_at: str = ""
    remaining: int = 0


def import_fitz():
    try:
        import pymupdf
    except ImportError as exc:
        raise RuntimeError("PyMuPDF is required. Install PaperMind with pip install -e .") from exc
    return pymupdf


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_header(path: Path) -> dict:
    """Read our JSON-valued YAML scalars, tolerating older generated frontmatter."""
    with path.open(encoding="utf-8", errors="replace") as f:
        if f.readline().strip() != "---":
            return {}
        result = {}
        for line in f:
            if line.strip() == "---":
                return result
            if line.startswith(" ") or ":" not in line:
                continue
            key, value = line.rstrip().split(":", 1)
            try:
                result[key] = json.loads(value.strip())
            except ValueError:
                result[key] = value.strip().strip('"')
    return {}


def iter_pdfs() -> list[Path]:
    return sorted(p for p in PDF_ROOT.rglob("*") if p.is_file() and p.suffix.lower() == ".pdf")


def iter_markdown() -> list[Path]:
    return sorted(p for p in MARKDOWN_ROOT.rglob("*.md") if not p.name.endswith(".zh.md"))


def ocr_page(page):
    """Return a temporary searchable document, never modify the original PDF."""
    if not shutil.which("tesseract"):
        raise RuntimeError("Scanned page requires Tesseract (brew install tesseract).")
    image = page.get_pixmap(dpi=200).tobytes("png")
    response = subprocess.run(
        ["tesseract", "stdin", "stdout", "-l", "eng", "pdf"],
        input=image, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
    )
    if response.returncode:
        raise RuntimeError("OCR failed: " + response.stderr.decode(errors="replace")[-500:])
    return import_fitz().open(stream=response.stdout, filetype="pdf")


def detect_title_result(pdf_path: Path) -> TitleResult:
    with import_fitz().open(pdf_path) as doc:
        if not len(doc) or doc.needs_pass:
            raise RuntimeError("PDF is empty or password protected")
        if len(doc[0].get_text().strip()) < 40:
            with ocr_page(doc[0]) as ocr:
                result = identify_title(ocr, pdf_path.stem)
                if result.verified and title_key(result.title) == title_key(pdf_path.stem):
                    return TitleResult(clean_title(pdf_path.stem), "filename-checked-against-ocr", True)
                return TitleResult(result.title, "ocr-" + result.source, result.verified)
        return identify_title(doc, pdf_path.stem)


def detect_title(pdf_path: Path, title_model: str = "") -> str:
    return detect_title_result(pdf_path).title


def extract_markdown(pdf_path: Path, title: str, relative_pdf: Path, *,
                     markdown_path: Path | None = None, title_source: str = "provided",
                     digest: str | None = None) -> str:
    import pymupdf4llm
    parts = []
    warnings = []
    ocr_pages = []
    total_chars = 0
    with import_fitz().open(pdf_path) as doc:
        if doc.needs_pass:
            raise RuntimeError("Password protected PDF")
        count = len(doc)
        headings = pymupdf4llm.IdentifyHeaders(doc)
        for i, page in enumerate(doc):
            raw = page.get_text()
            ocr = None
            try:
                source = doc
                page_index = i
                if not raw.strip() and not page.get_contents():
                    raise ValueError("original PDF page is blank")
                if len(raw.strip()) < 40:
                    ocr = ocr_page(page)
                    source, page_index = ocr, 0
                    ocr_pages.append(i + 1)
                chunks = pymupdf4llm.to_markdown(
                    source, pages=[page_index], page_chunks=True,
                    show_progress=False, write_images=False,
                    force_text=True, margins=0, ignore_code=True,
                    hdr_info=headings if ocr is None else False,
                    graphics_limit=5000,
                )
                text = chunks[0]["text"].strip()
                # A layout conversion must not silently discard most of a page.
                source_text = source[page_index].get_text().strip()
                # sort=True inserts alignment spaces; compare actual letters/digits.
                if len(title_key(text)) < len(title_key(source_text)) * .9:
                    blocks = source[page_index].get_text("blocks")
                    text = "\n\n".join(b[4].strip() for b in blocks if b[6] == 0)
                    warnings.append(f"Page {i + 1}: layout extraction incomplete; plain text retained")
                if not text:
                    warnings.append(f"Page {i + 1}: no text recovered; inspect original PDF")
            except (RuntimeError, ValueError, subprocess.TimeoutExpired) as exc:
                text = raw.strip()
                warnings.append(f"Page {i + 1}: {exc}; inspect original PDF")
            finally:
                if ocr is not None:
                    ocr.close()
            total_chars += len(text)
            link = quote(os.path.relpath(pdf_path, markdown_path.parent)) if markdown_path else quote(str(pdf_path))
            parts.extend([f"<!-- Page {i + 1} -->", f"[PDF page {i + 1}]({link}#page={i + 1})", "", text or "[No readable text on this page.]", ""])
    if total_chars < 40:
        raise RuntimeError("No usable text recovered; PDF preserved, no empty Markdown created")
    metadata = {
        "title": title, "source_pdf": str(pdf_path), "relative_path": str(relative_pdf),
        "source_sha256": digest or file_hash(pdf_path), "page_count": count,
        "title_source": title_source, "extracted_at": now_iso(),
        "extractor_version": EXTRACTOR_VERSION, "ocr_pages": ocr_pages,
        "extraction_warnings": warnings,
    }
    header = ["---"] + [f"{k}: {json.dumps(v, ensure_ascii=False)}" for k, v in metadata.items()] + ["---", "", f"# {title}", "",
        "> Automatically extracted reading copy. Verify figures, equations, tables and key numbers against the PDF.", ""]
    if warnings:
        header.extend(["> Extraction warnings: " + "; ".join(warnings), ""])
    return "\n".join(header + parts).rstrip() + "\n"


def _same_file(left: Path, right: Path | None) -> bool:
    if right is None:
        return False
    if left == right:
        return True
    return left.exists() and right.exists() and left.samefile(right)


def _unique_target(path: Path, digest: str, current: Path | None = None) -> Path:
    if not path.exists() or _same_file(path, current):
        return path
    # Stable suffix, not a run-dependent counter; never overwrite another work.
    return path.with_name(f"{path.stem} [{digest[:12]}]{path.suffix}")


def _backup(path: Path, markdown_root: Path) -> None:
    backup = markdown_root.parent / ".papermind-backups" / "markdown" / path.relative_to(markdown_root)
    backup = backup.with_name(backup.name + "." + file_hash(path)[:12] + ".bak")
    backup.parent.mkdir(parents=True, exist_ok=True)
    if not backup.exists():
        shutil.copy2(path, backup)


def organize(title_model: str = "", *, dry_run: bool = False, refresh: bool = False,
             stop_at_organized: bool = False) -> OrganizeResult:
    if refresh and stop_at_organized:
        raise ValueError("Refresh requires a full organization pass")
    if dry_run:
        return _organize(dry_run=True, refresh=refresh, stop_at_organized=stop_at_organized)
    ensure_directories()
    lock_path = PDF_ROOT.parent / ".papermind.lock"
    with lock_path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError("Another PaperMind organize process is already running") from exc
        return _organize(refresh=refresh, stop_at_organized=stop_at_organized)


def _legacy_body_key(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    body = text.split("\n---\n", 1)[-1]
    body = re.sub(r"^\s*# [^\n]*\n", "", body, count=1)
    body = re.sub(r"\s+", "", unicodedata.normalize("NFKC", body))
    return hashlib.sha256(body.encode()).hexdigest() if len(body) > 100 else str(path)


def _prepare_document(pdf_path: Path, md_path: Path, digest: str):
    title = detect_title_result(pdf_path)
    markdown = extract_markdown(pdf_path, title.title, pdf_path.relative_to(PDF_ROOT),
                                markdown_path=md_path, title_source=title.source, digest=digest)
    return title, markdown


@contextmanager
def _preparations(paths, by_hash, headers, *, dry_run, refresh, sequential=False):
    workers = max(1, min(4, int(os.getenv("PAPERMIND_WORKERS", "4"))))
    if dry_run or sequential or workers == 1:
        yield {}
        return
    pending = {}
    seen_hashes = set()
    for path in paths:
        digest = file_hash(path)
        if digest in seen_hashes:
            continue
        seen_hashes.add(digest)
        if not refresh and any(headers[p].get("extractor_version") == EXTRACTOR_VERSION
                               and headers[p].get("source_pdf") == str(path)
                               for p in by_hash.get(digest, [])):
            continue
        pending.setdefault(digest, path)
    if not pending:
        yield {}
        return
    # PyMuPDF must not be shared across threads. Workers read independent PDFs;
    # the parent alone renames/writes library files while holding the library lock.
    with ProcessPoolExecutor(max_workers=workers, mp_context=multiprocessing.get_context("fork")) as pool:
        futures = {path: pool.submit(_prepare_document, path,
                   MARKDOWN_ROOT / path.relative_to(PDF_ROOT).with_suffix(".md"), digest)
                   for digest, path in pending.items()}
        yield futures


def _organize(*, dry_run: bool = False, refresh: bool = False,
              stop_at_organized: bool = False) -> OrganizeResult:
    if not dry_run:
        ensure_directories()
    result = OrganizeResult()
    # This is an in-memory inventory of file provenance, not a stored search index.
    headers = {p: read_header(p) for p in iter_markdown()}
    by_hash = {}
    by_source = {}
    for path, header in headers.items():
        if header.get("source_sha256"):
            by_hash.setdefault(header["source_sha256"], []).append(path)
        if header.get("source_pdf"):
            by_source.setdefault(str(Path(header["source_pdf"]).resolve()), []).append(path)
    # Recover old generated copies after historical renames, only when their
    # complete bodies match. Titles alone never justify discarding a document.
    legacy_groups = {}
    for path, header in headers.items():
        if not stop_at_organized and header.get("source_pdf") and not header.get("source_sha256"):
            legacy_groups.setdefault(_legacy_body_key(path), []).append(path)
    for group in legacy_groups.values():
        live_sources = {str(Path(headers[p]["source_pdf"]).resolve()) for p in group
                        if Path(headers[p]["source_pdf"]).is_file()}
        if live_sources and (len(live_sources) == 1 or len({file_hash(Path(s)) for s in live_sources}) == 1):
            source = min(live_sources)
            by_source[source] = list(dict.fromkeys(by_source[source] + group))
    seen = set()
    paths = iter_pdfs()
    if stop_at_organized:
        # Snapshot the order before any rename. Never pre-extract or hash PDFs
        # beyond the stopping boundary through the parallel preparation pool.
        paths.sort(key=lambda p: (-p.stat().st_mtime_ns, str(p).casefold()))
    with _preparations(paths, by_hash, headers, dry_run=dry_run, refresh=refresh,
                       sequential=stop_at_organized) as prepared:
        for position, pdf_path in enumerate(paths):
            try:
                digest = file_hash(pdf_path)
                matches = by_hash.get(digest, []) or by_source.get(str(pdf_path.resolve()), [])
                current = next((p for p in matches if headers[p].get("source_sha256") == digest
                                and headers[p].get("extractor_version") == EXTRACTOR_VERSION
                                and headers[p].get("source_pdf") == str(pdf_path)), None)
                if current and not refresh and headers[current].get("source_pdf") == str(pdf_path):
                    result.skipped += 1
                    seen.add(digest)
                    if stop_at_organized:
                        result.stopped_at = str(pdf_path.relative_to(PDF_ROOT))
                        result.remaining = len(paths) - position - 1
                        print(f"Stopped at already organized paper: {result.stopped_at}; "
                              f"{result.remaining} older PDFs left untouched", flush=True)
                        break
                    continue
                if digest in seen:
                    result.skipped += 1
                    print(f"duplicate PDF content preserved: {pdf_path}")
                    continue
                preparation = prepared[pdf_path].result() if pdf_path in prepared else None
                title = preparation[0] if preparation else detect_title_result(pdf_path)
                relative = pdf_path.relative_to(PDF_ROOT)
                safe_title = sanitize_filename(title.title, pdf_path.stem)
                target = _unique_target(pdf_path.with_name(safe_title + ".pdf"), digest, pdf_path) if title.verified else pdf_path
                md_target = MARKDOWN_ROOT / relative.parent / (target.stem + ".md")
                if md_target.exists() and not any(_same_file(md_target, p) for p in matches):
                    md_target = _unique_target(md_target, digest)
                if target.exists() and not _same_file(target, pdf_path):
                    # Even the hash-suffixed destination could contain an unrelated file.
                    raise FileExistsError(f"PDF destination exists: {target}")
                if md_target.exists() and not any(_same_file(md_target, p) for p in matches):
                    raise FileExistsError(f"Markdown destination exists: {md_target}")
                if not title.verified:
                    result.warnings += 1
                    print(f"title needs review (filename preserved): {pdf_path}")
                if dry_run:
                    print(f"plan: {relative} -> {target.name}; title={title.title} ({title.source})")
                    result.processed += 1
                    seen.add(digest)
                    continue
                # Extract completely before renaming or replacing anything.
                markdown = preparation[1] if preparation else extract_markdown(pdf_path, title.title, target.relative_to(PDF_ROOT),
                                            markdown_path=md_target, title_source=title.source, digest=digest)
                # Adjust source links to their final location.
                markdown = markdown.replace('relative_path: ' + yaml_string(str(relative)), 'relative_path: ' + yaml_string(str(target.relative_to(PDF_ROOT))), 1)
                markdown = markdown.replace(yaml_string(str(pdf_path)), yaml_string(str(target)), 1)
                old_link = quote(os.path.relpath(pdf_path, md_target.parent)) + "#page="
                new_link = quote(os.path.relpath(target, md_target.parent)) + "#page="
                markdown = markdown.replace("](" + old_link, "](" + new_link)
                md_target.parent.mkdir(parents=True, exist_ok=True)
                for old in matches:
                    _backup(old, MARKDOWN_ROOT)
                renamed = False
                temp_path = None
                try:
                    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=md_target.parent, suffix=".tmp", delete=False) as f:
                        temp_path = Path(f.name)
                        f.write(markdown)
                    if target != pdf_path:
                        pdf_path.rename(target)
                        renamed = True
                    os.replace(temp_path, md_target)
                except Exception:
                    if renamed:
                        target.rename(pdf_path)
                    raise
                finally:
                    if temp_path is not None:
                        temp_path.unlink(missing_ok=True)
                for old in matches:
                    if old.exists() and not _same_file(old, md_target):
                        old.unlink()
                header = read_header(md_target)
                headers[md_target] = header
                by_hash[digest] = [md_target]
                by_source[str(target.resolve())] = [md_target]
                if header.get("extraction_warnings"):
                    result.warnings += 1
                seen.add(digest)
                result.processed += 1
                print(f"organized: {target.relative_to(PDF_ROOT)}", flush=True)
            except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as exc:
                result.warnings += 1
                print(f"warning: {pdf_path}: {exc}", flush=True)
    return result


def reorganize() -> OrganizeResult:
    return organize()
