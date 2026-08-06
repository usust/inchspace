# InchSpace 图标调研

调研日期：2026-08-04

## 参考来源

- Apple Human Interface Guidelines：[Icons](https://developer.apple.com/design/human-interface-guidelines/icons)、[App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)、[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)、[Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)。界面图标应优先使用熟悉、可缩放且语义一致的 SF Symbols；工具栏和侧栏应让系统控件负责间距、尺寸和状态。
- Apple：[SF Symbols](https://developer.apple.com/sf-symbols/) 与 [Design Resources](https://developer.apple.com/design/resources/)。SF Symbols 与系统字体在重量、基线和动态尺寸上协同工作。
- WWDC25：[Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/)、[Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)。Liquid Glass 主要属于导航和控件层；内容层不应手工堆叠多重玻璃、描边和阴影。
- WWDC25：[Say hello to the new look of app icons](https://developer.apple.com/videos/play/wwdc2025/220/) 与 [Create icons with Icon Composer](https://developer.apple.com/videos/play/wwdc2025/361/)，以及 Xcode 文档 [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/Xcode/creating-your-app-icon-using-icon-composer)。App Icon 应从少量可编辑图层开始，把动态玻璃效果和外形适配交给 Icon Composer。

## Apple 优秀案例

- Finder：侧栏采用熟悉的单色语义符号；选中态由列表背景与强调色表达，而不是放大图标。文件夹轮廓在小尺寸仍清楚。
- System Settings：齿轮等入口保持稳定笔画和圆润外形；高密度导航中图标服从文本行高。
- Preview：以少量主辅元素建立明确层级，透视服务于“预览/标记”语义。
- Photos：App Icon 可以保留品牌色，但通过简化、重叠和透明度建立层次；普通界面操作仍保持克制。
- Home：减少源图层并使用圆润的大形状，把材质变化留给系统渲染。
- Calendar、Dictionary：窄笔画与小型文字区域需要保守的高光和稳定对比度，尤其要验证深色外观。

## 第三方 macOS 26 案例

- [Craft OS 26](https://www.craft.do/os26)：采用更轻、更明亮的系统方向，同时让内容保持视觉中心。可借鉴其“品牌存在于内容而非每个控件”的克制方式。
- [Bear 的 macOS Tahoe 更新](https://blog.bear.app/2025/09/bear-is-now-com-paw-tible-with-new-oses-with-adapted-glassy-look/)：工具栏与侧栏适配系统材质，但仍保持原有简洁识别；App Icon 使用轻微渐变和高光，不把同样的彩色处理复制到所有界面图标。
- [CleanShot X 更新记录](https://cleanshot.com/changelog)：先适配 Tahoe 与 App Icon，再逐步更新界面，体现品牌图标和功能图标应分开维护。

这些案例公开资料未给出可复用的精确 pt 数值，因此本项目不臆造数值；以 SwiftUI 原生 `Label`、`Button`、`List` 和语义字体的实测结果为准。

## 尺寸与状态规律

- 侧栏、菜单、工具栏图标不设固定宽高，继承系统控件和文字环境；通常使用系统默认或 `.imageScale(.small/.medium)`。
- 卡片中的图标随 `.headline` 排版，不使用 40 pt 彩色底板；详情页属于展示区域，可使用语义化 `.largeTitle`，但不写死像素。
- 选中态由 `List(selection:)` 和系统 tint 呈现；未选中态保持单色。状态变化不改变图标尺寸。
- 普通操作采用 `.monochrome`；确有前后层级的展示图标采用 `.hierarchical`；只在错误、危险和成功状态使用对应语义色。
- 1x/2x、窄/宽窗口、提高对比度和深浅外观均依赖矢量 SF Symbols 与语义颜色，避免位图缩放和硬编码 RGB。

## 本项目策略

1. 所有界面入口均使用 SF Symbols，不新增自定义功能图标。
2. 侧栏继续使用原生 `Label` 与 `.sidebar`；搜索继续使用 `.searchable(..., placement: .toolbar)`。
3. 工具卡片删除固定 40×40 图标底板及悬停缩放，使用 `.headline` + `.imageScale(.medium)`；相邻标题承担可访问名称。
4. 详情展示使用语义 `.largeTitle` 和 hierarchical 渲染，不固定 72×72 frame。
5. App Icon 独立维护：传统 AppIcon 集合保证当前工程直接可运行；`IconSources` 提供 4 层 SVG，供 Icon Composer 生成 Default/Dark/Mono。

## 不适合本项目的设计

- 在侧栏、工具栏或卡片使用 24/32/48/64 pt 固定图标。
- 为每个功能加彩色圆角方块、渐变或玻璃底板。
- 以 Emoji、缩小的 App Icon 或低清 PNG 充当功能图标。
- 在内容卡片中叠加多层透明材质、强描边、霓虹或厚重阴影来模仿 Liquid Glass。
- 让选中或悬停状态缩放整个图标/卡片，造成视觉尺寸跳变。
