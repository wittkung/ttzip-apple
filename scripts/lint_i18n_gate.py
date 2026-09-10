#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
# All rights reserved.
#
# TTZip: High-performance native archiving and compression engine.

"""
TTZip Static i18n & Localization Defense Gate
Scans Swift sources under Sources/TTZipApp and Sources/TTZipUI for localization anti-patterns:
1. Direct SwiftUI .help("literal") calls instead of .l10nHelp(L10n.Xxx)
2. Common unlocalized hardcoded titles (DIRECTORY CANVAS, OVERVIEW & FILE SYSTEM, New Archive)
Supports --fix to automatically remediate known anti-patterns in place.
"""

import sys
import os
import re
import argparse
from pathlib import Path
from typing import List, Dict, Any, Tuple, Optional

# Terminal ANSI Colors
C_RESET = "\033[0m"
C_BOLD = "\033[1m"
C_RED = "\033[1;31m"
C_GREEN = "\033[1;32m"
C_YELLOW = "\033[1;33m"
C_CYAN = "\033[1;36m"
C_MAGENTA = "\033[1;35m"

SCAN_DIRECTORIES = ["Sources/TTZipApp", "Sources/TTZipUI"]
ALLOWED_EXTENSIONS = {".swift"}
IGNORED_DIRS = {".build", "DerivedData", ".git", "Tests"}

# 1. Known Hardcoded Title Anti-Patterns
BANNED_TITLE_PATTERNS: List[Dict[str, Any]] = [
    {
        "id": "I18N_FORBIDDEN_TITLE_DIRECTORY_CANVAS",
        "title": "DIRECTORY CANVAS",
        "pattern": re.compile(r'Text\s*\(\s*"DIRECTORY CANVAS"\s*\)'),
        "fix_pattern": re.compile(r'Text\s*\(\s*"DIRECTORY CANVAS"\s*\)'),
        "replacement": 'Text(l10n.t(L10n.Inspector.directoryCanvas))',
        "remediation": "Replace Text(\"DIRECTORY CANVAS\") with Text(l10n.t(L10n.Inspector.directoryCanvas)) or L10nText."
    },
    {
        "id": "I18N_FORBIDDEN_TITLE_OVERVIEW_FS",
        "title": "OVERVIEW & FILE SYSTEM",
        "pattern": re.compile(r'Text\s*\(\s*"OVERVIEW & FILE SYSTEM"\s*\)'),
        "fix_pattern": re.compile(r'Text\s*\(\s*"OVERVIEW & FILE SYSTEM"\s*\)'),
        "replacement": 'Text(l10n.t(L10n.Inspector.overviewFs))',
        "remediation": "Replace Text(\"OVERVIEW & FILE SYSTEM\") with Text(l10n.t(L10n.Inspector.overviewFs)) or L10nText."
    },
    {
        "id": "I18N_FORBIDDEN_TITLE_NEW_ARCHIVE",
        "title": "New Archive",
        "pattern": re.compile(r'Text\s*\(\s*"New Archive"\s*\)'),
        "fix_pattern": re.compile(r'Text\s*\(\s*"New Archive"\s*\)'),
        "replacement": 'Text(l10n.t(L10n.Compress.title))',
        "remediation": "Replace Text(\"New Archive\") with Text(l10n.t(L10n.Compress.title)) or L10nText."
    }
]

# 2. Known Help Tooltip Anti-Patterns
KNOWN_HELP_FIX_MAP: Dict[str, str] = {
    "Open algorithm and format guide": "L10n.Compress.formatGuide",
    "Solid archiving packs multiple files into a continuous stream to improve ratio": "L10n.Compress.solidArchiveDesc",
    "Encrypts the archive directory index and filenames": "L10n.Compress.encryptFileNames7z",
    "Grant root access to parent directory to browse without sandbox prompts": "L10n.Explorer.rootAccessHelp",
}

GENERIC_HELP_PATTERN = re.compile(r'\.help\s*\(\s*"([^"\\]+)"\s*\)')


class Violation:
    def __init__(self, rule_id: str, file_path: Path, line_number: int, line_content: str, message: str, can_fix: bool = False):
        self.rule_id = rule_id
        self.file_path = file_path
        self.line_number = line_number
        self.line_content = line_content
        self.message = message
        self.can_fix = can_fix


def scan_file(file_path: Path) -> List[Violation]:
    """Scans a single Swift file for localization anti-patterns."""
    violations: List[Violation] = []
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception as e:
        print(f"{C_YELLOW}⚠️ Unable to read {file_path}: {e}{C_RESET}")
        return violations

    for idx, line in enumerate(lines, start=1):
        stripped = line.strip()
        # Skip comment lines
        if stripped.startswith("//") or stripped.startswith("/*") or stripped.startswith("*"):
            continue

        # 1. Check banned hardcoded titles
        for title_rule in BANNED_TITLE_PATTERNS:
            if title_rule["pattern"].search(line):
                violations.append(
                    Violation(
                        rule_id=title_rule["id"],
                        file_path=file_path,
                        line_number=idx,
                        line_content=stripped,
                        message=title_rule["remediation"],
                        can_fix=True
                    )
                )

        # 2. Check known help tooltips that should use .l10nHelp
        for known_str, l10n_key in KNOWN_HELP_FIX_MAP.items():
            if f'.help("{known_str}")' in line:
                violations.append(
                    Violation(
                        rule_id="I18N_HARDCODED_HELP_KNOWN",
                        file_path=file_path,
                        line_number=idx,
                        line_content=stripped,
                        message=f"Hardcoded tooltip '.help(\"{known_str}\")' should be replaced with '.l10nHelp({l10n_key})'",
                        can_fix=True
                    )
                )

    return violations


