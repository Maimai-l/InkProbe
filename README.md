# InkProbe

InkProbe 是一个 iPadOS 原生测试应用，用于采集 PencilKit 像素橡皮的参照数据。在同一次 Apple Pencil 笔划中，PencilKit 按原生逻辑绘制和擦除，同时一个旁路记录器完整记录原始触摸输入。导出的数据供 JavaScript 端回放并逐像素比较，本应用只负责采集与导出。

- 应用名称：InkProbe（`project.yml` 中的 `APP_DISPLAY_NAME`）
- Bundle Identifier：`dev.local.inkprobe`（`project.yml` 中的 `PRODUCT_BUNDLE_IDENTIFIER`）
- 最低系统版本：iPadOS 15.0，仅 iPad，锁定横屏，强制浅色模式
- 无第三方依赖，只使用 UIKit、PencilKit、Foundation、UniformTypeIdentifiers

## 使用方法

1. 启动后自动创建一个未命名会话，视口位于画布中心，缩放比例为 1.0。
2. 用 Apple Pencil 书写或擦除。工具由系统 `PKToolPicker` 提供，撤销和重做使用工具选择器自带的按钮。手指用于滚动和缩放。
3. 顶部工具栏：
   - **仅 Pencil 绘图**：打开时 `drawingPolicy = .pencilOnly`；关闭时为 `.anyInput`，手指也会绘图，并同时记录 `direct` 类型的触摸。
   - **逐步快照**：每个序列结束后保存一次中间快照，默认打开。
   - **记录输入**：关闭时停用 TouchLogger（识别器 `isEnabled = false`），用于比较启用和停用记录器时的书写手感。关闭时正在进行的序列以 `endPhase = "loggerDisabled"` 结束。
   - **新会话**：清空画布和撤销栈，视口复位，重置时钟和计数器，可输入会话名称。
   - **结束并保存**：写入 `Documents/sessions/<yyyyMMdd-HHmmss>_<name>/`。保存期间显示进度并禁止绘制；保存完成后自动开始一个新的未命名会话。
   - **会话列表**：查看已保存会话，点选后可导出 zip 或删除，也可左滑删除。
   - 右侧状态文本：会话名称、样本数、序列数、当前笔划数、缩放比例。
4. 会话文件夹同时可以在“文件”应用的“我的 iPad → InkProbe”中看到。

## 数据格式

数据格式以需求文档第 5 节为准，这里只说明实现上需要注意的细节。

- 目录结构：

  ```
  Documents/sessions/<yyyyMMdd-HHmmss>_<name>/
    meta.json                 最后写入；缺少此文件说明保存未完成
    input.json
    final/
      drawing.drawing
      render@1x.png
      render@2x.png
      render@<screenScale>x.png   screenScale 与 1、2 重复时不生成
      render-transparent@2x.png
      strokes.json
    steps/
      0001/                   序列编号，四位补零
        drawing.drawing
        render@2x.png
        strokes.json
        step.json
  ```

- 所有 JSON 由应用内的 JSON 写入器生成，而不是 `JSONEncoder`：可选字段显式写为 `null`，`NaN` 和 `Infinity` 写为 `null`，Double 使用 Swift 的最短往返表示输出，不做四舍五入；整数值的 Double 写成不带小数点的整数。只含标量的对象（例如一个样本、一个路径点）写在同一行。
- 时间：`t` 与 `tReceived` 都是相对 `meta.json` 中 `clockOrigin` 的秒数。`clockOrigin` 是会话第一条样本的 `UITouch.timestamp`；会话中没有任何样本时，退化为会话开始时的系统时间（同一时基）。在第一条样本之前发生的事件，其 `t` 为负数。
- `tReceived` 是应用收到估计属性更新时的系统时间。更新通常在 `touchesEnded` 之后到达，记录器按 `estimationUpdateIndex` 匹配所属序列。
- `touchId` 只分配给被记录的触摸（Pencil，以及 `.anyInput` 模式下的手指）。
- `endPhase` 取值：`ended`、`cancelled`；记录被中断时为 `loggerDisabled`、`sessionSaved` 或 `sessionReset`。
- `tool.category` 除 `inking`、`eraser` 外，还可能是 `lasso` 或 `other`。
- 指纹：`fragmentHash` 中 `pathHash` 的 8 字节按大端（即十六进制字符串的书写顺序）加入。JS 端不需要重新计算指纹，直接比较字符串即可。
- `mask` 与 `points` 均为 PencilKit 返回的原始值，未应用 `transform`。未经变换的笔划 `transform` 为单位矩阵，此时两者即为 drawing 坐标。
- 逐步快照：序列结束后，在紧接着的 `canvasViewDrawingDidChange(_:)` 中保存；如果 PencilKit 在同一次事件分发中先于记录器提交了变化，也按 `drawingChanged = true` 处理；500 ms 内没有变化回调时保存并标记 `drawingChanged = false`。下一个序列开始时，若上一个快照仍在等待，立即保存（`drawingChanged = false`），避免新序列的改动混入。
- 各步位图使用最终 drawing 的 `renderRect`；各步 `strokes.json` 中的 `renderRect` 与位图一致。最终 drawing 为空时，改用各步 `renderRect` 的并集，并在 `meta.json` 的 `warnings` 中说明。
- 单张位图超过 1.5 亿像素时跳过，并写入 `meta.json` 的 `warnings`。
- `meta.json` 在需求文档的字段之外，还包含 `canvas.initialZoom`、`canvas.initialVisibleSize`、`counts.steps` 和 `warnings`。

