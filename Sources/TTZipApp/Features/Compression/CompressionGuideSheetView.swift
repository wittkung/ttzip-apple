// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Compression algorithms, container formats, and advanced parameters guide sheet.
public struct CompressionGuideSheetView: View {
    @Binding public var isPresented: Bool
    @State private var selectedTab: Int
    private var l10n = AppLocalizationState.shared

    public init(isPresented: Binding<Bool>, initialTab: Int = 0) {
        self._isPresented = isPresented
        self._selectedTab = State(initialValue: initialTab)
    }

    public var headerBadgeText: String {
        l10n.uiString(
            zh: "压缩百科指南",
            en: "COMPRESSION ENCYCLOPEDIA",
            zhHant: "壓縮百科指南"
        )
    }

    public var headerTitleText: String {
        l10n.uiString(
            zh: "压缩算法、容器格式与高级参数指南",
            en: "Compression Algorithms, Formats & Advanced Guide",
            zhHant: "壓縮演算法、容器格式與進階參數指南"
        )
    }

    public var tabTitles: [String] {
        [
            l10n.uiString(zh: "📦 容器格式", en: "📦 Formats", zhHant: "📦 容器格式"),
            l10n.uiString(zh: "⚡ 压缩算法", en: "⚡ Algorithms", zhHant: "⚡ 壓縮演算法"),
            l10n.uiString(zh: "🎛 高级参数", en: "🎛 Parameters", zhHant: "🎛 進階參數"),
            l10n.uiString(zh: "🔒 加密与分卷", en: "🔒 Security & Splits", zhHant: "🔒 加密與分卷")
        ]
    }

    public var footerSubtitleText: String {
        l10n.uiString(
            zh: "TTZip 架构白皮书与人机界面参考指南",
            en: "TTZip Architecture Whitepaper & HIG Reference",
            zhHant: "TTZip 架構白皮書與人機介面參考指南"
        )
    }