def apply_fixes(file_path: Path) -> int:
    """Applies automated in-place fixes for known anti-patterns."""
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            content = f.read()
    except Exception as e:
        print(f"{C_RED}Failed to read {file_path} for fix: {e}{C_RESET}")
        return 0

    original_content = content
    fix_count = 0

    # Fix banned titles
    for title_rule in BANNED_TITLE_PATTERNS:
        matches = len(title_rule["fix_pattern"].findall(content))
        if matches > 0:
            content = title_rule["fix_pattern"].sub(title_rule["replacement"], content)
            fix_count += matches

    # Fix known help tooltips
    for known_str, l10n_key in KNOWN_HELP_FIX_MAP.items():
        target = f'.help("{known_str}")'
        replacement = f'.l10nHelp({l10n_key})'
        if target in content:
            content = content.replace(target, replacement)
            fix_count += 1

    if fix_count > 0 and content != original_content:
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(content)

    return fix_count


def collect_swift_files(root_dir: Path) -> List[Path]:
    """Collects Swift source files under target scan directories."""
    collected: List[Path] = []
    for scan_rel in SCAN_DIRECTORIES:
        target_dir = root_dir / scan_rel
        if not target_dir.exists():
            continue
        for root, dirs, files in os.walk(target_dir):
            dirs[:] = [d for d in dirs if d not in IGNORED_DIRS]
            for file in files:
                if file.endswith(".swift"):
                    collected.append(Path(root) / file)
    return collected


def main():
    parser = argparse.ArgumentParser(description="TTZip Static i18n & Localization Defense Gate")
    parser.add_argument("--dir", type=str, default=".", help="Root directory of apple project")
    parser.add_argument("--fix", action="store_true", help="Automatically remediate known anti-patterns in place")
    parser.add_argument("--verbose", action="store_true", help="Print all scanned files")
    args = parser.parse_args()

    root_dir = Path(args.dir).resolve()
    print(f"{C_BOLD}{C_CYAN}======================================================================{C_RESET}")
    print(f"{C_BOLD}{C_CYAN}🌐 Running TTZip Apple Client i18n Static Defense Gate...{C_RESET}")
    print(f"{C_BOLD}{C_CYAN}======================================================================{C_RESET}")
    print(f"Target Root: {root_dir}")
    print(f"Scanning: {', '.join(SCAN_DIRECTORIES)}")

    swift_files = collect_swift_files(root_dir)
    if not swift_files:
        print(f"{C_YELLOW}⚠️ No Swift files found under scan targets in {root_dir}{C_RESET}")
        sys.exit(0)

    print(f"Discovered {len(swift_files)} Swift source files to audit.\n")

    if args.fix:
        print(f"{C_CYAN}🔧 Applying automated fixes across source files...{C_RESET}")
        total_fixed = 0
        for path in swift_files:
            fixes = apply_fixes(path)
            if fixes > 0:
                print(f"  {C_GREEN}Fixed {fixes} pattern(s) in {path.relative_to(root_dir)}{C_RESET}")
                total_fixed += fixes
        print(f"Total automated remediations applied: {total_fixed}\n")

    total_violations = 0
    all_violations: List[Violation] = []

    for path in swift_files:
        if args.verbose:
            print(f"Scanning {path.relative_to(root_dir)}...")
        violations = scan_file(path)
        if violations:
            total_violations += len(violations)
            all_violations.extend(violations)

    if total_violations > 0:
        print(f"{C_BOLD}{C_RED}❌ i18n Static Defense Gate FAILED: Found {total_violations} violation(s)!{C_RESET}\n")
        for v in all_violations:
            rel_path = v.file_path.relative_to(root_dir)
            print(f"{C_RED}[{v.rule_id}]{C_RESET} {C_BOLD}{rel_path}:{v.line_number}{C_RESET}")
            print(f"  Line: {C_YELLOW}{v.line_content}{C_RESET}")
            print(f"  Hint: {v.message}\n")
        
        print(f"{C_YELLOW}Run with --fix to automatically resolve supported anti-patterns.{C_RESET}")
        sys.exit(1)
    else:
        print(f"{C_BOLD}{C_GREEN}======================================================================{C_RESET}")
        print(f"{C_BOLD}{C_GREEN}✅ All {len(swift_files)} Swift files passed i18n static defense gate (0 violations)!{C_RESET}")
        print(f"{C_BOLD}{C_GREEN}======================================================================{C_RESET}")
        sys.exit(0)


if __name__ == "__main__":
    main()
