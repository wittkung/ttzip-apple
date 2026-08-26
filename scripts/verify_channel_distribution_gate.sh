#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
# All rights reserved.
#
# TTZip: Multi-Channel (MAS vs Direct) Automated CI Gate & Static Sandbox Compliance Guard.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

C_RESET="\033[0m"
C_BOLD="\033[1m"
C_GREEN="\033[1;32m"
C_RED="\033[1;31m"
C_BLUE="\033[1;34m"
C_CYAN="\033[1;36m"
C_YELLOW="\033[1;33m"

BUILD_MODE_FLAG="--debug"
for arg in "$@"; do
    if [ "$arg" = "--release" ] || [ "$arg" = "-r" ]; then
        BUILD_MODE_FLAG="--release"
    elif [ "$arg" = "--debug" ] || [ "$arg" = "-d" ]; then
        BUILD_MODE_FLAG="--debug"
    fi
done

GATE_START_TIME=$(python3 -c "import time; print(time.time())")

echo -e "${C_CYAN}${C_BOLD}======================================================================${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}   TTZip Apple Client: Multi-Channel CI Gate [Mode: ${BUILD_MODE_FLAG#--}]   ${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}======================================================================${C_RESET}"

DIST_MAS_DIR="${REPO_ROOT}/dist/mas"
DIST_DIRECT_DIR="${REPO_ROOT}/dist/direct"
DIST_MAS="${DIST_MAS_DIR}/TTZip.app"
DIST_DIRECT="${DIST_DIRECT_DIR}/TTZip.app"

step_time() {
    python3 -c "import time; print(round(time.time() - $1, 2))"
}

# -----------------------------------------------------------------------------
# Stage 1: Dual-Channel Targeted Unit Tests
# -----------------------------------------------------------------------------
echo -e "\n${C_BOLD}[Stage 1/5] ${C_BLUE}Dual-Channel Targeted Unit Tests...${C_RESET}"

T1_START=$(python3 -c "import time; print(time.time())")
echo -e "  --> [1/2] Testing MAS State Evaluation (${C_YELLOW}-DMAS_BUILD${C_RESET})..."
set +e
swift test --filter ChannelDistributionTests/testChannelStateEvaluation -Xswiftc -DMAS_BUILD 2>&1 | grep -E "Test Suite|passed|failed"
MAS_TEST_EXIT=${PIPESTATUS[0]}
set -e
if [ ${MAS_TEST_EXIT} -ne 0 ]; then
    echo -e "      ${C_RED}❌ MAS configuration test failed (exit code ${MAS_TEST_EXIT})${C_RESET}"
    exit ${MAS_TEST_EXIT}
fi
echo -e "      ${C_GREEN}✓${C_RESET} MAS configuration verified ($(step_time "${T1_START}")s)"

T2_START=$(python3 -c "import time; print(time.time())")
echo -e "  --> [2/2] Testing Direct State Evaluation (${C_YELLOW}-DDIRECT_BUILD${C_RESET})..."
set +e
swift test --filter ChannelDistributionTests/testChannelStateEvaluation -Xswiftc -DDIRECT_BUILD 2>&1 | grep -E "Test Suite|passed|failed"
DIRECT_TEST_EXIT=${PIPESTATUS[0]}
set -e
if [ ${DIRECT_TEST_EXIT} -ne 0 ]; then
    echo -e "      ${C_RED}❌ Direct configuration test failed (exit code ${DIRECT_TEST_EXIT})${C_RESET}"
    exit ${DIRECT_TEST_EXIT}
fi
echo -e "      ${C_GREEN}✓${C_RESET} Direct configuration verified ($(step_time "${T2_START}")s)"

# -----------------------------------------------------------------------------
# Stage 2: Packaging Both Channels in Isolated Build Directories (Zero Thrashing)
# -----------------------------------------------------------------------------
echo -e "\n${C_BOLD}[Stage 2/5] ${C_BLUE}Packaging Isolated .app Bundles (${BUILD_MODE_FLAG#--})...${C_RESET}"

mkdir -p "${DIST_MAS_DIR}" "${DIST_DIRECT_DIR}"

T3_START=$(python3 -c "import time; print(time.time())")
echo -e "  --> [1/2] Bundling MAS App (${C_YELLOW}Ad-hoc Sign, Entitlements: MAS${C_RESET})..."
"${SCRIPT_DIR}/bundle_app.sh" --channel mas "${BUILD_MODE_FLAG}" --identity "-" --out-dir "${DIST_MAS_DIR}" > /dev/null
echo -e "      ${C_GREEN}✓${C_RESET} MAS bundle packaged ($(step_time "${T3_START}")s)"

