# TTZip 插件开发入门指南

TTZip 采用 Shared Dynamic Framework (`TTZipPluginKit.framework`) 架构。插件作为动态库加载，与宿主共享同一运行上下文。本指南展示如何从零构建一个标准 TTZip 插件。

## 1. 工程初始化

使用 Swift Package Manager 创建基础库：

```bash
mkdir MyPlugin && cd MyPlugin
swift package init --type library
```

## 2. 配置依赖项

修改 `Package.swift`，通过 `.unsafeFlags` 链接宿主环境的 `TTZipPluginKit`。不建议硬编码本地绝对路径，应使用环境变量或相对构建路径。

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MyPlugin",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MyPlugin", type: .dynamic, targets: ["MyPlugin"]),
    ],
    targets: [
        .target(
            name: "MyPlugin",
            swiftSettings: [
                .unsafeFlags(["-F", "/Applications/TTZip.app/Contents/Frameworks"])
            ],
            linkerSettings: [
                .unsafeFlags(["-F", "/Applications/TTZip.app/Contents/Frameworks"]),
                .linkedFramework("TTZipPluginKit")
            ]
        ),
        .testTarget(
            name: "MyPluginTests",
            dependencies: ["MyPlugin"]
        ),
    ]
)
```

## 3. 实现插件核心契约

在 `Sources/MyPlugin/MyPlugin.swift` 中实现 `TTZipPlugin` 协议。必须导出 C 工厂函数 `@_cdecl("createTTZipPlugin")` 作为宿主反射加载的入口。

```swift
import Foundation
import SwiftUI
import TTZipPluginKit

@MainActor
public final class MyPlugin: TTZipPlugin {
    public let id = "com.example.myplugin"
    private var hostContext: TTZipHostContext?
    
    public init() {}
    
    public func onInitialize(context: TTZipHostContext) async throws {
        self.hostContext = context
        context.log(.info, "MyPlugin", "Initialize success.")
    }
    
    public func onTerminate() async throws {
        hostContext?.log(.info, "MyPlugin", "Terminated.")
    }
}

@_cdecl("createTTZipPlugin")
public func createTTZipPlugin() -> UnsafeMutableRawPointer {
    let plugin = MyPlugin()
    return Unmanaged.passRetained(plugin).toOpaque()
}
```

## 4. 插件元数据与打包

TTZip 插件遵循 macOS Bundle 结构，后缀为 `.ttplugin`。

### 目录结构

```text
MyPlugin.ttplugin/
└── Contents/
    ├── MacOS/
    │   └── MyPlugin (编译输出的动态库二进制)
    └── Resources/
        └── plugin.json (元数据清单)
```

### plugin.json 规范

```json
{
  "id": "com.example.myplugin",
  "version": "1.0.0",
  "minHostVersion": "1.2.0",
  "displayName": "My Demo Plugin",
  "description": "A demo plugin showcasing dynamic framework linking.",
  "author": "Developer Name",
  "permissions": [
    "fs.read",
    "host.notifications"
  ]
}
```

## 5. 单元测试

使用 `MockHostContext`（由 `TTZipPluginKit` 提供）脱离宿主环境编写测试。

```swift
import XCTest
import TTZipPluginKit
@testable import MyPlugin

final class MyPluginTests: XCTestCase {
    @MainActor
    func testInitialization() async throws {
        let plugin = MyPlugin()
        let mockContext = MockHostContext()
        
        try await plugin.onInitialize(context: mockContext)
        XCTAssertEqual(mockContext.logHistory.last?.message, "Initialize success.")
    }
}
```

## 6. 本地部署与调试

将构建产物复制到 TTZip 用户插件目录，并开启开发者模式支持重载。

```bash
# 编译
swift build -c debug

# 组装 Bundle
BUNDLE_DIR=~/Library/Application\ Support/TTZip/Plugins/MyPlugin.ttplugin
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp .build/debug/libMyPlugin.dylib "$BUNDLE_DIR/Contents/MacOS/MyPlugin"
cp plugin.json "$BUNDLE_DIR/Contents/Resources/"
```

在 TTZip 设置面板勾选 **Developer Mode (Auto-Reload)**。一旦 `.ttplugin` 内文件发生变化，宿主将卸载旧动态库并热重载新版本。
