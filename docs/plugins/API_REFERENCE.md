# TTZip 插件 API 参考文档

核心接口由 `TTZipPluginKit` 框架提供，定义了插件生命周期、UI 注入点、宿主环境上下文以及跨域通信模型。

## 1. 插件契约: `TTZipPlugin`

所有插件必须实现 `TTZipPlugin` 协议。宿主通过 `@MainActor` 调度所有生命周期方法与视图构造方法。

```swift
@MainActor
public protocol TTZipPlugin: AnyObject {
    /// 插件全局唯一标识符
    var id: String { get }
    
    // MARK: - 生命周期
    
    /// 初始化加载钩子
    func onInitialize(context: TTZipHostContext) async throws
    /// 卸载或应用退出前清理钩子
    func onTerminate() async throws
    
    // MARK: - 视图扩展点
    
    /// 注入到主侧边栏的图标与标签
    func sidebarItem() -> AnyView?
    /// 注入到主工作区的视图（侧边栏选中时渲染）
    func makeWorkspaceView() -> AnyView?
    /// 注入到偏好设置面板的视图
    func makeSettingsView() -> AnyView?
    /// 注入到右侧属性检查器的视图
    func makeInspectorView(for entry: TTZipArchiveEntry?) -> AnyView?
    
    // MARK: - 操作扩展点
    
    /// 全局命令面板（Cmd+K）扩展命令
    func omnibarCommands() -> [TTZipCommandAction]
    /// 右键上下文菜单扩展操作
    func contextMenuActions(for entries: [TTZipArchiveEntry]) -> [TTZipContextMenuAction]
    
    // MARK: - 能力扩展点
    
    /// 自定义压缩源提供者（如云端网盘集成）
    func archiveSourceProviders() -> [Any]
    /// 针对特定后缀或类型的文件预览提供者
    func previewProviders() -> [Any]
}
```

*(上述扩展点协议提供默认实现返回 `nil` 或空数组，插件仅需按需重写)*

## 2. 宿主上下文: `TTZipHostContext`

宿主在 `onInitialize` 注入此对象，为插件提供安全的系统级能力代理。

```swift
public protocol TTZipHostContext: Sendable {
    // MARK: - 环境隔离
    
    /// 插件专属的持久化存储目录 URL
    var storageDirectory: URL { get }
    
    /// 获取当前插件专属且隔离的 Keychain 访问代理
    func keychain(service: String) -> any KeychainProtocol
    
    // MARK: - 核心引擎代理
    
    /// 提交压缩任务
    func createArchive(sources: [URL], destination: URL, format: String) async throws
    /// 检查归档文件元数据
    func inspectArchive(at url: URL) async throws -> [TTZipArchiveEntry]
    /// 提取归档文件
    func extractArchive(at url: URL, to destination: URL, entries: [String]?) async throws
    
    // MARK: - 交互反馈
    
    /// 触发系统级或应用内通知
    func showNotification(title: String, message: String, level: TTZipNotificationLevel)
    /// 更新全局进度条状态
    func setGlobalProgress(id: String, progress: Double, message: String?)
    
    // MARK: - 日志与通信
    
    /// 写入宿主统一日志系统
    func log(_ level: TTZipPluginLogLevel, _ category: String, _ message: String)
    
    /// 订阅全局事件总线
    func subscribeEvent(name: String, handler: @escaping (Any) -> Void) -> SubscriptionToken
    /// 向事件总线发布事件
    func publishEvent(name: String, payload: Any)
}
```

## 3. 核心数据模型

### TTZipArchiveEntry
描述归档树中的单一节点。

```swift
public struct TTZipArchiveEntry: Identifiable, Sendable {
    public let id: String
    public let path: String
    public let size: Int64
    public let compressedSize: Int64
    public let isDirectory: Bool
    public let modifiedAt: Date?
}
```

### 日志与通知枚举

```swift
public enum TTZipPluginLogLevel: Sendable {
    case debug, info, warning, error, fault
}

public enum TTZipNotificationLevel: Sendable {
    case info, success, warning, error
}
```

### 操作模型

```swift
public struct TTZipCommandAction: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let icon: String?
    public let action: @Sendable () async -> Void
}

public struct TTZipContextMenuAction: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let icon: String?
    public let action: @Sendable ([TTZipArchiveEntry]) async -> Void
}
```

### 事件订阅 Token

```swift
public protocol SubscriptionToken: Sendable {
    /// 取消订阅并释放闭包资源
    func cancel()
}
```
