# 开发提示：应用语言与 macOS 27 Liquid Glass

在现有 SwiftUI macOS 应用 inchspace 中完成以下需求，并保留已有功能和用户未提交的修改。

1. 在「管理」分组添加「应用语言」入口。后台扫描 /Applications、~/Applications、/System/Applications 和系统 CoreServices 应用目录，结合 Spotlight 发现其他位置的应用。按实际路径去重，排除应用包内的辅助程序。提供手动选择 .app 的入口，以覆盖未索引位置。说明权限和 Spotlight 索引对完整性的影响，不承诺扫描到不可访问的应用。
2. 列表显示图标、名称、可用语言数量，支持名称、应用标识和路径搜索。详情显示应用标识、路径、当前语言覆盖、实际声明的语言、跟随系统选项和 Finder 定位。提供加载、空结果和错误状态。
3. 使用当前用户、指定应用域的 AppleLanguages 偏好设置，不改动应用包、不改变全局语言。读取时区分全局默认与单应用覆盖。仅写入应用声明的语言；恢复跟随系统时删除该键。校验保存结果，失败时尝试恢复旧值。提示同一 bundle ID 的多个副本共享设置。
4. 精简详情页，删除常驻说明段落与系统设置链接。保留「仅保存」，提供「保存并重启」主按钮；没有未保存修改时显示「重启应用」。保存成功后才能重启。使用正常退出请求，等待目标退出再按选定路径重新打开；未运行时直接打开。等待期间禁用重复操作并显示简短状态。如果应用拒绝退出、有未保存内容或超时，显示简短错误并保留语言设置，不强制终止进程。系统后台组件和 inchspace 本身禁用重启并通过按钮提示说明原因。仅点击保存不退出应用。对沙盒或自有语言机制，不把偏好写入成功等同于应用采用新语言。
5. 遵循 macOS 27 的 Liquid Glass 设计方向：系统原生侧栏与玻璃控件、导航玻璃层、清晰稳定的内容层、统一留白和圆角、选中项半粗体。公共页头使用系统 glassEffect，支持深浅色、减少透明度和增强对比度。不引入装饰性持续动画，不提高最低系统版本。
6. 增加应用发现、语言枚举、语言保存、恢复默认、拒绝非法偏好域和不支持语言的测试。在 Xcode 27 下构建并运行测试；如环境限制导致验证不完整，明确记录。

## 实现说明

- 新功能：`inchspace/AppLanguage/`；侧栏与路由集成在 `SidebarDestination`、`ContentView`。
- 公共页头：`AppFeatureHeader`，统一影响环境变量、服务器、终端、远程文件与应用语言页。
- 语言写入仅使用 CFPreferences 的精确应用域。不修改 AppleLocale，不直接编辑 plist，不要求管理员权限。
- 应用列表按路径保留同 bundle ID 的多个副本；语言覆盖按 bundle ID 共享。
- 标准应用目录递归扫描；Spotlight 补充发现其他路径。未索引或权限受限的文件并不保证自动出现。
- 手动添加位置在当前页面会话内保留，再次扫描时重新读取。

## 官方依据

- [Modernize your AppKit app — WWDC26](https://developer.apple.com/videos/play/wwdc2026/289/)：macOS 27 对侧栏、工具栏和 Liquid Glass 的原生更新。
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)：优先使用标准控件和系统材质。
- [Change the language your Mac uses](https://support.apple.com/guide/mac-help/mh26684/mac)：单应用语言设置及重新打开应用。
- [CFPreferencesCopyValue](https://developer.apple.com/documentation/corefoundation/cfpreferencescopyvalue(_:_:_:_:))：读取精确偏好域，避免把系统语言误判为单应用设置。

## 本次交互完善

- 删除「下次启动时生效」说明区，操作结果只在保存或重启时出现。
- 保存并重启按「写入、校验、正常退出、等待、重新打开」执行；退出超时为 20 秒。
- 重启只针对所选应用路径，不按名称或 bundle ID 批量结束其他副本。
- 搜索后同步可见选择，避免右侧仍显示隐藏的旧应用；空白应用名称回退到文件名。

## 验证结果

- 新模块与公共页头使用 Xcode 27 Swift 编译器、项目 MainActor 默认隔离设置通过类型检查；独立界面程序成功编译并检查新版页面，说明区已删除。
- 将生产服务源码与 XCTest 测试复制到临时无依赖 Swift Package，10 项测试全部通过：4 项扫描/偏好测试、6 项重启流程测试。重启测试使用注入的进程操作，不退出用户实际应用。
- 完整项目的 xcodebuild test 被现有 SwiftTerm Metal 着色器编译阻止：本机缺少 Metal Toolchain。尚未完成全项目测试或发布构建。

## 快捷筛选补充提示词

在应用语言页的搜索框上方使用原生分段控件「全部 / APPLE / USER」，默认全部；辅助功能名称分别为「全部应用 / Apple 应用 / 用户应用」。分类与名称、应用标识、路径搜索按交集过滤；实时显示命中数与总数。切换分类或关键词后保留仍可见的选中应用，否则选中第一项；无结果时清空选择并显示空状态。重新扫描后保留分类和关键词，并重新协调选择。保存或重启期间禁用筛选，扫描期间禁用语言编辑、保存和重启，避免扫描结果重新加载偏好时与保存竞争。保持页面简洁，不增加常驻说明文字。

分类按 Apple 应用范围划分：应用标识以 `com.apple.` 开头时归入「APPLE」，无论安装位置，因此 `/Library/Image Capture/.../AirScanLegacyDiscovery.app`、单独安装的 Xcode、Pages 均属于 APPLE。系统路径兜底沿用原规则：解析符号链接后，系统 Applications、Library 与 Cryptexes 中的应用也归入 APPLE。其余应用归入「USER」；`com.appleish.*` 等相似前缀不匹配。该规则用于界面分类，不作为代码签名或可信来源验证。

当前界面使用紧凑页头与原生玻璃操作按钮；列表顶部筛选与搜索共用玻璃工具区，详情使用稳定内容底色。选中名称使用半粗体，详情名称、标识和路径可换行与复制；分类标记使用 APPLE / USER。玻璃工具区在减少透明度或增强对比度时回退为不透明底色与边框。

本轮回归用例覆盖 Apple 标识（含 AirScan、Xcode、Pages）、系统路径兜底、相似标识边界、APPLE / USER 分类互补、筛选选择协调，以及扫描期间禁止保存与重启。已完成源码审阅；命令执行工具初始化时报 `No space left on device`，本轮未运行编译、XCTest 或实际界面预览。上文「验证结果」为此前记录，不代表本轮修改已通过运行验证。
