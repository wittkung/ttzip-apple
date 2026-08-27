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

# 智能检测本地微内核 (TTZipCore) 是否需要重新编译
if [ -d "../core" ]; then
    VENDOR_LIB="../core/Frameworks/TTZipVendor.xcframework/macos-arm64_x86_64/libTTZipVendor.a"
    [ ! -f "$VENDOR_LIB" ] && VENDOR_LIB="../core/Frameworks/TTZipVendor.xcframework/macos-arm64/libTTZipVendor.a"

    NEED_CORE_BUILD=false
    if [ ! -f "$VENDOR_LIB" ]; then
        echo "--> [INFO] 未检测到预编译 TTZipCore SDK，准备全量编译..."
        NEED_CORE_BUILD=true
    elif [ -n "$(find ../core/rust/src ../core/rust/ttzip-engine/src ../core/rust/Cargo.toml -newer "$VENDOR_LIB" 2>/dev/null | head -n 1)" ]; then
        echo "--> [INFO] 检测到 Rust 微内核源码更新，准备增量编译 TTZipCore..."
        NEED_CORE_BUILD=true
    fi

    if [ "$NEED_CORE_BUILD" = true ]; then
        (cd ../core && ./scripts/build_sdk_framework.sh --release --native --no-zip)
    else
        echo "--> [INFO] TTZipCore 微内核二进制已是最新，跳过编译。"
        # 确保 UniFFI 绑定与 Swift 6 后处理一致
        if [ -f "../core/scripts/postprocess_uniffi_swift.py" ] && [ -f "../core/Sources/TTZipCore/Generated/ttzip_engine.swift" ]; then
            python3 "../core/scripts/postprocess_uniffi_swift.py" "../core/Sources/TTZipCore/Generated/ttzip_engine.swift" >/dev/null 2>&1 || true
        fi
    fi
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

