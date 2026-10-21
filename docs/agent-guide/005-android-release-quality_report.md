# Android 修复与性能复测报告

日期：2026-10-21 初测，2026-10-22 续测。状态：修复、优化与模拟器复测已完成；正式 Release 验收仍有下述缺口。  
对应[执行计划](005-android-release-quality.md)及[初测 Android/iOS 对照](004-android-ios-release-qa_report.md)。证据沿用本轮 `2026-10-21` 目录。

## 结论

**正文漏显已修复，块公式排版和代码展示已补齐；日记更新管线移除了重复 JSON 处理及不断积累的历史节点元数据。最终固定包在 API33 的三轮复核达到本轮建议预算，仍需真机与真实使用闭环完成正式 Release 验收。** 红米未接入，不能声称其卡顿已经解决。

本轮性能改动只涉及 Android Kotlin；没有修改 iOS 布局、样式或其依赖版本，也没有增加全局浮层、调度器或新的后台队列。此前收益不确定的菜单浮层和 app Baseline Profile 实验均已撤下。

## Android 与 iOS 的已测差异及修复

| 初测 Android 问题 | 本轮结果 | iOS 对照及验证边界 |
| --- | --- | --- |
| 粗体、引用正文消失 | 递归读取共享 markup 的 `children`；保留嵌套格式、链接、Unicode 与完成状态 | 补齐原先 iOS 可显示而 Android 漏显的正文；8项真实渲染/点击/编辑动作测试通过 |
| 公式只是等宽 TeX 文本 | 离线排版上下标、分式和根号；非法表达式可读回退，支持深色与字体缩放 | 块公式功能缺口已补齐；未宣称所有 TeX 命令与行内排版完全等价 |
| 代码无语言标签和高亮 | 显示语言标签和彩色 spans，保留空白、支持横向滚动；浅/深色实际 token 对比度达到4.5:1 | Swift 已实测；未知语言保留可读原文，不宣称所有语言均完成验收 |
| Material 与 iOS 材质/工具栏不同 | 保留 Android 的平台风格 | 合理的平台差异，未以性能优化改变 iOS 样式 |

公式/代码合计8项仪器测试覆盖实际布局、像素、文本 spans、更新及主题切换。公式与高亮计算在有限并发的工作线程执行，缓存有容量上限，没有新增 WebView。依赖和字体许可通知随 Android assets 收录。

最终包[截图](android-release-quality/2026-10-21/android-final.png)与[原生录屏](android-release-quality/2026-10-21/android-final-demo.mp4)见证据目录；录屏为 Android `screenrecord` 原始输出，24.83秒、1080×2400、无音频。iOS 内容对照沿用[初测截图](android-ios-release-qa/2026-10-21/ios-rich-content.png)，本轮没有修改其渲染器。

## 实际定位到的性能问题

Simpleperf 的真实滚动调用栈中，patch 处理约占该次 App CPU 样本的3.53%，不是全部卡顿来源。进一步录下50批 native 日记窗口 patch（8,774,118字节），包含22,609次创建节点、1,522次整棵子树移除，没有逐个节点删除操作。

旧过滤器只在逐个删除时清理节点类型表，整棵子树移除后仍保留历史节点记录，并在每批更新时复制它们；同时执行 JSONObject 解析、重新序列化，再由 LUI 再次解析。

