# 方寸 InchSpace

跨平台桌面 UI 应用，目标支持 Windows、macOS、Linux。

## Tech Stack

- Tauri 2
- React
- TypeScript
- Vite
- Tailwind CSS

## Run Scripts

```bash
npm install
npm run icons
npm run desktop:dev
```

常用脚本：

```bash
npm run dev            # 只启动前端 Vite
npm run desktop:dev    # 启动桌面开发环境
npm run icons          # 从 SVG 主图标生成桌面图标资产
npm run desktop:check  # 前端构建 + Rust 检查
npm run desktop:build  # 构建桌面安装包
```

## Project Notes

项目约束写在 `AGENTS.md`：跨平台目标、iOS 26 风格方向、亮暗色主题、菜单栏平台习惯和命名规则。
