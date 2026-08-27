#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
# All rights reserved.
#
# TTZip: High-performance native archiving and compression engine.

"""
TTZip Static Architecture & Decoupling Defense Gate (Defect 48)
Enforces strict unidirectional decoupling:
1. Blocks hardcoded/embedded plugin directories under Sources/ (e.g., Sources/Plugins/)
2. Blocks hardcoded plugin Bundle IDs (e.g., com.ttzip.plugin.iina, larksync)
3. Blocks developer local absolute paths (/Users/...)
4. Blocks studio-lab workspace leakage keywords
5. Blocks plugin-specific dlsym symbols (e.g., getLarkSyncWorkspaceView_c)
"""

import sys
import os
import re
import argparse
from pathlib import Path
from typing import List, Dict, Any, Tuple

# Terminal ANSI Colors
C_RESET = "\033[0m"
C_BOLD = "\033[1m"
C_RED = "\033[1;31m"
C_GREEN = "\033[1;32m"
C_YELLOW = "\033[1;33m"
C_CYAN = "\033[1;36m"
C_MAGENTA = "\033[1;35m"

SOURCE_DIRS = ["Sources"]
SOURCE_EXTENSIONS = {
    ".swift", ".m", ".h", ".c", ".cpp", ".mm",
    ".plist", ".json", ".xcprivacy", ".strings"
}
IGNORED_DIRS = {
    "target", ".build", "Vendor", ".git", "DerivedData", "Generated", "Pods"
}

# Top-level forbidden directory names directly under Sources/
FORBIDDEN_TOP_LEVEL_PLUGIN_DIRS = {
    "Plugins", "PlugIns", "LarkSync", "ttzip-plugin-iina", "IINA"
}

# Allowed top-level targets under Sources/
ALLOWED_TOP_LEVEL_SOURCES = {
    "TTZipApp", "TTZipPluginKit", "TTZipFinderSync", "TTZipQuickLook", "TTZipCore", "TTZipCLI"
}

# 2. Invariant Rules Configuration
RULES = [
    {
        "id": "ARCH_NO_HARDCODED_LOCAL_PATHS",
        "description": "Developer local filesystem path (/Users/...) forbidden in source code",
        "pattern": re.compile(r'/Users/[a-zA-Z0-9_.-]+'),
        "remediation": "Replace hardcoded '/Users/...' with dynamic directory resolution (e.g., Bundle.main, FileManager.default.urls)."
    },
    {
        "id": "ARCH_NO_STUDIO_LAB_LEAK",
        "description": "Internal workspace 'studio-lab' keyword reference detected",
        "pattern": re.compile(r'studio-lab', re.IGNORECASE),
        "remediation": "Remove hardcoded references to 'studio-lab'. Plugins must be installed dynamically via TTZipPluginKit."
    },
    {
        "id": "ARCH_NO_HARDCODED_PLUGIN_BUNDLE_ID",
        "description": "Hardcoded specific plugin Bundle ID detected",
        "pattern": re.compile(r'com\.ttzip\.plugin\.(larksync|iina|[a-zA-Z0-9_]+-[a-zA-Z0-9_]+)'),
        "remediation": "Decouple host from specific plugin IDs. Use dynamic registration or marketplace discovery."
    },
    {
        "id": "ARCH_NO_HARDCODED_PLUGIN_IDENTIFIERS",
        "description": "Hardcoded specific plugin identifier/symbol detected (e.g. larksync / IINA coupling)",
        "pattern": re.compile(
            r'("larksync(\.[a-zA-Z0-9_]+)?"|\bLarkSyncPlugin\b|\bLarkSync\.ttplugin\b|\bttzip-plugin-iina\b|\blarksync\b)',
            re.IGNORECASE
        ),
        "remediation": "Remove specific plugin names/identifiers. Decouple via generic plugin protocols (TTZipPlugin)."
    },
    {
        "id": "ARCH_NO_SPECIFIC_DLSYM_SYMBOLS",
        "description": "Specific plugin C-symbol dlsym coupling detected",
        "pattern": re.compile(r'dlsym\s*\(\s*[^,]+,\s*"getLarkSyncWorkspaceView_c"\s*\)|getLarkSyncWorkspaceView_c'),
        "remediation": "Use standardized generic ABI entrypoint ('createTTZipPlugin') instead of plugin-specific dlsym symbols."
    }
]

def get_repo_root() -> Path:
    return Path(__file__).resolve().parent.parent