修复直接复用 backend 的现有节点信息及已解析 batch，只保留仍存活的忽略属性。布局与样式规则保持原样，性能部分产品代码净减少十余行。LUI 仅增加节点类型查询，并公开原有的 decoded-batch 入口：[提交 `1edf1269`](https://github.com/logseq/lui/commit/1edf12691bcd78ee65b52355d5c2a35f4194524c)，已在 `logseq.opam` 固定。同一源码树已在保留远端提交后推入 LUI `main`：[提交 `e33a1521`](https://github.com/logseq/lui/commit/e33a152120dff61a65217130d9479f0e974fde47)；App 保持已测试的固定 revision。该提交不含 Swift、OCaml 或布局代码变更；Apple package 继续使用原 revision。

### Release 管线 CPU 对照

在非 debuggable Release 包中，直接回放同一份真实 native patch 流；每组6次预热、12次计时，使用 `Debug.threadCpuTimeNanos()`，中位数按原始样本计算。新旧 core SHA 与 patch 流 SHA 均相同。此测试不包含 Compose 绘制，不能换算成 FPS 或整页提速比例。

| 顺序 | 实现 | 50批处理 CPU 中位数 |
| --- | --- | ---: |
| A | 原管线 | 492.38 ms |
| B | 新管线 | 348.09 ms |
| A 反向复测 | 原管线 | 1007.37 ms |

首组对照减少约29%；反向复测原版仍更高，但也显示了明显的宿主/ART/GC波动，不将这个百分比作为跨设备保证。原始样本、共同输入与校验值：[汇总](android-release-quality/2026-10-21/patch-pipeline/summary.json)、[原版](android-release-quality/2026-10-21/patch-pipeline/release-before.json)、[新版](android-release-quality/2026-10-21/patch-pipeline/release-after.json)、[反向复测](android-release-quality/2026-10-21/patch-pipeline/release-before-2.json)。

### 相同内容的 Release 实际滚动

AVD `logseq_release_qa_33`：API33 Google APIs arm64、1080×2400、60Hz、4核、2GiB、host GPU、headless，关闭网络。两端都已修复富文本和公式/代码，使用同一100篇日记×8blocks的数据库，不含 WebView；Kotlin差异只在 patch 管线的两个文件。原生 core/JNI/graphics 库逐字节相同。均重置 ART 状态、安装各自依赖提供的 profile，再编译 speed-profile；没有全量 speed 编译或候选 app profile。

每轮向下4次、向上4次，各400ms。工具检查 App 前台、无系统弹窗、非零帧与真实列表移动。采样与本任务构建、截图及录屏分开；共享 Mac 上的其他任务仍可能影响结果。

| 轮次 | 原管线 janky/总帧 | 原管线 P95 / P99 | 新管线 janky/总帧 | 新管线 P95 / P99 |
| --- | ---: | ---: | ---: | ---: |
| 1 | 16/326（4.91%） | 32 / 48 ms | 14/332（4.22%） | 28 / 53 ms |
| 2 | 23/252（9.13%） | 38 / 150 ms | 16/300（5.33%） | 40 / 150 ms |
| 3 | 54/165（32.73%） | 150 / 300 ms | 29/317（9.15%） | 53 / 89 ms |
| 合计 | **93/743（12.52%）** | — | **59/949（6.22%）** | — |

这是此组样本的系统 janky-frame 比例，不是平均 FPS。新管线后两轮仍未达到计划建议的 jank<5%、P95<32ms，P99仍达150ms；不能据此签字“卡顿已解决”。[before JSON](android-release-quality/2026-10-21/patch-ui-before/android-performance.json)、[after JSON](android-release-quality/2026-10-21/patch-ui-after/android-performance.json)、[相同原生库校验](android-release-quality/2026-10-21/patch-ui-after/controlled-apks.json)。

最终固定包（build revision `2ad7d02e`，包含本轮 Android 工作区改动）重建了当前 native core，并单独复核：

| 最终包轮次 | janky/总帧 | P95 / P99 |
| --- | ---: | ---: |
| 1 | 11/324（3.40%） | 26 / 73 ms |
| 2 | 7/336（2.08%） | 23 / 30 ms |
| 3 | 9/333（2.70%） | 21 / 27 ms |
| 合计 | **27/993（2.72%）** | — |

这三轮均满足本轮建议的 jank<5%、P95<32ms。首次 P99 仍达73ms，样本也不足以代替真机或长时间验收。最终包 core 与控制组不同，**不能把12.52%到2.72%宣传为管线修复的提速幅度**；管线对照仍以前面的相同 core 数据为准。[最终包 JSON](android-release-quality/2026-10-21/final-integration-performance/android-performance.json)、[APK校验及版本](android-release-quality/2026-10-21/final-integration-performance/apk.json)。

## 验证结果

- Android app JVM 单元测试 **54项通过**，包含9项真实 backend 过滤契约测试；同样9项在原实现上先通过，确认重构保留行为。
- 富文本8项、公式/代码8项及10,000行大列表导航1项，合计 **17项仪器测试**，在最终固定 APK 上全部再次通过（[日志](android-release-quality/2026-10-21/patch-pipeline/final-frozen-ui.log)）。大列表检查可见行有界、滚到9990、返回位置、搜索焦点及输入栏。
- 测量有效性8项、图谱定位/种子2项和既有 E2E runner shell suite通过。已修正写入过期图谱目录的问题，拒绝弹窗、错误前台、未移动和0帧的无效样本。
- 当前 core 的 Debug、AndroidTest、Release 构建已成功；曾有一次增量 APK 打包失败，重试及完整构建 gate 随后成功，失败日志保留，没有计为产品测试失败或成功产物。

详细 APK/core 校验值、构建及测试日志见[证据说明](android-release-quality/2026-10-21/README.md)。CPU采样遵循 [Android Simpleperf 文档](https://android.googlesource.com/platform/system/extras/+/master/simpleperf/doc/android_application_profiling.md)。API36 的系统/ART启动异常及无效样本单独保留，未与 API33 合并计算优化幅度。

## 距离正式 Release 仍缺什么

1. **红米性能验收**：用同一 graph 验证首次与持续滚动、输入延迟、长时间使用和恢复。本次模拟器预算通过，但仍有首次长帧；不能把剩余问题都归因于宿主，更不能保证红米的改善幅度。
2. **真实使用闭环**：真实登录下的编辑落盘/重启保留、双端同步、附件往返，以及中文 IME。本轮离线 fixture 使用虚构 token 与关闭的 localhost 地址，不替代这些验收。
3. **发布工程**：正式签名及分发包验证。本机签名只用于测试，不是生产发布签名。

本轮完成的范围是确证显示缺口、追踪并减少真实滚动更新中的重复工作，以及可复验的前后测试。以上仍未验证或未达标的环节继续作为正式 Release 差距保留。
