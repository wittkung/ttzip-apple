# Copyright 2026 MetastudyLine. All rights reserved.
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Read-only Mach-O and Swift UniFFI checksum parity verification helpers."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Optional
import re
import subprocess

UNIFFI_SWIFT_RELPATHS = (
    "products/ttzip/core/Sources/TTZipCore/Generated/ttzip_engine.swift",
    "products/ttzip/app-core/Sources/TTZipAppCore/Generated/ttzip_app_core.swift",
)
UNIFFI_SWIFT_RE = re.compile(
    r"\b(uniffi_ttzip_(?:engine|app_core)_checksum_[A-Za-z0-9_]+)\(\)\s*!=\s*(\d+)"
)
UNIFFI_SYM_HEADER_RE = re.compile(
    r"<_(uniffi_ttzip_(?:engine|app_core)_checksum_[A-Za-z0-9_]+)>:"
)
UNIFFI_IMM_RE = re.compile(
    r"\bmov(?:z|l|w)?\s+(?:"
    r"w0,\s*#(0x[0-9a-fA-F]+|\d+)|"
    r"w0,\s*(wzr)|"
    r"\$(0x[0-9a-fA-F]+|\d+),\s*%e?ax"
    r")"
)


def parse_swift_uniffi_checksums(swift_path: Path) -> dict[str, int]:
    """Extract the expected UniFFI symbol checksum mapping from a generated Swift binding file."""
    raw = swift_path.read_text(encoding="utf-8")
    return {
        match.group(1): int(match.group(2))
        for match in UNIFFI_SWIFT_RE.finditer(raw)
    }


def load_expected_swift_uniffi_checksums(source_root: Path) -> dict[str, int]:
    """Load the combined expected UniFFI symbol checksums from generated Swift bindings."""
    expected: dict[str, int] = {}
    for relpath in UNIFFI_SWIFT_RELPATHS:
        swift_file = source_root / relpath
        if not swift_file.is_file():
            return {}
        expected.update(parse_swift_uniffi_checksums(swift_file))
    return expected


def disassemble_macho_uniffi_checksums(
    binary_path: Path,
    symbols: Optional[list[str]] = None,
) -> dict[str, int]:
    """Disassemble a Mach-O binary and parse 16-bit return values for UniFFI checksum symbols."""
    if not binary_path.is_file():
        return {}
    if symbols is not None and not symbols:
        return {}
    cmd = ["/usr/bin/objdump", "-d"]
    if symbols:
        symbol_arg = ",".join(f"_{sym}" for sym in symbols)
        cmd.append(f"--disassemble-symbols={symbol_arg}")
    cmd.append(str(binary_path))
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        return {}
    result: dict[str, int] = {}
    current_sym: Optional[str] = None
    for line in proc.stdout.splitlines():
        header = UNIFFI_SYM_HEADER_RE.search(line)
        if header:
            current_sym = header.group(1)
            continue
        if current_sym and current_sym not in result:
            imm = UNIFFI_IMM_RE.search(line)
            if imm:
                raw_val = imm.group(1) or imm.group(3)
                result[current_sym] = 0 if imm.group(2) else int(raw_val, 0)
    return result


def verify_macho_uniffi_checksums(
    binary_path: Path,
    source_root: Path,
) -> dict[str, Any]:
    """Compare Mach-O UniFFI checksum symbols in binary_path against generated Swift bindings."""
    expected = load_expected_swift_uniffi_checksums(source_root)
    if not expected or not binary_path.is_file():
        return {
            "applicable": False,
            "passed": False,
            "matched": 0,
            "matched_count": 0,
            "total": 0,
            "expected_count": 0,
            "mismatches": [],
            "missing": [],
            "missing_in_binary": [],
        }
    actual = disassemble_macho_uniffi_checksums(binary_path, sorted(expected))
    missing = [sym for sym in sorted(expected) if sym not in actual]
    mismatches = [
        f"{sym}: binary={actual[sym]} != swift={expected[sym]}"
        for sym in sorted(expected)
        if sym in actual and actual[sym] != expected[sym]
    ]
    matched = len(expected) - len(missing) - len(mismatches)
    passed = not missing and not mismatches
    return {
        "applicable": True,
        "passed": passed,
        "matched": matched,
        "matched_count": matched,
        "total": len(expected),
        "expected_count": len(expected),
        "mismatches": mismatches,
        "missing": missing,
        "missing_in_binary": missing,
    }
