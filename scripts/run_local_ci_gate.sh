#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
# All rights reserved.
#
# TTZip: High-performance native archiving and compression engine.

# Zero-Cloud Local CI/CD Pipeline for TTZip Apple Client (macOS Native App & Extensions).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "======================================================================"
echo "⚡️ Running TTZip Apple Client Local CI Gate (Zero Cloud Quota)..."
echo "======================================================================"

cd "${REPO_ROOT}"

# Stage 1: LOC Gate
echo ">>> [Stage 1/3] LOC Defense Gate..."
"${REPO_ROOT}/scripts/lint_loc_gate.sh"

# Stage 2: Swift UI & Extensions Test Suite
echo ">>> [Stage 2/3] Running macOS Swift App Tests..."
swift test --quiet

# Stage 3: Multi-Channel Packaging & Sandbox Gate
echo ">>> [Stage 3/3] Running Multi-Channel Packaging & Sandbox Gate..."
"${REPO_ROOT}/scripts/verify_channel_distribution_gate.sh"

echo "======================================================================"
echo "✅ Local CI/CD Gate Passed! TTZip Apple Client 100% compliant."
echo "======================================================================"
