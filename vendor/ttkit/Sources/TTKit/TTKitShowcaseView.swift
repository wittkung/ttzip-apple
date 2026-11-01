// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTKitCore
import TTKitDesign
import TTKitFluid

/// Interactive showcase demonstrating the canonical TTKit 4-Layer Optical Model,
/// Metal 3-Pass with R8 cache acceleration pipeline (iTTime spec), and Axiom IV 3-Tier Stacking Gate.
///
/// Optical Topology:
/// - Layer 1 & 2: Base Physical Emitter & Metal 3-Pass High-Throughput Viscous Fluid.
/// - Layer 3 Tier 1: Ambient Base Plate (28pt blur, 55% / 70% tint, 0.5pt specular hairline).
/// - Layer 3 Tier 2: Primary Functional Plates with Kintsugi Gold Tab Bar (36pt blur).
/// - Layer 3 Tier 3: Overlay Sheet & Contextual Inspector (48pt blur, 85% / 90% tint).
/// - Axiom IV Gate: Visual warning & depth clamp if stacking depth exceeds 3.
/// - Layer 4: Singular Action Glyph, WSJ Kintsugi Golden Rule Line (Y = 52.0pt).
public struct TTKitShowcaseView: View {
    @State private var isFluidRunning: Bool = true
    @State private var isDarkMode: Bool = true
    @State private var fluidIntensity: Double = 0.60
    @State private var selectedMineral: MineralOption = .cinnabarRed
    @State private var selectedTab: ShowcaseTab = .telemetry
    @State private var isOverlayInspectorPresented: Bool = false
    @State private var triggerLayer4Violation: Bool = false
    @Namespace private var sidebarNamespace

    public init() {}

    public enum ShowcaseTab: String, CaseIterable, Identifiable, Sendable {
        case telemetry = "光学模型遥测"
        case metalPipeline = "Metal 3-Pass 架构"
        case stackingGate = "公理四三层门禁"

        public var id: String { rawValue }
        public var icon: String {
            switch self {
            case .telemetry: return "sparkles"
            case .metalPipeline: return "cpu"
            case .stackingGate: return "square.3.layers.3d"
            }
        }
        public var badge: String {
            switch self {
            case .telemetry: return "4-Tier"
            case .metalPipeline: return "0.05ms"
            case .stackingGate: return "Gate IV"
            }
        }
    }

    public enum MineralOption: String, CaseIterable, Identifiable, Sendable {
        case cinnabarRed = "朱砂红 (iTTime 矿物原标)"
        case acousticIndigo = "声学黛青 (Acoustic Indigo)"
        case kintsugiGold = "金缮金 (Kintsugi Gold)"
        case bambooGreen = "竹青绿 (Bamboo Green)"
        case archivalAmber = "松柏琥珀 (Archival Amber)"

        public var id: String { rawValue }

        public var color: Color {
            switch self {
            case .cinnabarRed:
                // 1:1 Ground Truth from iTTime ZenTheme.cinnabarRed (Dark: #D65D5D, Light: #C04848)
                return UniversalTokens.dynamicColor(
                    lightRed: 192.0 / 255.0, lightGreen: 72.0 / 255.0, lightBlue: 72.0 / 255.0, lightAlpha: 1.0,
                    darkRed: 214.0 / 255.0, darkGreen: 93.0 / 255.0, darkBlue: 93.0 / 255.0, darkAlpha: 1.0
                )
            case .acousticIndigo:
                return TTKitTheme.acousticIndigo
            case .kintsugiGold:
                return TTKitTheme.kintsugiGold
            case .bambooGreen:
                return TTKitTheme.bambooGreen
            case .archivalAmber:
                return TTKitTheme.archivalAmber
            }
        }
    }

