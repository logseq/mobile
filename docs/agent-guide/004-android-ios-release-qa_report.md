# Android UI/UX、iOS 对照与 Release 差距实测报告

> 后续修复与复测见 [005-android-release-quality_report.md](005-android-release-quality_report.md)。本文保留初测版本的结果；正文、公式与代码展示的旧缺口已在后续修复中处理。

日期：2026-10-21（Asia/Shanghai）  
版本：2.0.2；源码 revision：`5db32d1833ab8229c220ebe4e6c005e32cddeceb`

## 结论

**当前不建议按正式 Release 的完成状态验收。优先解决两件事：Android 富文本会漏显示正文；Release 包的日记滚动仍有明显长帧。** 此外，Android 尚未实现与 iOS 相同的公式排版和代码语法高亮。

这轮实际运行了 Android App、录制原生视频、测量帧统计并采集 Perfetto trace；没有把历史报告或源码中的所有潜在问题重新列一遍。红米没有连接，本报告不能确认那台手机的具体卡顿原因，也不能给出 Android 比 iOS 慢多少倍的结论。

## 测试条件与证据

| 项目 | 本轮使用的条件 |
| --- | --- |
| Android | `logseq_android_36`，API 36.1，arm64，1080×2400，60 Hz，4 vCPU、2 GB guest RAM |
| GPU | 显式 `-gpu host`；SurfaceFlinger 确认 Apple M3 OpenGL ES Translator。最初的软件渲染环境不用于 Release 结论 |
| 构建 | 当前源码重新构建 Profile 与 Release；Release 无 `DEBUGGABLE`，仅用本地 Android debug key 签名以便模拟器安装，并非正式发布签名 |
| 数据 | 内容对照：8 篇日记的现有 E2E fixture；性能复测：100 篇日记 × 8 blocks，含文本、引用、公式、代码，不含 WebView |
| iOS | iPhone 17 Pro / iOS 26 模拟器；同一内容 fixture，使用仓库离线 UI test host，链接生产渲染器和 OCaml core |
| iOS 边界 | test host 绕开登录，平台 presenter 使用测试 executor。因此可比较实际内容渲染，不能据此验收真实登录、系统分享和同步，也不能把 host 的 Settings 断言失败判成正式 App bug |
| 负载限制 | 宿主机存在内存压力及其他进程负载。探索阶段还与编译重叠；正式 Release 滚动复测在构建结束、重启 Android 后执行。所得绝对耗时仍是本模拟器上的观测值 |

[原生 Android demo](android-ios-release-qa/2026-10-21/android-demo.mp4)：`adb shell screenrecord` 原始 MP4，1080×2400，101.07 秒，无音轨，展示快速捕获、侧栏、闪卡与滚动。录制的是 Profile 包，没有加速或剪掉失败操作。

[证据说明与复测脚本](android-ios-release-qa/2026-10-21/README.md)包含原始日志、截图、帧数据与 trace。两端内容截图：[Android](android-ios-release-qa/2026-10-21/android-rich-content.png)、[iOS](android-ios-release-qa/2026-10-21/ios-rich-content.png)。

## 已确认的 UI/UX 差异及功能缺口

| 项目 | Android 实际表现 | iOS 对照 | 判断 |
| --- | --- | --- | --- |
| 引用正文 | `E2E Rich Quote` 只剩竖线，文字未显示 | 同一 fixture 完整显示引用文字 | **P1：正文显示缺失，阻止发布验收** |
| 粗体正文 | 性能 fixture 的 `with **bold text** and ...` 显示成 `with and ...`，`bold text` 消失；Release 中同样出现 | 共享协议中正文存在；iOS 渲染器处理嵌套内容 | **P1：同一渲染协议错误**。此处不是数据库数据丢失的证据 |
| 数学公式 | 显示等宽文本 `E = mc^2`、`x_0 + y_2 = z_2` | 实际排版指数与数学字体 | **尚不支持真正的 TeX 数学排版** |
| 代码块 | 等宽纯色文本；未显示 `swift` 语言标签 | 显示语言标签与语法高亮 | **尚不支持完整语法高亮/语言展示** |
| 界面风格 | Material 侧栏、较平的胶囊控件、Material 底部 sheet | 原生浮动工具栏、材质与不同的排版密度 | 合理的平台差异，不要求逐像素照搬 iOS |

