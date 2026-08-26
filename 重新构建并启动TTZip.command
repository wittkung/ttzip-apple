#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
# All rights reserved.
#
# TTZip: High-performance native archiving and compression engine.

# ==============================================================================
# 重新构建并启动TTZip.command
# 一键编译、装配、代码签名并启动 TTZip macOS 原生客户端
# ==============================================================================

set -eo pipefail

# 自动创建 fnm 状态目录，消除本地多终端环境提示
mkdir -p "$HOME/.local/state/fnm_multishells" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "============================================================"
echo "  ⚡ 启动 TTZip macOS 原生客户端全量构建与运行流水线..."
echo "  架构: 独立微内核 SDK (TTZipCore) + Swift 6 原生 App"
echo "============================================================"

# 若本地存在 ../core 但尚未生成 Vendor 二进制，进行友好提示或触发预构建
if [ -d "../core" ] && [ ! -f "../core/Vendor/TTZipVendor.xcframework/macos-arm64_x86_64/libTTZipVendor.a" ] && [ ! -f "../core/Vendor/TTZipVendor.xcframework/macos-arm64/libTTZipVendor.a" ]; then
    echo "--> [INFO] 检测到本地微内核代码库，正在自动预编译 Universal TTZipCore SDK..."
    (cd ../core && ./scripts/build_sdk_framework.sh --release) || true
fi

if [ -f "./scripts/bundle_app.sh" ]; then
    ./scripts/bundle_app.sh --release --open "$@"
elif [ -f "../apple/scripts/bundle_app.sh" ]; then
    ../apple/scripts/bundle_app.sh --release --open "$@"
else
    echo "❌ 错误: 未找到 bundle_app.sh 构建脚本！"
    exit 1
fi

if [ -t 0 ]; then
    echo ""
    echo "💡 构建完成。按任意键关闭此终端窗口..."
    read -n 1 -s -r 2>/dev/null || true
fi
