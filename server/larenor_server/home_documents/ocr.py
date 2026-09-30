"""Bounded local OCR for untrusted home-document warranty candidates."""

from __future__ import annotations

import csv
from datetime import date
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import tempfile
import time

from ..errors import ApiError
from .models import DocumentBlobRef, OcrWarrantyCandidate


MAX_PAGES = 3
MAX_PIXELS = 8_000_000
MAX_SIDE = 8192
MAX_RASTER_BYTES = 16 * 1024 * 1024
MAX_TSV_BYTES = 1024 * 1024
MAX_TSV_ROWS = 10_000
OCR_DEADLINE_SECONDS = 20.0
MAX_PROCESS_MEMORY_BYTES = 512 * 1024 * 1024
_ISO_DATE = re.compile(r"(?<![0-9])([0-9]{4}-[0-9]{2}-[0-9]{2})(?![0-9])")
_WARRANTY_CUES = frozenset({
    "warranty", "warranty:", "expires", "expires:", "expiration",
    "expiration:", "garanti", "garanti:", "gecerlilik", "gecerlilik:",
})
_TSV_FIELDS = (
    "level", "page_num", "block_num", "par_num", "line_num", "word_num",
    "left", "top", "width", "height", "conf", "text",
)


def _fail():
    raise ApiError("server_unavailable", 503)


def _dimensions_png(value: bytes) -> tuple[int, int]:
    if len(value) < 24 or value[:8] != b"\x89PNG\r\n\x1a\n" or value[12:16] != b"IHDR":
        _fail()
    return int.from_bytes(value[16:20], "big"), int.from_bytes(value[20:24], "big")


def _dimensions_jpeg(value: bytes) -> tuple[int, int]:
    if len(value) < 4 or value[:2] != b"\xff\xd8" or value[-2:] != b"\xff\xd9":
        _fail()
    offset = 2
    sof = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}
    while offset + 4 <= len(value):
        if value[offset] != 0xFF:
            _fail()
        while offset < len(value) and value[offset] == 0xFF:
            offset += 1
        if offset >= len(value):
            break
        marker = value[offset]
        offset += 1
        if marker in {0xD8, 0xD9}:
            continue
        if marker == 0xDA:
            break
        if offset + 2 > len(value):
            _fail()
        length = int.from_bytes(value[offset:offset + 2], "big")
        if length < 2 or offset + length > len(value):
            _fail()
        if marker in sof:
            if length < 7:
                _fail()
            height = int.from_bytes(value[offset + 3:offset + 5], "big")
            width = int.from_bytes(value[offset + 5:offset + 7], "big")
            return width, height
        offset += length
    _fail()


def _bounded_image(value: bytes, content_type: str) -> None:
    width, height = (
        _dimensions_png(value)
        if content_type == "image/png"
        else _dimensions_jpeg(value)
    )
    if (
        width < 1 or height < 1 or width > MAX_SIDE or height > MAX_SIDE
        or width * height > MAX_PIXELS
    ):
        _fail()


