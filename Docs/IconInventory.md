# InchSpace 图标清单

渲染约定：侧栏和普通操作默认 monochrome；展示性层叠图标可 hierarchical。全部使用 SF Symbols，因而无需自定义界面资源。

| 功能 | 位置 | 语义 | 推荐 SF Symbol | 备选 | 自定义 | 渲染 | 选中 / 未选中 | 无障碍标签 | 源文件 |
|---|---|---|---|---|---|---|---|---|---|
| 工作台 | 侧栏、Hero | 工具总览/模块 | `square.grid.2x2`；Hero `square.3.layers.3d` | `rectangle.grid.2x2` | 否 | 单色；Hero 分层 | 系统列表 tint / primary | 工作台；Hero 装饰隐藏 | `SidebarDestination.swift`, `WorkspaceView.swift` |
| 收藏 | 侧栏 | 已收藏项目 | `star` | `star.fill` | 否 | 单色 | 系统 tint / primary | 收藏 | `SidebarDestination.swift` |
| 最近使用 | 侧栏 | 时间历史 | `clock` | `clock.arrow.circlepath` | 否 | 单色 | 系统 tint / primary | 最近使用 | `SidebarDestination.swift` |
| 文本处理 | 侧栏、卡片 | 字符与排版 | `textformat` | `character.cursor.ibeam` | 否 | 单色 | 系统 tint / accent | 文本处理/文本清理 | `SidebarDestination.swift`, `WorkspaceView.swift` |
| 图片工具 | 侧栏、卡片 | 图片资源 | `photo.on.rectangle` | `photo` | 否 | 单色 | 系统 tint / accent | 图片工具/图片压缩 | 同上 |
| 格式转换 | 侧栏 | 双向转换 | `arrow.left.arrow.right` | `arrow.triangle.2.circlepath` | 否 | 单色 | 系统 tint / primary | 格式转换 | `SidebarDestination.swift` |
| 开发工具 | 侧栏 | 代码工具 | `chevron.left.forwardslash.chevron.right` | `terminal` | 否 | 单色 | 系统 tint / primary | 开发工具 | `SidebarDestination.swift` |
| JSON 格式化 | 卡片/详情 | 结构化数据 | `curlybraces` | `doc.plaintext` | 否 | 单色/详情分层 | accent / accent | JSON 格式化 | `SidebarDestination.swift`, `WorkspaceView.swift` |
| 颜色取样 | 卡片/详情 | 取色 | `eyedropper` | `paintpalette` | 否 | 单色/详情分层 | accent / accent | 颜色取样 | 同上 |
| 单位换算 | 卡片/详情 | 测量 | `ruler` | `lines.measurement.horizontal` | 否 | 单色/详情分层 | accent / accent | 单位换算 | 同上 |
| 时间戳转换 | 卡片/详情 | 时间转换 | `clock.arrow.circlepath` | `calendar.badge.clock` | 否 | 单色/详情分层 | accent / accent | 时间戳转换 | 同上 |
| URL 编解码 | 卡片/详情 | 链接 | `link` | `network` | 否 | 单色/详情分层 | accent / accent | URL 编解码 | 同上 |
| 大小写转换 | 卡片/详情 | 字符编辑 | `character.cursor.ibeam` | `textformat` | 否 | 单色/详情分层 | accent / accent | 大小写转换 | 同上 |
| 快速开始 | Hero 按钮 | 继续/进入 | `arrow.right` | `play` | 否 | 单色，由 Button 决定 | 系统按钮状态 | 快速开始 | `WorkspaceView.swift` |
| 进入详情 | 卡片尾部 | Disclosure | `chevron.right` | `arrow.right` | 否 | 单色 tertiary | 不变 | 装饰隐藏（链接标题已命名） | `WorkspaceView.swift` |
| 就绪状态 | 详情状态 | 成功/可用 | `checkmark.circle.fill` | `checkmark.circle` | 否 | 单色 secondary | 不适用 | 界面入口已就绪… | `WorkspaceView.swift` |
| App Icon | Dock/Finder | InchSpace 品牌与模块工具空间 | 不适用 | 不适用 | 是 | 全彩分层 | Default/Dark/Mono 由 Icon Composer | InchSpace | `Assets.xcassets/AppIcon.appiconset`, `IconSources` |

## SF Symbols 映射结论

现有功能都能由系统符号准确表达。品牌图标是唯一需要自定义的图标；它不会复用于侧栏、卡片或按钮。
