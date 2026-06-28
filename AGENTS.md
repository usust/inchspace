# InchSpace Project Notes

本项目是跨平台桌面 UI 应用，中文名“方寸”，英文名 InchSpace。

## Product Direction

- 目标平台：Windows、macOS、Linux。
- 当前技术栈：Tauri 2、React、TypeScript、Vite、Tailwind CSS。
- 第一原则：优先做真实可运行的桌面应用界面，不做营销落地页。
- UI 风格：偏 iOS 26 的通透、轻量、层次清晰风格；避免过度装饰。
- 多平台一致性：核心页面布局、交互和视觉语言保持一致。
- 原生差异：菜单栏、窗口行为和系统级交互尽量贴近各平台习惯。

## Visual System

- 支持亮色、暗色，并为未来更多色彩方案保留 CSS 变量入口。
- 主题变量集中在 `src/App.css` 的 `:root`、`[data-theme]`、`[data-scheme]`。
- 卡片圆角保持 8px，除应用图标和系统图标外不使用过大的圆角。
- 工具按钮优先使用 lucide-react 图标，并提供 `title` 提示。
- 不使用脚手架默认 logo、默认欢迎页或无产品含义的占位图。

## Naming

- 中文展示名：方寸。
- 英文展示名：InchSpace。
- 组合展示：方寸 InchSpace。
- Bundle identifier：`com.inchspace.desktop`。

## Scripts

- `npm run desktop:dev`：启动 Tauri 桌面开发环境。
- `npm run dev`：只启动 Vite 前端预览。
- `npm run icons`：从 `src/assets/inchspace-icon.svg` 生成 Tauri 图标资产。
- `npm run desktop:build`：构建桌面应用安装包。
- `npm run desktop:check`：前端构建加 Rust 检查。
