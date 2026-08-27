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
ARCH_SCRIPT="${SCRIPT_DIR}/lint_architecture_gate.py"

if [ -f "${ARCH_SCRIPT}" ]; then
    python3 "${ARCH_SCRIPT}" --dir "${APPLE_ROOT}" "$@"
else
    echo "⚠️ Architecture lint script not found at ${ARCH_SCRIPT}"
    exit 1
fi