    public var doneButtonTitle: String {
        l10n.uiString(zh: "完成", en: "Done", zhHant: "完成")
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "book.pages.fill")
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                        Text(headerBadgeText)
                            .font(.system(size: 9, weight: .bold, design: .serif))
                            .tracking(2)
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                    }
                    Text(headerTitleText)
                        .font(.system(size: 15, weight: .bold, design: .serif))
                        .foregroundStyle(.primary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.primary.opacity(0.025))

            Divider()

            let titles = tabTitles
            HStack(spacing: 6) {
                ForEach(titles.indices, id: \.self) { idx in
                    tabButton(title: titles[idx], index: idx)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.015))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTab {
                    case 0: formatsGuideSection
                    case 1: algorithmsGuideSection
                    case 2: advancedParamsSection
                    case 3: securityAndSplitSection
                    default: EmptyView()
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Text(footerSubtitleText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(doneButtonTitle) {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .tint(TTZipTheme.bambooGreen)
                .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(width: 660, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func tabButton(title: String, index: Int) -> some View {
        let isSelected = selectedTab == index
        return Button(action: { selectedTab = index }) {
            Text(title)
                .font(.system(size: 11.5, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? TTZipTheme.bambooGreen : Color.primary.opacity(0.04))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var formatsGuideSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            guideCard(
                icon: "archivebox.fill",
                title: l10n.uiString(zh: ".7z（7-Zip 高压缩率归档）", en: ".7z (7-Zip High Compression)", zhHant: ".7z（7-Zip 高壓縮率封存）"),
                badge: l10n.uiString(zh: "高压缩率", en: "High Ratio", zhHant: "高壓縮率"),
                content: l10n.uiString(
                    zh: "由 Igor Pavlov 设计的开放架构容器格式。支持多线程 LZMA2、固实归档（Solid）、文件名头部加密（-mhe=on）以及最高 1536MB 字典，适合源码、文档与极致空间节省。",
                    en: "Open architecture format designed by Igor Pavlov. Supports multithreaded LZMA2, Solid Archive block packing, header encryption (-mhe=on), and dictionaries up to 512MB. Ideal for source code, large documents, and maximum space savings.",
                    zhHant: "由 Igor Pavlov 設計的開放架構容器格式。支援多執行緒 LZMA2、固實封存（Solid）、檔名標頭加密（-mhe=on）以及最高 1536MB 字典，適合原始碼、文件與極致空間節省。"
                )
            )

            guideCard(
                icon: "doc.zipper",
                title: l10n.uiString(zh: ".zip（ZIP 通用标准）", en: ".zip (ZIP Standard)", zhHant: ".zip（ZIP 通用標準）"),
                badge: l10n.uiString(zh: "全平台通用", en: "Universal", zhHant: "全平台通用"),
                content: l10n.uiString(
                    zh: "macOS、Windows、Linux、iOS 与 Android 原生支持的跨平台通用标准。支持 Deflate、AES-256 加密与 UTF-8 编码标记，杜绝跨平台文件名乱码。",
                    en: "Universal cross-platform standard with built-in support on macOS, Windows, Linux, iOS, and Android. Features Deflate, AES-256 encryption, and UTF-8 encoding flags to prevent filename corruption across platforms.",
                    zhHant: "macOS、Windows、Linux、iOS 與 Android 原生支援的跨平台通用標準。支援 Deflate、AES-256 加密與 UTF-8 編碼標記，杜絕跨平台檔名亂碼。"
                )
            )

            guideCard(
                icon: "bolt.horizontal.fill",
                title: l10n.uiString(zh: ".tar.zst / .zst（Zstandard 极速流）", en: ".tar.zst / .zst (Zstandard)", zhHant: ".tar.zst / .zst（Zstandard 極速串流）"),
                badge: l10n.uiString(zh: "超高速", en: "Ultra-Fast", zhHant: "超高速"),
                content: l10n.uiString(
                    zh: "Meta 研发的下一代高吞吐压缩算法，结合 POSIX tar 打包可提供 600–900 MB/s 的压缩与解压吞吐量，非常适合大型数据集与快照备份。",
                    en: "Next-generation high-throughput algorithm developed by Meta (Facebook). Combined with POSIX streaming, delivers 600-900 MB/s compression and extraction speeds, ideal for large datasets and backups.",
                    zhHant: "Meta 研發的下一代高吞吐壓縮演算法，結合 POSIX tar 打包可提供 600–900 MB/s 的壓縮與解壓吞吐量，非常適合大型資料集與快照備份。"
                )
            )

            guideCard(
                icon: "terminal.fill",
                title: l10n.uiString(zh: ".tar.gz / .tar.bz2 / .tar.xz（Unix 归档包）", en: ".tar.gz / .tar.bz2 / .tar.xz (Unix Tarball)", zhHant: ".tar.gz / .tar.bz2 / .tar.xz（Unix 封存包）"),
                badge: "POSIX",
                content: l10n.uiString(
                    zh: "标准 Unix 归档容器配合流式压缩（Gzip、Bzip2 或 XZ），完整保留 POSIX 权限位、时间戳与扩展属性。",
                    en: "Standard Unix archive packaging paired with streaming compression (Gzip, Bzip2, or XZ). Preserves POSIX file modes, timestamps, and extended attributes.",
                    zhHant: "標準 Unix 封存容器配合串流壓縮（Gzip、Bzip2 或 XZ），完整保留 POSIX 權限位、時間戳與擴充屬性。"
                )
            )
        }
    }

    private var algorithmsGuideSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            guideCard(
                icon: "cpu",
                title: l10n.uiString(zh: "LZMA2（高压缩率与多线程）", en: "LZMA2 (High Ratio & Multithreading)", zhHant: "LZMA2（高壓縮率與多執行緒）"),
                badge: l10n.uiString(zh: "7z 默认", en: "7z Default", zhHant: "7z 預設"),
                content: l10n.uiString(
                    zh: "支持并行分块与大字典窗口的增强型 LZMA 算法，在文档、二进制与代码上均能提供顶级压缩率。",
                    en: "Enhanced LZMA algorithm with parallel chunking and dictionary buffers up to 512MB. Delivers top-tier compression ratios across documents, binaries, and code.",
                    zhHant: "支援平行分塊與大字典視窗的增強型 LZMA 演算法，在文件、二進位與程式碼上均能提供頂級壓縮率。"
                )
            )

            guideCard(
                icon: "doc.text.fill",
                title: l10n.uiString(zh: "PPMd（文本与源码预测）", en: "PPMd (Text / Code Prediction)", zhHant: "PPMd（文字與原始碼預測）"),
                badge: l10n.uiString(zh: "文本专精", en: "Text Specialist", zhHant: "文字專精"),
                content: l10n.uiString(
                    zh: "由 Dmitry Shkarin 设计的偏匹配预测算法，针对纯文本、源代码、HTML 与 JSON 结构化数据深度优化。",
                    en: "Prediction by Partial Matching algorithm designed by Dmitry Shkarin. Optimized for pure text, source code, HTML, and JSON data structures.",
                    zhHant: "由 Dmitry Shkarin 設計的偏匹配預測演算法，針對純文字、原始碼、HTML 與 JSON 結構化資料深度最佳化。"
                )
            )

            guideCard(
                icon: "square.stack.3d.down.right.fill",
                title: l10n.uiString(zh: "Deflate / Deflate64（通用标准）", en: "Deflate / Deflate64 (Standard)", zhHant: "Deflate / Deflate64（通用標準）"),
                badge: "ZIP / GZIP",
                content: l10n.uiString(
                    zh: "经典 LZ77 与霍夫曼编码管线，解码轻量快速，兼容所有操作系统。",
                    en: "Classic LZ77 and Huffman coding pipeline. Fast hardware decoding and universal compatibility across all operating systems.",
                    zhHant: "經典 LZ77 與霍夫曼編碼管線，解碼輕量快速，相容所有作業系統。"
                )
            )

            guideCard(
                icon: "bolt.fill",
                title: l10n.uiString(zh: "Zstd / Zstandard（高吞吐流）", en: "Zstd / Zstandard (High Throughput)", zhHant: "Zstd / Zstandard（高吞吐串流）"),
                badge: l10n.uiString(zh: "现代标准", en: "Modern Standard", zhHant: "現代標準"),
                content: l10n.uiString(
                    zh: "基于有限状态熵（FSE）的现代压缩器，提供媲美 Deflate 的压缩率与 3–5 倍的解压速度。",
                    en: "Finite State Entropy (FSE) based compressor delivering ratios comparable to Deflate with 3x to 5x higher decompression throughput.",
                    zhHant: "基於有限狀態熵（FSE）的現代壓縮器，提供媲美 Deflate 的壓縮率與 3–5 倍的解壓速度。"
                )
            )

            guideCard(
                icon: "shippingbox.fill",
                title: l10n.uiString(zh: "Copy / Store（0% 免压缩直通）", en: "Copy / Store (0% Compression)", zhHant: "Copy / Store（0% 免壓縮直通）"),
                badge: l10n.uiString(zh: "直通打包", en: "Passthrough", zhHant: "直通打包"),
                content: l10n.uiString(
                    zh: "不进行二次压缩计算的直接 I/O 打包，适合 MP4、JPG、MP3 与磁盘镜像等已压缩媒体。",
                    en: "Direct I/O passthrough without compression compute overhead. Ideal for pre-compressed media like MP4, JPG, MP3, and disk images.",
                    zhHant: "不進行二次壓縮計算的直接 I/O 打包，適合 MP4、JPG、MP3 與磁碟映像等已壓縮媒體。"
                )
            )
        }
    }

    private var advancedParamsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            guideCard(
                icon: "memorychip",
                title: l10n.uiString(zh: "字典大小（Dictionary Size）", en: "Dictionary Size", zhHant: "字典大小（Dictionary Size）"),
                badge: l10n.uiString(zh: "内存滑动窗口", en: "Memory Window", zhHant: "記憶體滑動視窗"),
                content: l10n.uiString(
                    zh: "用于匹配重复数据片段的滑动窗口缓存。更大的字典（如 64MB、128MB）能显著提升重复数据压缩率，但会增加内存占用。",
                    en: "Sliding window memory buffer used for matching duplicate data strings. Larger dictionaries (e.g., 64MB, 128MB) improve ratio on repetitive data at the cost of additional RAM usage.",
                    zhHant: "用於匹配重複資料片段的滑動視窗快取。更大的字典（如 64MB、128MB）能顯著提升重複資料壓縮率，但會增加記憶體佔用。"
                )
            )

            guideCard(
                icon: "cube.transparent.fill",
                title: l10n.uiString(zh: "固实归档（Solid Archive）", en: "Solid Archive", zhHant: "固實封存（Solid Archive）"),
                badge: l10n.uiString(zh: "7z 特性", en: "7z Feature", zhHant: "7z 特性"),
                content: l10n.uiString(
                    zh: "将多个文件合并为连续数据流进行跨文件字典匹配，对大批量相似文件可提升 20%–50% 压缩率。",
                    en: "Packs multiple files into a single continuous stream for cross-file dictionary matching. Increases ratio by 20%-50% for batches of similar files.",
                    zhHant: "將多個檔案合併為連續資料流進行跨檔案字典匹配，對大批量相似檔案可提升 20%–50% 壓縮率。"
                )
            )

            guideCard(
                icon: "arrow.triangle.2.circlepath",
                title: l10n.uiString(zh: "长距离匹配（--long=27）", en: "Long Distance Matching (--long=27)", zhHant: "長距離匹配（--long=27）"),
                badge: l10n.uiString(zh: "Zstd 特性", en: "Zstd Feature", zhHant: "Zstd 特性"),
                content: l10n.uiString(
                    zh: "将 Zstandard 匹配窗口扩展至 128MB 以上，用于检测大型文件与日志批次之间的远距离重复数据。",
                    en: "Zstandard LDM window extending up to 128MB+ to detect redundancy across distant large files and log batches.",
                    zhHant: "將 Zstandard 匹配視窗擴展至 128MB 以上，用於偵測大型檔案與日誌批次之間的遠距離重複資料。"
                )
            )
        }
    }

    private var securityAndSplitSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            guideCard(
                icon: "lock.shield.fill",
                title: l10n.uiString(zh: "AES-256 与 ZipCrypto", en: "AES-256 vs ZipCrypto", zhHant: "AES-256 與 ZipCrypto"),
                badge: l10n.uiString(zh: "加密安全", en: "Security", zhHant: "加密安全"),
                content: l10n.uiString(
                    zh: "AES-256 采用硬件加速的 256 位对称加密；ZipCrypto 为传统兼容算法，存在已知密码学弱点，仅建议旧系统兼容时使用。",
                    en: "AES-256 utilizes 256-bit symmetric encryption with hardware SIMD acceleration. ZipCrypto is a legacy algorithm with known cryptographic vulnerabilities.",
                    zhHant: "AES-256 採用硬體加速的 256 位元對稱加密；ZipCrypto 為傳統相容演算法，存在已知密碼學弱點，僅建議舊系統相容時使用。"
                )
            )

            guideCard(
                icon: "eye.slash.fill",
                title: l10n.uiString(zh: "加密文件名（-mhe=on）", en: "Encrypt File Names (-mhe=on)", zhHant: "加密檔名（-mhe=on）"),
                badge: l10n.uiString(zh: "7z 目录保护", en: "7z Header Security", zhHant: "7z 目錄保護"),
                content: l10n.uiString(
                    zh: "加密归档中央目录索引与文件名列表，未输入正确密码前无法查看包内任何文件名或结构。",
                    en: "Encrypts the central archive directory index and filenames. Directory contents remain completely hidden until unlocked with the correct password.",
                    zhHant: "加密封存中央目錄索引與檔名列表，未輸入正確密碼前無法查看包內任何檔名或結構。"
                )
            )

            guideCard(
                icon: "square.split.2x2.fill",
                title: l10n.uiString(zh: "分卷压缩（Volume Splitting）", en: "Volume Splitting", zhHant: "分卷壓縮（Volume Splitting）"),
                badge: l10n.uiString(zh: "多卷切分", en: "Multi-Part", zhHant: "多卷切分"),
                content: l10n.uiString(
                    zh: "将大型归档按指定大小切分为多个分卷（如邮件附件上限或 4GB FAT32 限制），解压首卷即可自动重组完整归档。",
                    en: "Splits large archives into defined volume segments (e.g., 25MB email limit, 4GB FAT32). Selecting the primary volume automatically reassembles the complete archive.",
                    zhHant: "將大型封存按指定大小切分為多個分卷（如郵件附件上限或 4GB FAT32 限制），解壓首卷即可自動重組完整封存。"
                )
            )
        }
    }

    private func guideCard(icon: String, title: String, badge: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(badge)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(TTZipTheme.kintsugiGold.opacity(0.12))
                    .clipShape(Capsule())
            }
            Text(content)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
        }
        .padding(12)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}
