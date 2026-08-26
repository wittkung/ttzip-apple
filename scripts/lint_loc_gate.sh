#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
# All rights reserved.
#
# TTZip: High-performance native archiving and compression engine.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOC_SCRIPT="${REPO_ROOT}/core/scripts/lint_loc_gate.py"

if [ -f "${LOC_SCRIPT}" ]; then
    python3 "${LOC_SCRIPT}" --dir "${APPLE_ROOT}" --min-files 10 "$@"
else
    echo "⚠️ LOC script not found at ${LOC_SCRIPT}"
    exit 1
fi
