#!/usr/bin/env bash
# Copyright 2026 MetastudyLine. All rights reserved.
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOC_SCRIPT="${SCRIPT_DIR}/lint_loc_gate.py"

if [ -f "${LOC_SCRIPT}" ]; then
    python3 "${LOC_SCRIPT}" --dir "${APPLE_ROOT}" --min-files 10 "$@"
else
    echo "⚠️ LOC script not found at ${LOC_SCRIPT}"
    exit 1
fi