class TesseractHomeDocumentOcr:
    """Run fixed Poppler/Tesseract commands and return an untrusted candidate."""

    def __init__(self, tesseract: Path, pdftoppm: Path):
        self.tesseract = self._executable(tesseract)
        self.pdftoppm = self._executable(pdftoppm)

    @staticmethod
    def _executable(value: Path) -> Path:
        if (
            not isinstance(value, Path) or not value.is_absolute()
            or ".." in value.parts
            or any(ord(char) < 32 or ord(char) == 127 for char in str(value))
            or not value.is_file() or not os.access(value, os.X_OK)
        ):
            raise ValueError("invalid_home_document_ocr_executable")
        return value

    @staticmethod
    def _run(argv: list[str], root: Path, outputs, maximum: int, deadline: float):
        if deadline - time.monotonic() <= 0:
            _fail()
        try:
            process = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                cwd=root,
                env={
                    "HOME": str(root), "LANG": "C", "LC_ALL": "C",
                    "PATH": "/usr/bin:/bin", "OMP_THREAD_LIMIT": "1",
                    "OMP_NUM_THREADS": "1",
                },
                close_fds=True,
                start_new_session=True,
            )
        except (OSError, ValueError):
            _fail()
        try:
            if hasattr(resource, "prlimit"):
                try:
                    resource.prlimit(process.pid, resource.RLIMIT_CPU, (20, 20))
                    resource.prlimit(
                        process.pid, resource.RLIMIT_AS,
                        (MAX_PROCESS_MEMORY_BYTES, MAX_PROCESS_MEMORY_BYTES),
                    )
                    resource.prlimit(
                        process.pid, resource.RLIMIT_FSIZE, (maximum, maximum)
                    )
                except ProcessLookupError:
                    if process.poll() != 0:
                        _fail()
            while process.poll() is None:
                size = sum(path.stat().st_size for path in outputs() if path.is_file())
                if size > maximum or time.monotonic() >= deadline:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                    _fail()
                time.sleep(0.02)
            if process.returncode != 0:
                _fail()
            size = sum(path.stat().st_size for path in outputs() if path.is_file())
            if size < 1 or size > maximum:
                _fail()
        except ApiError:
            raise
        except (OSError, subprocess.SubprocessError):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except (OSError, ProcessLookupError):
                pass
            process.wait()
            _fail()

    def _images(self, root: Path, blob: DocumentBlobRef, content: bytes, deadline: float):
        if blob.contentType == "application/pdf":
            if not content.startswith(b"%PDF-"):
                _fail()
            source = root / "source.pdf"
            source.write_bytes(content)
            prefix = root / "page"
            outputs = lambda: tuple(root.glob("page-*.png"))
            self._run([
                str(self.pdftoppm), "-f", "1", "-l", str(MAX_PAGES),
                "-scale-to", "1600", "-png", str(source), str(prefix),
            ], root, outputs, MAX_RASTER_BYTES, deadline)
            images = sorted(outputs())
            if not 1 <= len(images) <= MAX_PAGES:
                _fail()
            for path in images:
                _bounded_image(path.read_bytes(), "image/png")
            return images
        suffix = ".png" if blob.contentType == "image/png" else ".jpg"
        _bounded_image(content, blob.contentType)
        source = root / ("source" + suffix)
        source.write_bytes(content)
        return [source]

    @staticmethod
    def _date_candidate(path: Path):
        try:
            raw = path.read_bytes()
            if not 1 <= len(raw) <= MAX_TSV_BYTES:
                _fail()
            text = raw.decode("utf-8")
            reader = csv.DictReader(text.splitlines(), delimiter="\t")
            if tuple(reader.fieldnames or ()) != _TSV_FIELDS:
                _fail()
            lines: dict[tuple[str, str, str, str], list[tuple[str, float]]] = {}
            for index, row in enumerate(reader):
                if index >= MAX_TSV_ROWS or set(row) != set(_TSV_FIELDS):
                    _fail()
                if row["level"] != "5" or not row["text"]:
                    continue
                token = row["text"].strip()
                confidence = float(row["conf"])
                if (
                    not token or len(token) > 256 or not 0 <= confidence <= 100
                    or any(ord(char) < 32 or ord(char) == 127 for char in token)
                ):
                    _fail()
                key = tuple(row[name] for name in (
                    "page_num", "block_num", "par_num", "line_num"
                ))
                lines.setdefault(key, []).append((token, confidence))
        except ApiError:
            raise
        except (OSError, UnicodeError, ValueError, csv.Error):
            _fail()
        candidates = []
        for words in lines.values():
            folded = {word.casefold().strip(".,;()[]") for word, _ in words}
            if not folded.intersection(_WARRANTY_CUES):
                continue
            for word, confidence in words:
                for match in _ISO_DATE.finditer(word):
                    value = match.group(1)
                    try:
                        if date.fromisoformat(value).isoformat() != value:
                            continue
                    except ValueError:
                        continue
                    candidates.append((round(confidence * 10), value))
        if not candidates:
            return None
        candidates.sort(key=lambda item: (-item[0], item[1]))
        return candidates[0]

    def extract(self, blob: DocumentBlobRef, content: bytes):
        if (
            type(content) is not bytes or len(content) != blob.contentLength
            or blob.contentType not in {"application/pdf", "image/jpeg", "image/png"}
        ):
            _fail()
        deadline = time.monotonic() + OCR_DEADLINE_SECONDS
        best = None
        try:
            with tempfile.TemporaryDirectory(prefix="larenor-home-document-ocr-") as name:
                root = Path(name)
                for index, image in enumerate(self._images(root, blob, content, deadline)):
                    output = root / f"ocr-{index}"
                    tsv = output.with_suffix(".tsv")
                    self._run([
                        str(self.tesseract), str(image), str(output),
                        "--psm", "6", "-l", "eng", "tsv",
                    ], root, lambda: (tsv,), MAX_TSV_BYTES, deadline)
                    candidate = self._date_candidate(tsv)
                    if candidate is not None and (
                        best is None
                        or candidate[0] > best[0]
                        or candidate[0] == best[0] and candidate[1] < best[1]
                    ):
                        best = candidate
        except ApiError:
            raise
        except (OSError, ValueError):
            _fail()
        if best is None:
            return None
        confidence, extracted = best
        return OcrWarrantyCandidate(
            schemaVersion=1,
            provider="tesseract",
            extractedDate=extracted,
            confidencePermille=confidence,
            sourceRevision=blob.serviceRevision,
            sourceDigest=blob.sha256,
            sourceContentType=blob.contentType,
        )
