# InchSpace App Icon 源文件

`AppIconMaster.png` 是通过内置图像生成工具制作并接入传统 `AppIcon.appiconset` 的 1024×1024 母版。生成提示的核心约束是：三层圆润模块组成工具工作台，前层带克制的标尺刻度；蓝靛色、青色高光、2–4 层、正面构图、充足留白、16 px 可辨；无文字、无 Apple/第三方标志、无预制最终圆角蒙版、无厚重玻璃反射。

四个编号 SVG 是供 Icon Composer 使用的可编辑、无版权依赖分层版本，Z 轴顺序如下：

1. `01-background.svg`：深蓝底色。建议不加玻璃；Default 100% opacity，Dark 降低亮度约 8%，Mono 使用系统单色底。
2. `02-back-tile.svg`：后层靛色模块。建议 95–100% opacity，极轻阴影，模糊 0。
3. `03-middle-tile.svg`：中层浅色模块。建议 90–96% opacity，使用轻微玻璃材质；Dark 模式降低白色亮度，避免刺眼。
4. `04-front-tile-detail.svg`：主层和刻度。建议主层 96–100% opacity、轻微高光；刻度保持高对比，不增加模糊。

## Icon Composer 操作

1. 在 Apple Design Resources 下载当前 App Icon 模板，并在 Icon Composer 新建项目。
2. 按编号依次拖入 SVG；确认 1024×1024 画布、各层居中，主体边缘保留充足 safe area。
3. 为三个 tile 分别启用轻量材质和很小的 Z 轴间距。阴影与高光交给 Icon Composer，不要在源层叠加厚重效果。
4. 在 Default、Dark、Mono 三种外观下分别检查；再预览 Full Color、Tinted、Clear、Light、Dark。
5. 特别在 16、32、128 px 预览刻度：若变糊，减少刻度而不是加粗所有层。开启提高对比度时确认浅色中层与背景边界仍清晰。
6. 保存真实 `.icon` 文件后拖入 Xcode 工程，在 Target → General / App Icons 中选择它。确认无误前保留现有 `AppIcon.appiconset` 作为直接构建资源。

自动化环境不创建伪 `.icon` 文件；Default/Dark/Mono 的最终材质参数和系统实时预览需在 Icon Composer GUI 中完成。
