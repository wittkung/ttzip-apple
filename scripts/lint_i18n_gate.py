#!/usr/bin/env python3
# Copyright 2026 MetastudyLine. All rights reserved.
# SPDX-License-Identifier: MIT OR Apache-2.0

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
    },
    {
        "id": "I18N_FORBIDDEN_TITLE_ZEN_WORKSPACE",
        "title": "Zen Workspace",
        "pattern": re.compile(r'Text\s*\(\s*"Zen Workspace"\s*\)'),
        "fix_pattern": re.compile(r'Text\s*\(\s*"Zen Workspace"\s*\)'),
        "replacement": 'Text(l10n.uiString(zh: "禅意工作台", en: "Zen Workspace"))',
        "remediation": 'Replace Text("Zen Workspace") with l10n.uiString(zh: "禅意工作台", en: "Zen Workspace").'
    },
    {
        "id": "I18N_FORBIDDEN_TITLE_SELECT_ITEM_INSPECT",
        "title": "Select an item in the explorer to inspect",
        "pattern": re.compile(r'Text\s*\(\s*"Select an item in the explorer to inspect"\s*\)'),
        "fix_pattern": re.compile(r'Text\s*\(\s*"Select an item in the explorer to inspect"\s*\)'),
        "replacement": 'Text(l10n.uiString(zh: "在资源管理器中选择项目以检视详情", en: "Select an item in the explorer to inspect"))',
        "remediation": 'Replace Text("Select an item in the explorer to inspect") with l10n.uiString(zh: "在资源管理器中选择项目以检视详情", en: "Select an item in the explorer to inspect").'
    },
    {
        "id": "I18N_FORBIDDEN_TITLE_STORAGE_INSPECTOR",
        "title": "Storage Space Inspector",
        "pattern": re.compile(r'Text\s*\(\s*"Storage Space Inspector"\s*\)'),
        "fix_pattern": re.compile(r'Text\s*\(\s*"Storage Space Inspector"\s*\)'),
        "replacement": 'Text(l10n.uiString(zh: "存储空间透视", en: "Storage Space Inspector"))',
        "remediation": 'Replace Text("Storage Space Inspector") with l10n.uiString(zh: "存储空间透视", en: "Storage Space Inspector").'
    },
    {
        "id": "I18N_FORBIDDEN_TITLE_RECLAIMABLE_CACHE",
        "title": "Reclaimable Cache",
        "pattern": re.compile(r'Text\s*\(\s*"Reclaimable Cache"\s*\)'),
        "fix_pattern": re.compile(r'Text\s*\(\s*"Reclaimable Cache"\s*\)'),
        "replacement": 'Text(l10n.uiString(zh: "可清理缓存", en: "Reclaimable Cache"))',
        "remediation": 'Replace Text("Reclaimable Cache") with l10n.uiString(zh: "可清理缓存", en: "Reclaimable Cache").'
    },
    {
        "id": "I18N_FORBIDDEN_TITLE_RESET_MASTER_PASSWORD",
        "title": "Reset Master Password",
        "pattern": re.compile(r'Text\s*\(\s*"Reset Master Password"\s*\)'),
        "fix_pattern": re.compile(r'Text\s*\(\s*"Reset Master Password"\s*\)'),
        "replacement": 'Text(l10n.uiString(zh: "重置主密码", en: "Reset Master Password"))',
        "remediation": 'Replace Text("Reset Master Password") with l10n.uiString(zh: "重置主密码", en: "Reset Master Password").'
    },
    {
        "id": "I18N_FORBIDDEN_TITLE_ADD_PASSWORD_VAULT",
        "title": "Add Password to Secure Vault",
        "pattern": re.compile(r'Text\s*\(\s*"Add Password to Secure Vault"\s*\)'),
        "fix_pattern": re.compile(r'Text\s*\(\s*"Add Password to Secure Vault"\s*\)'),
        "replacement": 'Text(l10n.uiString(zh: "添加密码至安全保险库", en: "Add Password to Secure Vault"))',
        "remediation": 'Replace Text("Add Password to Secure Vault") with l10n.uiString(zh: "添加密码至安全保险库", en: "Add Password to Secure Vault").'
    }
]

# 2. Known Help Tooltip Anti-Patterns
KNOWN_HELP_FIX_MAP: Dict[str, str] = {
    "Open algorithm and format guide": "L10n.Compress.formatGuide",
    "Solid archiving packs multiple files into a continuous stream to improve ratio": "L10n.Compress.solidArchiveDesc",
    "Encrypts the archive directory index and filenames": "L10n.Compress.encryptFileNames7z",
    "Grant root access to parent directory to browse without sandbox prompts": "L10n.Explorer.rootAccessHelp",
    "Close Storage Inspector": "L10n.Common.close",
}

