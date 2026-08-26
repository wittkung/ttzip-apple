# TTZipPluginKit: TTZip 官方开源插件 SDK (Official Plugin SDK)

<p align="center">
  <b>简体中文</b> | <a href="README.md">English</a>
</p>

`TTZipPluginKit` 是专为 **TTZip / ttsubs** 桌面应用生态设计的统一、安全、高性能插件契约与扩展点协议库。

---

## 核心能力

1. **8 大标准扩展点**：
   - 侧边栏贡献 (`TTZipSidebarContribution`)
   - 3 栏米勒列工作区与容器 (`makeWorkspaceView`)
   - Pro 检查器扩展 (`makeInspectorView`)
   - 预览器扩展 (`TTZipPreviewProvider`)
   - 虚拟归档数据源 (`TTZipVirtualArchiveDataSource`)
   - 全局 Omnibar 命令 (`TTZipOmnibarCommand`)
   - 文件上下文菜单 (`TTZipContextMenuContribution`)
   - 租户隔离安全保险箱 (`TTZipKeychainStore`)

2. **零信任安全门禁与密码学校验**：
   - `TTZipPluginSecurity`：O(1) 内存分块流式 SHA-256 哈希校验、Apple CryptoKit Ed25519 数字签名验证、Zip Slip 路径遍历检测。

3. **两阶段提交原子安装器**：
   - `TTZipPluginInstaller`：支持 `URLSession` 流式下载（Byte-level 进度、实时下载速率）、2PC Staging 隔离校验与 APFS `replaceItem` 原子目录置换。

4. **动态运行时加载器**：
   - `TTZipPluginLoader` 与 `TTZipPluginRegistry`：支持无宿主重启的运行时动态热挂载（Live Hot-Mount）与反注册。

5. **全流程国际化支持 (i18n)**：
   - `TTZipPluginL10n`：内置中英文双语映射，与宿主 `AppLocalizationState` 深度联动。