## 本地构建

1. `brew install xcodegen`
2. 在仓库根目录执行 `xcodegen generate`
3. 打开 `InkProbe.xcodeproj`，在 Signing & Capabilities 中选择自己的 Team（免费 Apple ID 的 Personal Team 即可）
4. 连接 iPad，选择设备后运行。免费 Team 签名的应用有效期为 7 天，到期后需重新运行

`InkProbe.xcodeproj` 和 `InkProbe/Resources/Info.plist` 由 XcodeGen 根据 `project.yml` 生成，不提交到仓库。

### 本地打包 IPA（用于 TrollStore）

```sh
brew install xcodegen ldid-procursus
xcodegen generate
xcodebuild -project InkProbe.xcodeproj -scheme InkProbe -sdk iphoneos -configuration Release \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
ldid -S build/Build/Products/Release-iphoneos/InkProbe.app/InkProbe
rm -rf Payload InkProbe.ipa && mkdir Payload
cp -R build/Build/Products/Release-iphoneos/InkProbe.app Payload/
zip -qry InkProbe.ipa Payload
```

## GitHub Actions

`.github/workflows/build.yml` 在 `push`、`pull_request` 和手动触发时运行于 `macos-26`：生成工程、以 Release 配置构建（不签名）、用 `ldid -S` 伪签名、打包为 `InkProbe.ipa` 并作为 artifact 上传。构建日志不经过过滤，保留完整的编译错误。

## 安装到 iPad（TrollStore）

1. 在 GitHub Actions 的运行记录中下载 artifact，解压得到 `InkProbe.ipa`。
2. 通过 AirDrop 或“文件”应用把 IPA 传到 iPad。
3. 在 TrollStore 中选择该 IPA 安装。更新版本时直接覆盖安装，Documents 中的会话数据会保留。

TrollStore 安装的应用不受 7 天有效期限制。提示：iOS 重建图标缓存后，TrollStore 安装的应用可能无法启动，此时在已安装的持久化助手（Persistence Helper）中重新注册即可，这是 TrollStore 本身的机制。

## 源码结构

```
InkProbe/
  App/        AppDelegate.swift, SceneDelegate.swift
  Canvas/     CanvasViewController.swift  画布、工具选择器、视口与快照逻辑
              TouchLogger.swift           旁路触摸记录器（UIGestureRecognizer 子类）
              ToolState.swift             工具读取与颜色转换
              RecordingSession.swift      会话的内存数据
  Export/     SessionStore.swift          会话目录、列表、删除
              DrawingExporter.swift       位图渲染与导出步骤
              BezierPathSVG.swift         CGPath → SVG path data
              Zipper.swift                NSFileCoordinator 打包 zip
  Model/      JSON.swift                  JSON 写入器与 FNV-1a
              InputModels.swift           input.json 的数据模型
              StrokeModels.swift          strokes.json、指纹与 step diff
  UI/         ToolbarView.swift, SessionListViewController.swift
  Resources/  Assets.xcassets（Info.plist 由 XcodeGen 生成）
```
