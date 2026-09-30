"""Real PDF bytes and executable lookup for F35 OCR acceptance."""

import os
from pathlib import Path
import shutil


def executable(environment: str, name: str) -> Path:
    raw = os.environ.get(environment) or shutil.which(name)
    if raw is None:
        raise RuntimeError(f"{name}_executable_required")
    value = Path(raw).resolve()
    if not value.is_file():
        raise RuntimeError(f"{name}_executable_required")
    return value


def warranty_pdf(text: str = "WARRANTY 2028-06-01") -> bytes:
    if not text.isascii() or any(char in text for char in "()\\"):
        raise ValueError("invalid_fixture_text")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
            b"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>"
        ),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>",
    ]
    stream = f"BT /F1 32 Tf 72 700 Td ({text}) Tj ET".encode("ascii")
    objects.append(
        b"<< /Length " + str(len(stream)).encode("ascii")
        + b" >>\nstream\n" + stream + b"\nendstream"
    )
    result = bytearray(b"%PDF-1.4\n")
    offsets = []
    for index, item in enumerate(objects, 1):
        offsets.append(len(result))
        result.extend(f"{index} 0 obj\n".encode("ascii"))
        result.extend(item)
        result.extend(b"\nendobj\n")
    xref = len(result)
    result.extend(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
    result.extend(b"0000000000 65535 f \n")
    for offset in offsets:
        result.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
    result.extend(
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
        f"startxref\n{xref}\n%%EOF\n".encode("ascii")
    )
    return bytes(result)