正文缺失的原因已经核对到数据契约：共享层在 [markup.ml](../../shared/src/logseq/core/markup.ml#L68) 中将引用和 emphasis 正文编码为 `children`；Android 的 [appendNode](../../android/app/src/main/kotlin/com/logseq/app/ui/extensions/OutlinerBlockContent.kt#L319) 与引用分支却读取 `node.optString("text")`。应递归渲染节点子内容并保留嵌套样式，不能只补一段 fallback 文案。

公式和代码展示是当前实现明确保留的简化：[AndroidMath / AndroidCodeBlock](../../android/app/src/main/kotlin/com/logseq/app/ui/extensions/OutlinerBlockContent.kt#L635)。这些是本轮有截图和源码双重证据的缺口；没有把未测试的功能都称为“不支持”。

实际完成的操作包括快速捕获提交并在日记中看到新 block、侧栏切换到闪卡、展示 cloze 答案，以及 Release 中打开 Settings。录屏中设置齿轮曾连续点击无响应，但重启并在 Release 包复测后已能打开：[复测截图](android-ios-release-qa/2026-10-21/android-release-settings.png)。因此不将它列为已确认的功能故障。ASCII 输入也已操作；没有足够证据声称中文 IME 或连续输入延迟通过验收。

## 性能：实际测到了什么

### 1. 不含 WebView 的 Release 日记滚动仍卡顿

相同的 100×8 fixture，每轮向下滑动 4 次、向上滑动 4 次，滑动持续 400 ms，每次间隔约 150 ms。每轮前重置 App 的 `dumpsys gfxinfo`，采样期间没有录屏。

| Release 滚动轮次 | 渲染帧 | Janky frames | 掉帧比例 | 帧耗时 P50 / P95 / P99 |
| --- | ---: | ---: | ---: | --- |
| 1 | 130 | 61 | 46.92% | 34 / 150 / 200 ms |
| 2 | 108 | 67 | 62.04% | 48 / 200 / 250 ms |
| 3 | 211 | 59 | 27.96% | 26 / 150 / 200 ms |

三轮合计 449 帧中 187 帧被 Android 标记为 janky，约 **41.6%**。这是系统帧统计的比例，不是平均 FPS；百分位来自系统直方图，存在分桶精度。采样前后截图确认实际滚动了日记，画面没有被系统对话框遮挡。

原始数据：[Release JSON](android-ios-release-qa/2026-10-21/release-100x8/android-performance.json)、[采样前](android-ios-release-qa/2026-10-21/release-100x8/screen-before.png)、[采样后](android-ios-release-qa/2026-10-21/release-100x8/screen-after.png)。

### 2. 长帧集中在主线程布局、重组，并伴随 JIT

另外采集的 12 秒 Release trace 中观察到：

| 片段 | 单次最长耗时 |
| --- | ---: |
| `AndroidOwner:measureAndLayout` | 264.1 ms |
| `Compose:recompose` | 184.2 ms |
| ART 编译 `AndroidComposeView.screenToLocal...` | 657.7 ms |

该 trace 中 App 主线程累计 CPU 时间约 3,919 ms，RenderThread 约 1,019 ms，JIT 线程约 636 ms，`DefaultDispatch` 约 63 ms。**就这次滚动场景而言，应先检查 Android UI 的布局/重组和首次执行成本；现有证据不支持直接把瓶颈归给 OCaml core。** 各 trace 片段可嵌套，不能相加当作一次操作耗时；CPU 时间也不等同于用户等待时间。

含视频的早期 Profile trace 还测到 WebView 绘制最长约 82 ms、lazy prefetch 最长约 136 ms。但 Release 的无 WebView 场景也存在长帧，所以只优化视频嵌入不足以解决问题。

证据：[Release trace](android-ios-release-qa/2026-10-21/release-100x8/scroll.perfetto-trace)、[片段统计](android-ios-release-qa/2026-10-21/release-100x8/trace-summary.csv)、[线程 CPU](android-ios-release-qa/2026-10-21/release-100x8/cpu.csv)。

下一步应在 trace 中继续定位昂贵布局对应的具体行与重复重组范围，检查 lazy item 的稳定 identity/content type、滚动状态读取范围和主线程计算；这是基于本次 trace 的调查方向，不是已验证的修复方案。参照 [Compose 性能实践](https://developer.android.com/develop/ui/compose/performance/bestpractices)。对首次触控的 JIT 停顿，应实测关键交互的 [Baseline Profiles](https://developer.android.com/topic/performance/baselineprofiles/overview) 效果，不能用它掩盖持续的布局成本。

### 3. 没有证据支持的性能结论

- Release 的静置 10 秒产生 **0 个 App 新帧**，没有复现空闲页面持续重绘。此时 gfxinfo 的 `4950 ms` 百分位是无帧样本占位值，不是 4.95 秒卡顿。
- 三轮滚动后的 App PSS 约 126–130 MiB，没有单调增长；样本不足以判断内存泄漏，也没有证明 App 内存占用是红米卡顿根因。
- 冷启动样本波动很大，且存在系统刚启动的负载。本轮不将它压成一个“正常冷启动耗时”或两端速度排名。`first_ui_rendered` 在 `doOnPreDraw` 上报，`journals_ui_ready` 在行布局回调上报，都不等于用户已看到并可操作的完整页面。
- 曾出现 **Process system** ANR，随后手势被系统弹窗拦截，产生“滚动但 App 渲染 0 帧”的无效样本。这些样本已单独保存并排除；不能把系统 ANR 写成 Logseq ANR，也不能把 0 帧解释为流畅。

因此，报告支持“当前模拟器上的 Release 滚动确实有长帧”，尚不能确认红米上具体的 CPU、GPU、内存、IME 或同步占用比例。

## 距离正式 Release 还差什么

按本轮证据，建议按以下顺序收敛，而不是先增加更多功能：

| 优先级 | 要完成的事 | 可签字的验收结果 |
| --- | --- | --- |
| P1 | 修复引用、粗体等嵌套富文本的正文显示 | 同一 fixture 两端正文完整；覆盖嵌套样式与引用，不以控件存在代替内容正确 |
| P1 | 降低日记滚动的布局、重组和 JIT 长帧 | 用同一 100×8 graph 在稳定模拟器及用户红米上重复 Release 测量，记录帧分布与 trace；先建立明确预算。可将持续滚动 jank <5%、P95 <32 ms 作为讨论起点，属于建议目标，并非已达成指标 |
| P2 | 补公式排版与代码展示 | 公式、上下标、代码语言与高亮的视觉结果达到明确的产品验收标准 |
| 发布前证据 | 完成真实 App 的关键闭环 | 在真实登录状态下验证编辑落盘/重启保留、双端同步和附件往返，并补中文 IME；本轮离线渲染对照不能替代这些验收 |
| 发布工程 | 让自动化和发布包可复验 | 修正 fixture 活动目录及 Maestro 截图路径问题；帧采样拒绝弹窗/未滚动/0 帧的无效样本；验证正式签名包。当前 Gradle Release 产物为 unsigned APK，本轮签名只用于本机测试 |

本轮已有两类测试工具问题影响证据可靠性：Android 将图谱迁移到 `UI_Regression-uiregression` 后，往旧的 `uiregression` 目录写 fixture 不会改变活动图谱；Maestro 2.8 拒绝指向本轮输出目录之外的绝对截图路径。相关失败已保留，不能计为产品回归，也不能计为测试通过。

本次未改产品代码，未运行 `swift test`。Android Profile 与 Release 均构建成功；iOS 渲染库 build-only 检查成功。原 iOS App 的 Documents 与偏好设置已恢复，内容对照使用单独的 test host。