def scan_directory_invariants(root_dir: Path) -> List[Dict[str, Any]]:
    violations = []
    for sdir in SOURCE_DIRS:
        sources_path = root_dir / sdir
        if not sources_path.exists():
            continue

        # 1. Check direct top-level subdirectories under Sources/
        for item in sources_path.iterdir():
            if item.is_dir() and item.name not in IGNORED_DIRS:
                if item.name in FORBIDDEN_TOP_LEVEL_PLUGIN_DIRS or (
                    item.name.lower().startswith("plugin") and item.name != "TTZipPluginKit"
                ):
                    rel_path = str(item.relative_to(root_dir))
                    violations.append({
                        "rule_id": "ARCH_NO_EMBEDDED_PLUGIN_DIR",
                        "description": f"Forbidden plugin directory '{item.name}' detected directly under Sources/",
                        "file_path": rel_path,
                        "line_number": 0,
                        "snippet": f"Directory: {rel_path}",
                        "remediation": "Extract plugin implementation into standalone repository or plugin package outside Sources/."
                    })

        # 2. Check for nested plugin bundles (.ttplugin) or direct Plugins/ directories
        for root, dirs, _ in os.walk(sources_path):
            dirs[:] = [d for d in dirs if d not in IGNORED_DIRS]
            for d in dirs:
                if d.endswith(".ttplugin") or d.endswith(".plugin"):
                    dir_path = Path(root) / d
                    rel_path = str(dir_path.relative_to(root_dir))
                    violations.append({
                        "rule_id": "ARCH_NO_EMBEDDED_PLUGIN_DIR",
                        "description": f"Forbidden plugin bundle directory '{d}' detected inside Sources/",
                        "file_path": rel_path,
                        "line_number": 0,
                        "snippet": f"Directory: {rel_path}",
                        "remediation": "Move plugin bundles to external build artifacts or test fixture directories."
                    })

    return violations

def is_comment_line(line: str, ext: str) -> bool:
    stripped = line.strip()
    if ext in {".swift", ".c", ".cpp", ".h", ".m", ".mm"}:
        if stripped.startswith("//") or stripped.startswith("/*") or stripped.startswith("*"):
            return True
    return False

def scan_file_invariants(root_dir: Path) -> Tuple[int, List[Dict[str, Any]]]:
    violations = []
    scanned_files = 0

    for sdir in SOURCE_DIRS:
        sources_path = root_dir / sdir
        if not sources_path.exists():
            continue

        for root, dirs, files in os.walk(sources_path):
            dirs[:] = [d for d in dirs if d not in IGNORED_DIRS]

            for file in sorted(files):
                ext = os.path.splitext(file)[1].lower()
                if ext not in SOURCE_EXTENSIONS:
                    continue

                file_path = Path(root) / file
                if file_path.is_symlink():
                    continue

                scanned_files += 1
                rel_path = str(file_path.relative_to(root_dir))

                try:
                    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
                        lines = f.readlines()
                except Exception as e:
                    print(f"{C_YELLOW}⚠️  Warning: Unable to read {file_path}: {e}{C_RESET}", file=sys.stderr)
                    continue

                for line_idx, line in enumerate(lines, 1):
                    # Check if line is purely comment
                    if is_comment_line(line, ext):
                        continue

                    for rule in RULES:
                        if rule["pattern"].search(line):
                            violations.append({
                                "rule_id": rule["id"],
                                "description": rule["description"],
                                "file_path": rel_path,
                                "line_number": line_idx,
                                "snippet": line.strip(),
                                "remediation": rule["remediation"]
                            })

    return scanned_files, violations

def main():
    parser = argparse.ArgumentParser(description="TTZip Architecture & Decoupling Defense Gate")
    parser.add_argument("--dir", type=str, default=None, help="Root directory to scan (defaults to apple root)")
    args = parser.parse_args()

    repo_root = Path(args.dir).resolve() if args.dir else get_repo_root()

    print(f"{C_CYAN}{C_BOLD}======================================================================{C_RESET}")
    print(f"{C_CYAN}{C_BOLD}   TTZip Architecture & Decoupling Defense Gate (Defect 48)         {C_RESET}")
    print(f"{C_CYAN}{C_BOLD}======================================================================{C_RESET}")
    print(f"Target Directory: {repo_root}")
    print(f"Scanning Sources for forbidden plugin coupling, paths, and symbols...\n")

    dir_violations = scan_directory_invariants(repo_root)
    scanned_files, file_violations = scan_file_invariants(repo_root)

    total_violations = dir_violations + file_violations

    print(f"Scanned {scanned_files} source files across '{repo_root / 'Sources'}'.")

    if scanned_files == 0:
        print(f"\n{C_RED}{C_BOLD}❌ ARCHITECTURE GATE FAILED: No source files found under {repo_root / 'Sources'}!{C_RESET}\n")
        sys.exit(2)

    if total_violations:
        print(f"\n{C_RED}{C_BOLD}❌ ARCHITECTURE GATE FAILED: Found {len(total_violations)} architecture violation(s)!{C_RESET}\n")
        print(f"{'Line':>6} | {'Rule ID':<38} | Location / Snippet")
        print("-" * 85)
        for v in total_violations:
            loc = f"{v['file_path']}:{v['line_number']}" if v['line_number'] > 0 else v['file_path']
            print(f"{C_RED}{v['line_number']:>6}{C_RESET} | {C_MAGENTA}{v['rule_id']:<38}{C_RESET} | {C_BOLD}{loc}{C_RESET}")
            print(f"       | {C_YELLOW}Snippet:{C_RESET} {v['snippet']}")
            print(f"       | {C_CYAN}Fix:{C_RESET}     {v['remediation']}")
            print("-" * 85)

        print(f"\n{C_YELLOW}💡 Action required: Decouple plugin-specific code, remove local developer paths, and adhere to clean plugin interfaces.{C_RESET}\n")
        sys.exit(1)

    print(f"{C_GREEN}{C_BOLD}✅ [PASS] All {scanned_files} source files conform to architecture & decoupling invariants.{C_RESET}\n")
    sys.exit(0)

if __name__ == "__main__":
    main()