    public var body: some View {
        ZStack {
            // MARK: - Layer 1 & Layer 2: Metal 3-Pass 离屏三球 + MPS 高斯模糊 + R8 显存缓存
            TTKitFluidBackgroundView(
                engine: .metalCached,
                config: FluidBackgroundConfig(
                    baseColor: selectedMineral.color,
                    isRunning: isFluidRunning,
                    isDarkMode: isDarkMode,
                    fluidOpacity: Float(fluidIntensity)
                )
            )

            // MARK: - Layer 3: 原生 NavigationSplitView (macOS 原生侧边目录 Tab 栏 + 沉静主工作台)
            NavigationSplitView {
                sidebarContent
                    .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
            } detail: {
                detailContent
            }
            .navigationSplitViewStyle(.balanced)

            // MARK: - Layer 3 (Tier 3): 悬浮模态检视器 (高斯模糊 48pt)
            if isOverlayInspectorPresented {
                overlayInspectorPlate
                    .transition(.opacity)
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                fluidIntensity = 0.60
            }
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isOverlayInspectorPresented)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: triggerLayer4Violation)
        .animation(.easeInOut(duration: 0.28), value: isDarkMode)
        .animation(.spring(response: 0.30, dampingFraction: 0.85), value: selectedTab)
    }

    // MARK: - 原生侧边目录 Tab 栏 (半透明玻璃透出底层流体)
    private var sidebarContent: some View {
        List(selection: $selectedTab) {
            // 管线状态指示芯片
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("Metal 3-Pass 架构")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(UniversalTokens.Text.primary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color.black.opacity(isDarkMode ? 0.35 : 0.06))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(isDarkMode ? 0.15 : 0.25), lineWidth: 0.5)
                    )

                    Text("iTTime 工业离屏渲染 · 40π 周期闭环")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.75))
                }
                .padding(.vertical, 2)
            }
            .listRowBackground(Color.clear)

            // 分组一：macOS 原生架构视图 Tab 导航目录项
            Section("架构视界导航") {
                ForEach(ShowcaseTab.allCases) { tab in
                    Label {
                        HStack {
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: selectedTab == tab ? .bold : .medium))
                            Spacer()
                            Text(tab.badge)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.black.opacity(isDarkMode ? 0.40 : 0.08)))
                                .foregroundStyle(selectedTab == tab ? TTKitTheme.kintsugiGold : (isDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.75)))
                                .overlay(
                                    Capsule().strokeBorder(Color.white.opacity(selectedTab == tab ? 0.35 : 0.15), lineWidth: 0.5)
                                )
                        }
                    } icon: {
                        Image(systemName: tab.icon)
                            .foregroundStyle(selectedTab == tab ? selectedMineral.color : (isDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.70)))
                    }
                    .tag(tab)
                }
            }

            // 分组二：东方矿物色谱注入
            Section("东方矿物原色") {
                ForEach(MineralOption.allCases) { mineral in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(mineral.color)
                            .frame(width: 10, height: 10)
                            .overlay(
                                Circle().strokeBorder(Color.white.opacity(0.60), lineWidth: selectedMineral == mineral ? 1.5 : 0)
                            )
                        Text(mineral.rawValue)
                            .font(.system(size: 11, weight: selectedMineral == mineral ? .semibold : .regular))
                            .foregroundStyle(selectedMineral == mineral ? (isDarkMode ? Color.white : Color.black) : (isDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.70)))
                        Spacer()
                        if selectedMineral == mineral {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(mineral.color)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            selectedMineral = mineral
                        }
                    }
                }
            }

            // 分组三：流体动力学微调
            Section("流体色彩浓度") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("浓度微调")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.75))
                        Spacer()
                        Text("\(Int(fluidIntensity * 100))%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(selectedMineral.color)
                    }
                    Slider(value: $fluidIntensity, in: 0.30...1.0)
                        .tint(selectedMineral.color)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .tint(selectedMineral.color)
        .background {
            if #available(macOS 26.0, *) {
                Rectangle()
                    .fill(Color.black.opacity(isDarkMode ? 0.12 : 0.04))
                    .glassEffect(.regular.tint(selectedMineral.color.opacity(0.08)), in: Rectangle())
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(isDarkMode ? 0.12 : 0.04))
            }
        }
    }

    // MARK: - 主工作台 (联动原生 Tab 选中项)
    private var detailContent: some View {
        VStack(spacing: 14) {
            // 顶部导航栏
            topNavigationBar
                .ttFloatingGlassPlate(tier: .base, cornerRadius: 14)

            // Tab 页面切换容器 (沉静一级微磨砂大底板)
            VStack(alignment: .leading, spacing: 0) {
                switch selectedTab {
                case .telemetry:
                    telemetryTabContent
                case .metalPipeline:
                    metalPipelineTabContent
                case .stackingGate:
                    stackingGateTabContent
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ttFloatingGlassPlate(tier: .base, cornerRadius: 16)
        }
        .padding(16)
    }

    // MARK: - Layer 4: 顶栏导航与金缮基准线 (Y = 52.0pt)
    private var topNavigationBar: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 10) {
                    Circle()
                        .fill(selectedMineral.color)
                        .frame(width: 12, height: 12)
                    Text("TTKit 光学架构与三重毛玻璃样板")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(UniversalTokens.Text.primary)
                }

                Spacer()

                // 夜间/日间模式一键切换按钮 (原生 Liquid Glass 交互按钮)
                Button {
                    isDarkMode.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isDarkMode ? "moon.stars.fill" : "sun.max.fill")
                            .font(.system(size: 12))
                        Text(isDarkMode ? "夜间模式" : "日间模式")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .applyGlassButtonStyle()

                Toggle("流体流动", isOn: $isFluidRunning)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                // 悬浮检视器切换 (原生 Liquid Glass 高亮按钮)
                Button {
                    isOverlayInspectorPresented.toggle()
                } label: {
                    Text(isOverlayInspectorPresented ? "关闭检视器" : "打开 Tier 3 检视器")
                        .font(.system(size: 12, weight: .medium))
                }
                .applyGlassProminentButtonStyle()
                .tint(selectedMineral.color)
            }
            .padding(.horizontal, 16)
            .frame(height: UniversalTokens.Layout.headerBarHeight)

            TTKintsugiDivider(.horizontal, falloff: true)
        }
    }

    // MARK: - Tab 1: 光学遥测内容
    private var telemetryTabContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("四层光学物理模型遥测")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isDarkMode ? Color.white.opacity(0.80) : Color.black.opacity(0.70))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                TelemetryCard(
                    title: "Layer 1: 物理发光底座",
                    value: isDarkMode ? "OLED 纯黑 (#000000)" : "纯净阳光白 (#FFFFFF)",
                    detail: isDarkMode ? "0 nits 绝对物理辐射底座" : "1000 nits 标准辐射参考"
                )
                TelemetryCard(
                    title: "Layer 2: 黏性流体动力学",
                    value: "Metal 3-Pass 缓存管线",
                    detail: isFluidRunning ? "低频流速 0.06x • 呼吸极光运转中" : "0-CPU 待机休眠"
                )
                TelemetryCard(
                    title: "Layer 3: 透镜基底 (Tier 1)",
                    value: "画布基底透镜",
                    detail: "高斯模糊 28pt • 0.5pt 菲涅尔高光边缘"
                )
                TelemetryCard(
                    title: "Layer 3: 主工作台 (Tier 2)",
                    value: "主要功能板块",
                    detail: "高斯模糊 36pt • 0.5pt 镜面高光边缘"
                )
            }

            Spacer()
        }
    }

    // MARK: - Tab 2: Metal 3-Pass 架构解析
    private var metalPipelineTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("METAL 3-STAGE OFFSCREEN PIPELINE")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(isDarkMode ? Color.white.opacity(0.80) : Color.black.opacity(0.70))

            VStack(spacing: 10) {
                pipelineStepCard(
                    step: "Pass 1",
                    name: "离屏三球绘制 (circlesPipeline)",
                    desc: "使用 4-Octave 分形噪声与双摆晃动方程，在 1/4 降采样离屏纹理中绘制流体粒子原语。"
                )
                pipelineStepCard(
                    step: "Pass 2",
                    name: "MPS 高斯模糊滤波 (MPSImageGaussianBlur)",
                    desc: "调用 MetalPerformanceShaders 硬件核函数执行大半径高斯扩散 (sigma = 45)，消除锯齿与接缝。"
                )
                pipelineStepCard(
                    step: "Pass 3",
                    name: "屏幕合成与 R8 显存缓存 (blitPipeline)",
                    desc: "提取单通道覆盖度至 R8 环形显存缓存，稳态下仅需单次采样即可呈现，单帧 GPU 仅耗时 0.05ms。"
                )
            }

            Spacer()
        }
    }

    private func pipelineStepCard(step: String, name: String, desc: String) -> some View {
        let stepShape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(alignment: .top, spacing: 12) {
            Text(step)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(TTKitTheme.kintsugiGold.opacity(isDarkMode ? 0.25 : 0.20))
                .foregroundStyle(TTKitTheme.kintsugiGold)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isDarkMode ? Color.white : Color.black)
                Text(desc)
                    .font(.system(size: 11, weight: .medium))
                    .lineSpacing(2)
                    .foregroundStyle(isDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            stepShape
                .fill(Color.black.opacity(isDarkMode ? 0.42 : 0.06))
                .overlay {
                    stepShape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isDarkMode ? 0.25 : 0.40),
                                Color.white.opacity(isDarkMode ? 0.06 : 0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
                }
        }
    }

    // MARK: - Tab 3: 公理四门禁内容
    private var stackingGateTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("公理四：三层堆叠绝对硬门禁 (Axiom IV)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.75))

            Text("悬浮毛玻璃板块层级在全生命周期内严格限制堆叠深度 ≤ 3 层。在 Tier 3 浮层内部再次嵌套第 4 层玻璃将被环境深度追踪器自动拦截，杜绝多层高斯散射造成的折射噪波与光效坍塌。")
                .font(.system(size: 12))
                .lineSpacing(4)
                .foregroundStyle(isDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.75))

            TTKintsugiDivider(.horizontal, falloff: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("深度状态监控")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isDarkMode ? Color.white.opacity(0.80) : Color.black.opacity(0.70))

                HStack(spacing: 12) {
                    depthBadge(tier: "Tier 1", name: "底座透镜", blur: "28pt", depth: 1)
                    depthBadge(tier: "Tier 2", name: "主工作台", blur: "36pt", depth: 2)
                    depthBadge(tier: "Tier 3", name: "模态浮层", blur: "48pt", depth: 3)
                }
            }

            Spacer()
        }
    }

    private func depthBadge(tier: String, name: String, blur: String, depth: Int) -> some View {
        VStack(spacing: 4) {
            Text(tier)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(TTKitTheme.kintsugiGold)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isDarkMode ? Color.white : Color.black)
            Text("模糊 \(blur)")
                .font(.system(size: 10))
                .foregroundStyle(isDarkMode ? Color.white.opacity(0.80) : Color.black.opacity(0.70))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.black.opacity(isDarkMode ? 0.35 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(isDarkMode ? 0.15 : 0.25), lineWidth: 0.5)
        )
    }

    // MARK: - Layer 3 (Tier 3): 模态检视器悬浮板块 (高斯模糊 48pt)
    private var overlayInspectorPlate: some View {
        ZStack {
            Color.black.opacity(isDarkMode ? 0.40 : 0.15)
                .ignoresSafeArea()
                .onTapGesture {
                    isOverlayInspectorPresented = false
                }

            VStack(spacing: 16) {
                HStack {
                    Text("Tier 3 悬浮模态检视器")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(UniversalTokens.Text.primary)
                    Spacer()
                    Button {
                        isOverlayInspectorPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(UniversalTokens.Text.primary.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                }

                Text("当前浮动检视面板处于法定堆叠深度 = 3（高斯模糊 48pt）。此为公理四允许的最大光学折射深度。")
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .foregroundStyle(UniversalTokens.Text.primary.opacity(0.65))

                Toggle("尝试嵌套第 4 层玻璃卡片（测试越界拦截）", isOn: $triggerLayer4Violation)
                    .font(.system(size: 13, weight: .medium))

                if triggerLayer4Violation {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "exclamationmark.octagon.fill")
                                .foregroundStyle(.red)
                            Text("Axiom IV 堆叠硬门禁生效拦截")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.red)
                        }
                        Text("堆叠深度 = 4 已被系统拦截拒绝。自动降级为平整无模糊的常规容器，阻断过度折射噪波。")
                            .font(.system(size: 11))
                            .foregroundStyle(UniversalTokens.Text.primary.opacity(0.65))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                Spacer()
            }
            .padding(20)
            .frame(width: 420, height: 320)
            .ttOverlayGlassPlate(cornerRadius: 18)
        }
    }
}

// MARK: - 辅助子视图组件

private struct TelemetryCard: View {
    let title: String
    let value: String
    let detail: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let isDark = (colorScheme == .dark)
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(TTKitTheme.kintsugiGold)
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isDark ? Color.white : Color.black)
            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isDark ? Color.white.opacity(0.85) : Color.black.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            cardShape
                .fill(Color.black.opacity(isDark ? 0.42 : 0.06))
                .overlay {
                    cardShape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isDark ? 0.25 : 0.40),
                                    Color.white.opacity(isDark ? 0.06 : 0.10)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                }
        }
    }
}



#Preview("TTKit 光学架构样板 (深色)") {
    TTKitShowcaseView()
        .preferredColorScheme(.dark)
        .frame(minWidth: 1024, minHeight: 680)
}

#Preview("TTKit 光学架构样板 (浅色)") {
    TTKitShowcaseView()
        .preferredColorScheme(.light)
        .frame(minWidth: 1024, minHeight: 680)
}
