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
I18N_SCRIPT="${SCRIPT_DIR}/lint_i18n_gate.py"

if [ -f "${I18N_SCRIPT}" ]; then
    python3 "${I18N_SCRIPT}" --dir "${APPLE_ROOT}" "$@"
else
    echo "⚠️ i18n lint script not found at ${I18N_SCRIPT}"
    exit 1
fi