T4_START=$(python3 -c "import time; print(time.time())")
echo -e "  --> [2/2] Bundling Direct App (${C_YELLOW}Ad-hoc Sign, Entitlements: Direct${C_RESET})..."
"${SCRIPT_DIR}/bundle_app.sh" --channel direct "${BUILD_MODE_FLAG}" --identity "-" --out-dir "${DIST_DIRECT_DIR}" > /dev/null
echo -e "      ${C_GREEN}✓${C_RESET} Direct bundle packaged ($(step_time "${T4_START}")s)"

# -----------------------------------------------------------------------------
# Stage 3: Sparkle Framework Stripping & Mach-O Dependency Assertion Gate
# -----------------------------------------------------------------------------
echo -e "\n${C_BOLD}[Stage 3/5] ${C_BLUE}Verifying Sparkle Framework Isolation & Stripping...${C_RESET}"

# 1. MAS: Sparkle must be physically absent
if [ -d "${DIST_MAS}/Contents/Frameworks/Sparkle.framework" ]; then
    echo -e "  ${C_RED}❌ FAIL: Sparkle.framework detected in MAS build bundle!${C_RESET}"
    exit 1
fi
echo -e "  ${C_GREEN}✓${C_RESET} MAS: Sparkle.framework strictly stripped."

# 2. Direct: Sparkle must be physically present
if [ ! -d "${DIST_DIRECT}/Contents/Frameworks/Sparkle.framework" ]; then
    echo -e "  ${C_RED}❌ FAIL: Sparkle.framework missing in Direct build bundle!${C_RESET}"
    exit 1
fi
echo -e "  ${C_GREEN}✓${C_RESET} Direct: Sparkle.framework embedded."

# -----------------------------------------------------------------------------
# Stage 4: Codesign Signature & App Sandbox Entitlements Assertion Gate
# -----------------------------------------------------------------------------
echo -e "\n${C_BOLD}[Stage 4/5] ${C_BLUE}Verifying CodeSign Entitlements & App Sandbox Compliance...${C_RESET}"

# 1. MAS Sandbox Entitlements
MAS_ENT_TMP=$(mktemp)
codesign -d --entitlements - --xml "${DIST_MAS}" > "${MAS_ENT_TMP}" 2>/dev/null || true
if ! grep -q '<key>com.apple.security.app-sandbox</key>[[:space:]]*<true/>' "${MAS_ENT_TMP}"; then
    echo -e "  ${C_RED}❌ FAIL: MAS build missing '<key>com.apple.security.app-sandbox</key><true/>'!${C_RESET}"
    rm -f "${MAS_ENT_TMP}"
    exit 1
fi
echo -e "  ${C_GREEN}✓${C_RESET} MAS: Sandbox entitlement confirmed (<true/>)."
rm -f "${MAS_ENT_TMP}"

# 2. Direct Sandbox Absence (must NOT have app-sandbox set to true)
DIRECT_ENT_TMP=$(mktemp)
codesign -d --entitlements - --xml "${DIST_DIRECT}" > "${DIRECT_ENT_TMP}" 2>/dev/null || true
if grep -q '<key>com.apple.security.app-sandbox</key>[[:space:]]*<true/>' "${DIRECT_ENT_TMP}"; then
    echo -e "  ${C_RED}❌ FAIL: Direct build should NOT have App Sandbox enabled!${C_RESET}"
    rm -f "${DIRECT_ENT_TMP}"
    exit 1
fi
echo -e "  ${C_GREEN}✓${C_RESET} Direct: Non-sandbox entitlement confirmed (<false/>)."
rm -f "${DIRECT_ENT_TMP}"


# -----------------------------------------------------------------------------
# Stage 5: Resource & Cryptographic Integrity Gate
# -----------------------------------------------------------------------------
echo -e "\n${C_BOLD}[Stage 5/5] ${C_BLUE}Verifying Bundle Structure & Signatures...${C_RESET}"

for BUNDLE in "${DIST_MAS}" "${DIST_DIRECT}"; do
    B_NAME="$(basename "$(dirname "${BUNDLE}")")"
    [ -f "${BUNDLE}/Contents/Info.plist" ] || { echo "❌ Missing Info.plist in ${B_NAME}"; exit 1; }
    [ -f "${BUNDLE}/Contents/PkgInfo" ] || { echo "❌ Missing PkgInfo in ${B_NAME}"; exit 1; }
    codesign --verify --deep --strict "${BUNDLE}"
    echo -e "  ${C_GREEN}✓${C_RESET} ${B_NAME}: Valid bundle structure & code signature."
done

TOTAL_TIME=$(python3 -c "import time; print(round(time.time() - ${GATE_START_TIME}, 2))")

echo -e "\n${C_CYAN}${C_BOLD}======================================================================${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}🎉 All Multi-Channel CI Gates PASSED (Total: ${TOTAL_TIME}s)${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}======================================================================${C_RESET}"
