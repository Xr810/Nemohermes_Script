#!/usr/bin/env python3
"""Render an authorized ephemeral Open WebUI PDF into images for Hermes vision.

Hermes reads supported source files directly. This adapter exists only because
Hermes 0.19.0 treats PDF as binary and its vision tool accepts images, not PDF.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
from pathlib import Path
from typing import Any


OPEN_WEBUI_ROOT = Path(os.environ.get("OPEN_WEBUI_ROOT", "/sandbox/open-webui")).resolve()
DATA_ROOT = (OPEN_WEBUI_ROOT / "data").resolve()
UPLOAD_ROOT = (DATA_ROOT / "uploads").resolve()
DB_PATH = (DATA_ROOT / "webui.db").resolve()
CACHE_ROOT = (OPEN_WEBUI_ROOT / "source-cache").resolve()
EPHEMERAL_ROOT = Path(os.environ.get("HERMES_EPHEMERAL_ROOT", "/tmp/je-hermes-chat-files")).resolve()

FILE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
MAX_SOURCE_BYTES = 200 * 1024 * 1024


class PdfAdapterError(RuntimeError):
    pass


def is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def load_pdf(file_id: str) -> tuple[Path, dict[str, Any]]:
    if not FILE_ID_RE.fullmatch(file_id):
        raise PdfAdapterError("Invalid file ID")
    if not DB_PATH.is_file():
        raise PdfAdapterError("Open WebUI database not found")

    with sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True) as connection:
        row = connection.execute(
            "SELECT filename, path, meta FROM file WHERE id = ?",
            (file_id,),
        ).fetchone()
    if not row:
        raise PdfAdapterError("File does not exist in Open WebUI")

    filename, raw_path, raw_meta = row
    if not raw_path:
        raise PdfAdapterError("File has no stored source path")
    source_path = Path(raw_path).resolve()
    if not source_path.is_file() or not is_within(source_path, UPLOAD_ROOT):
        raise PdfAdapterError("Stored source path is outside the upload root")
    if source_path.suffix.lower() != ".pdf":
        raise PdfAdapterError("PDF adapter accepts only .pdf files")

    size = source_path.stat().st_size
    if size > MAX_SOURCE_BYTES:
        raise PdfAdapterError(f"PDF exceeds the {MAX_SOURCE_BYTES}-byte safety limit")
    try:
        meta = json.loads(raw_meta) if isinstance(raw_meta, str) else (raw_meta or {})
    except json.JSONDecodeError:
        meta = {}
    return source_path, {
        "filename": str(filename),
        "size": size,
        "content_type": meta.get("content_type") if isinstance(meta, dict) else None,
    }


def load_ephemeral_pdf(raw_path: str) -> tuple[Path, dict[str, Any]]:
    source_path = Path(raw_path).resolve()
    if not source_path.is_file() or not is_within(source_path, EPHEMERAL_ROOT):
        raise PdfAdapterError("Ephemeral source path is outside the authorized handoff root")
    if source_path.suffix.lower() != ".pdf":
        raise PdfAdapterError("PDF adapter accepts only .pdf files")

    size = source_path.stat().st_size
    if size > MAX_SOURCE_BYTES:
        raise PdfAdapterError(f"PDF exceeds the {MAX_SOURCE_BYTES}-byte safety limit")
    return source_path, {
        "filename": source_path.name,
        "size": size,
        "content_type": "application/pdf",
    }


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def render_pdf(file_id: str | None, source_path_arg: str | None, max_pages: int) -> dict[str, Any]:
    import pypdfium2 as pdfium

    if source_path_arg:
        source_path, record = load_ephemeral_pdf(source_path_arg)
    elif file_id:
        source_path, record = load_pdf(file_id)
    else:
        raise PdfAdapterError("A file ID or ephemeral source path is required")
    digest = sha256_file(source_path)
    if source_path_arg:
        output_dir = (source_path.parent / f"rendered-{digest[:16]}").resolve()
        if not is_within(output_dir, EPHEMERAL_ROOT):
            raise PdfAdapterError("Invalid ephemeral render path")
    else:
        output_dir = (CACHE_ROOT / f"{file_id}-{digest[:16]}").resolve()
        if not is_within(output_dir, CACHE_ROOT):
            raise PdfAdapterError("Invalid cache path")
    output_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    output_dir.chmod(0o700)

    document = pdfium.PdfDocument(str(source_path))
    page_count = len(document)
    image_paths: list[str] = []
    try:
        for index in range(min(page_count, max_pages)):
            image_path = output_dir / f"page-{index + 1:03d}.png"
            if not image_path.is_file():
                page = document[index]
                bitmap = page.render(scale=150 / 72)
                image = bitmap.to_pil()
                try:
                    image.save(image_path, "PNG")
                    image_path.chmod(0o600)
                finally:
                    image.close()
                    bitmap.close()
                    page.close()
            image_paths.append(str(image_path))
    finally:
        document.close()

    return {
        "status": "ok",
        "file_id": file_id,
        "filename": record["filename"],
        "content_type": record["content_type"] or "application/pdf",
        "size": record["size"],
        "sha256": digest,
        "source_path": str(source_path),
        "source_is_authoritative": True,
        "page_count": page_count,
        "rendered_page_count": len(image_paths),
        "pages_truncated": page_count > max_pages,
        "page_image_paths": image_paths,
        "recommended_next_step": "Use Hermes vision_analyze on the returned page_image_paths.",
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render an Open WebUI PDF for Hermes vision")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--file-id", help="Authorized persistent Open WebUI PDF file ID")
    source.add_argument("--source-path", help="Authorized ephemeral PDF source path")
    parser.add_argument("--max-pages", type=int, default=25, help="Maximum pages to render (1-50)")
    args = parser.parse_args()
    args.max_pages = max(1, min(args.max_pages, 50))
    return args


def main() -> int:
    try:
        args = parse_args()
        print(
            json.dumps(
                render_pdf(args.file_id, args.source_path, args.max_pages),
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0
    except PdfAdapterError as error:
        print(json.dumps({"status": "error", "error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 2
    except Exception as error:
        print(
            json.dumps({"status": "error", "error": f"{type(error).__name__}: {error}"}, ensure_ascii=False),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