GENERIC_HELP_PATTERN = re.compile(r'\.help\s*\(\s*"([^"\\]+)"\s*\)')

# 3. Known Modal Hardcoded English Anti-Patterns
BANNED_MODAL_FILES = {"CompressionProgressModalView.swift", "CompressionSummarySheetView.swift"}
BANNED_MODAL_PATTERNS: List[Dict[str, Any]] = [
    {
        "id": "I18N_FORBIDDEN_MODAL_COMPRESSING",
        "title": "Compressing...",
        "pattern": re.compile(r'Text\s*\(\s*"Compressing\.\.\."\s*\)'),
        "remediation": "Replace Text(\"Compressing...\") with l10n.t(L10n.Queue.taskCompressing)."
    },
    {
        "id": "I18N_FORBIDDEN_MODAL_PROGRESS",
        "title": "Progress",
        "pattern": re.compile(r'Text\s*\(\s*"Progress"\s*\)'),
        "remediation": "Replace Text(\"Progress\") with l10n.uiString(zh: \"总进度\", en: \"Progress\", ...)."
    },
    {
        "id": "I18N_FORBIDDEN_MODAL_RUN_IN_BACKGROUND",
        "title": "Run in Background",
        "pattern": re.compile(r'Text\s*\(\s*"Run in Background"\s*\)'),
        "remediation": "Replace Text(\"Run in Background\") with l10n.uiString(zh: \"后台运行\", en: \"Run in Background\", ...)."
    },
    {
        "id": "I18N_FORBIDDEN_MODAL_CANCEL_TASK",
        "title": "Cancel Task",
        "pattern": re.compile(r'Text\s*\(\s*"Cancel Task"\s*\)'),
        "remediation": "Replace Text(\"Cancel Task\") with l10n.t(L10n.Queue.cancelTask)."
    },
    {
        "id": "I18N_FORBIDDEN_MODAL_COMPRESSION_COMPLETED",
        "title": "Compression Completed",
        "pattern": re.compile(r'Text\s*\(\s*"Compression Completed"\s*\)'),
        "remediation": "Replace Text(\"Compression Completed\") with l10n.uiString(zh: \"压缩已完成\", en: \"Compression Completed\", ...)."
    }
]


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

        # 3. Check banned hardcoded modal strings in target views
        if file_path.name in BANNED_MODAL_FILES:
            for modal_rule in BANNED_MODAL_PATTERNS:
                if modal_rule["pattern"].search(line):
                    violations.append(
                        Violation(
                            rule_id=modal_rule["id"],
                            file_path=file_path,
                            line_number=idx,
                            line_content=stripped,
                            message=modal_rule["remediation"],
                            can_fix=False
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


def get_apple_root() -> Path:
    """Resolve the apple root directory adaptively."""
    if "BUILD_WORKSPACE_DIRECTORY" in os.environ:
        cand = Path(os.environ["BUILD_WORKSPACE_DIRECTORY"]) / "products/ttzip/apple"
        if cand.exists():
            return cand.resolve()
    # Path(__file__).resolve() automatically dereferences the runfiles symlink to source tree
    script_root = Path(__file__).resolve().parent.parent
    if (script_root / "Sources").exists():
        return script_root
    cwd_cand = Path.cwd()
    if (cwd_cand / "Sources").exists():
        return cwd_cand.resolve()
    if (cwd_cand / "products/ttzip/apple/Sources").exists():
        return (cwd_cand / "products/ttzip/apple").resolve()
    return script_root



def main():
    parser = argparse.ArgumentParser(description="TTZip Static i18n & Localization Defense Gate")
    parser.add_argument("--dir", type=str, default=None, help="Root directory of apple project")
    parser.add_argument("--fix", action="store_true", help="Automatically remediate known anti-patterns in place")
    parser.add_argument("--verbose", action="store_true", help="Print all scanned files")
    args = parser.parse_args()

    root_dir = Path(args.dir).resolve() if args.dir else get_apple_root()
    print(f"{C_BOLD}{C_CYAN}======================================================================{C_RESET}")
    print(f"{C_BOLD}{C_CYAN}🌐 Running TTZip Apple Client i18n Static Defense Gate...{C_RESET}")
    print(f"{C_BOLD}{C_CYAN}======================================================================{C_RESET}")
    print(f"Target Root: {root_dir}")
    print(f"Scanning: {', '.join(SCAN_DIRECTORIES)}")

    swift_files = collect_swift_files(root_dir)
    if not swift_files:
        print(f"{C_RED}❌ ERROR: No Swift files found under scan targets in {root_dir}! Aborting to prevent false green.{C_RESET}")
        sys.exit(2)


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
