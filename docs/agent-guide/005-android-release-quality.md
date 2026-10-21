# Android Release Quality Implementation Plan

Goal: 修复已实测的 Android 正文显示缺失、补齐公式与代码展示，并用可重复的 Release 测量降低滚动成本。

Hard constraints (user, 2026-10-21): performance work must preserve iOS layout and styling, and must not add unnecessary complexity. Keep changes local to Android; reject mechanisms without demonstrated benefit.

Architecture: 保持共享 OCaml 模型及现有 Kotlin/Compose 宿主。
首先修正 Android 对共享 markup 树的消费，再将昂贵的展示计算移出重复的布局路径。
性能改动以实际 trace 和行为回归为依据，保留编辑、导航、虚拟化与拖放语义。

Tech Stack: Kotlin、Jetpack Compose、Android instrumentation/JUnit、OCaml/Dune、Maestro、Perfetto。

Related: Builds on [004-android-ios-release-qa_report.md](004-android-ios-release-qa_report.md).

## Problem statement

工作目录为 `/Users/tiensonqin/Codes/projects/logseq-chat`。
计划起点源码 revision 为 `5db32d18`。
保留已有报告及其他任务的工作，不修改无关文件。

共享协议将 emphasis 和 quote 的正文放入 `children`，Android 却读取 `text`，因此正文漏显。
数学块目前只是等宽文本，代码块没有语言标记与高亮。
报告中的无 WebView Release 滚动样本有 27.96%–62.04% janky frames，trace 中布局、重组与 JIT 存在长片段。
这些模拟器数据需要在同一环境重新建立基线，不能直接解释红米真机情况。

## Testing Plan

每个阶段均先写齐该阶段的行为回归与边界测试，确认因现有行为而失败，再开始该阶段实现。
不以检查测试标签、类型或文件包含某个字符串替代真正的渲染与交互验证。

| 阶段 | 验证行为 | 测试与证据 |
| --- | --- | --- |
| 1 正文 | 嵌套粗体/斜体/删除线、引用中的链接与页面引用完整显示，链接仍可点击，完成状态保留样式 | 新增 Android rich-content instrumentation tests，经真实 LUI wire/store/extension 渲染，不 mock renderer |
| 2 展示 | 公式上下标、分式与非法表达式；代码语言标签、真实彩色 spans、未知语言、空内容和深色主题 | 先增加仪器测试与必要的纯渲染工具单测，再接入离线公式与高亮实现；截图复核 |
| 3 性能 | 大图谱滚动后的正文、标题、编辑焦点、返回位置正确；虚拟化仍有界，旧行状态不串到新行 | 复用并扩展 AndroidOutlinerParityTest；针对被 trace 确认的失效行为补回归 |
| 4 测量 | 正确定位活动图谱，拒绝 ANR/错误前台/未滚动样本；同配置的前后帧分布可比较 | Python 测量工具测试、Release 三轮滚动、Perfetto 与原生截图/录屏 |

NOTE: I will write *all* tests before I add any implementation behavior.

## Task checklist

- [x] Read the planning and TDD guidelines, report, root instructions and current Android renderer.
- [x] Create this implementation plan and record scope, edge cases, verification and open questions.
- [x] Phase 1: write all failing rich-content tests and verify RED.
- [x] Phase 1: correct recursive markup rendering, verify GREEN, simplify and recheck.
- [x] Phase 2: write all failing math/code rendering tests and verify RED.
- [x] Phase 2: implement offline formula layout and themed code highlighting, verify GREEN and screenshots.
- [x] Phase 3: establish a repeatable Release baseline and identify the concrete hot path.
- [x] Phase 3: preserve the earlier failing interaction/accessibility regressions and establish nine passing backend contracts before the behavior-preserving pipeline refactor.
- [x] Phase 3: implement the smallest durable optimization, verify GREEN and interaction parity.
- [x] Phase 4: write failing measurement-validity tests, fix fixture/state handling and verify GREEN.
- [x] Run the relevant Android unit/instrumentation gates and Release build.
- [x] Repeat the same Release performance scenarios, inspect traces and capture after screenshots/demo.
- [x] Update the report with actual improvements, remaining limits and test results; complete the goal only when its implementation and verification are done.

## Phase 1: preserve the complete markup tree

Files:

- `/Users/tiensonqin/Codes/projects/logseq-chat/android/app/src/androidTest/kotlin/com/logseq/app/AndroidRichContentTest.kt` (new).
- `/Users/tiensonqin/Codes/projects/logseq-chat/android/app/src/main/kotlin/com/logseq/app/ui/extensions/OutlinerBlockContent.kt`.
- `/Users/tiensonqin/Codes/projects/logseq-chat/android/app/src/main/kotlin/com/logseq/app/ui/extensions/AndroidRichText.kt` (only if extraction improves reuse).

1. Build a small test harness using the existing `logseqExtensionRegistry`, `LuiBackend.applyJson` and Compose test rule.
2. Feed actual shared markup shapes through `create-extension` and assert visible text and link callbacks for nested emphasis, quotes, Unicode, completion decoration, empty children and malformed markup fallback.
3. Run the complete new test class and retain expected failing assertions before touching production code.
4. Recursively consume children under their inherited style and annotations; keep quote text interactive and size its decoration to its actual content.
5. Cache parsed/grouped markup by encoded input and avoid rebuilding identical annotated content on unrelated recompositions.
6. Re-run the new class and existing outliner parity tests; use the existing fixture for a screenshot comparison.

The expected rendering contract includes this concrete input:

```json
{"type":"emphasis","style":"bold","children":[{"type":"text","text":"bold text"}]}
```

Its visible text must remain `bold text`.
The implementation must not require a duplicated `text` field from the shared layer.

## Phase 2: render math and code without adding WebViews

Files:

- `/Users/tiensonqin/Codes/projects/logseq-chat/android/app/build.gradle.kts`.
- `/Users/tiensonqin/Codes/projects/logseq-chat/android/app/src/main/kotlin/com/logseq/app/ui/extensions/OutlinerBlockContent.kt`.
- `/Users/tiensonqin/Codes/projects/logseq-chat/android/app/src/main/kotlin/com/logseq/app/ui/extensions/AndroidMath.kt` (new if needed).
- `/Users/tiensonqin/Codes/projects/logseq-chat/android/app/src/main/kotlin/com/logseq/app/ui/extensions/AndroidCodeBlock.kt` (new if needed).
- `/Users/tiensonqin/Codes/projects/logseq-chat/android/app/src/androidTest/kotlin/com/logseq/app/AndroidRichContentTest.kt`.

1. Add the complete math/code test set first and confirm the old plain-text implementation fails the intended assertions.
2. Validate a local Android Canvas TeX implementation and a pure Kotlin syntax engine using their primary documentation and real dependency resolution.
3. Keep renderer/library details behind small Android helpers; prefer existing Maven Central artifacts and record the selected versions.
4. Perform nontrivial parsing/highlighting away from repeated main-thread composition; cache by source, language, theme and text size as applicable, with bounded lifetime.
5. Preserve accessible source text, clear invalid-expression fallback, horizontal access to wide formulas/code and theme contrast.
6. Keep unknown languages readable, preserve all code characters and whitespace, and show a language label when supplied.
7. Test offline in light/dark appearance and remeasure rich-row scrolling after adding the renderers.

Candidate primary references:

- [JLatexMath Android](https://github.com/noties/jlatexmath-android) for offline Canvas formula rendering.
- [Highlights](https://github.com/SnipMeDev/Highlights) for Kotlin syntax highlighting including Swift.

These are implementation candidates, not a requirement to use a particular library if dependency or rendering validation fails.

## Phase 3: optimize the measured scrolling work

Initial inspection paths:

- `/Users/tiensonqin/Codes/projects/logseq-chat/android/app/src/main/kotlin/com/logseq/app/ui/extensions/OutlinerBlockContent.kt`.
- `/Users/tiensonqin/Codes/projects/logseq-chat/android/app/src/main/kotlin/com/logseq/app/runtime/LogseqRuntime.kt`.
- `/Users/tiensonqin/Codes/projects/logseq-chat/shared/src/logseq/view_outliner.ml`.
- `/Users/tiensonqin/Codes/projects/logseq-chat/android/app/src/androidTest/kotlin/com/logseq/app/AndroidOutlinerParityTest.kt`.
- `/Users/tiensonqin/Codes/projects/logseq-chat/duniverse/lui/platform/android/lui/src/main/kotlin/dev/lui/LuiVirtualList.kt` and `LuiNodeView.kt` (dependency investigation).

1. Retain the original report samples and capture a fresh pre-change Release baseline in a separate evidence directory.
2. Use 100 journals × 8 blocks, the same gesture sequence, refresh rate and GPU mode; build completely before measurement.
3. Separate first-use/JIT measurements from warmed scrolling; validate foreground, screenshot content, actual movement and absence of system dialogs.
4. Identify whether work is repeated span construction, virtual-window invalidation, unnecessary wrapper layout, composition reuse or code compilation before selecting the change.
5. Write the selected behavior regression before implementing; preserve the ten-thousand-row scroll/edit/back test.
6. Prefer removing repeated work and unnecessary layouts over lowering visual fidelity, disabling virtualization, or changing data semantics.
7. If the real defect belongs to LUI, make the change durable in its source repository and update the app's pinned dependency rather than relying on an ignored `duniverse` edit.
8. Evaluate app Baseline Profiles only for measured JIT costs; do not call AOT compilation a fix for repeated expensive layouts.

Native row integration is an option only if the trace shows that the existing generic row hierarchy remains the dominant cost after simpler fixes.
It must preserve status/priority, tags, collapse, edit, selection, page navigation, assets and drag/drop, and requires shared-protocol/iOS fingerprint updates if the extension schema changes.

## Phase 4: make acceptance evidence repeatable

Files:

- `/Users/tiensonqin/Codes/projects/logseq-chat/scripts/test-android-e2e.sh`.
- `/Users/tiensonqin/Codes/projects/logseq-chat/scripts/test-android-e2e-runner.sh`.
- `/Users/tiensonqin/Codes/projects/logseq-chat/tests/e2e/android-rich-block-rendering.yaml`.
- `/Users/tiensonqin/Codes/projects/logseq-chat/docs/agent-guide/android-ios-release-qa/2026-10-21/measure-android.py`.
- `/Users/tiensonqin/Codes/projects/logseq-chat/docs/agent-guide/004-android-ios-release-qa_report.md`.
- `/Users/tiensonqin/Codes/projects/logseq-chat/docs/agent-guide/005-android-release-quality_report.md` (new result report).

Add measurement-tool behavior tests before changing state/fixture handling.
Resolve the canonical graph directory from persisted metadata or the platform storage policy; do not assume the graph ID is the active directory name.
Use Maestro-compatible relative screenshot names/output directories and retain failure artifacts.
Reject obstructed, nonmoving or zero-frame scrolling samples and keep unsupported measurements distinct from regressions.
Record device, revision, variant, compilation mode, dataset, warmup, host conditions, sample counts, frame distribution, memory and trace paths.
Report comparisons for the same scenario; do not claim the proposed <5% jank / P95 <32 ms target has passed without measurements.

## Verification commands

Run from `/Users/tiensonqin/Codes/projects/logseq-chat`.
Keep Gradle workers/heap bounded while a simulator is running; do not measure performance during compilation.

```sh
rtk proxy ./android/gradlew -p android --max-workers=2 --no-parallel -Dorg.gradle.jvmargs=-Xmx2g -PlogseqRequireNativeCore=false :app:testDebugUnitTest
rtk proxy ./android/gradlew -p android --max-workers=2 --no-parallel -Dorg.gradle.jvmargs=-Xmx2g -PlogseqRequireNativeCore=false :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.logseq.app.AndroidRichContentTest
rtk proxy ./android/gradlew -p android --max-workers=2 --no-parallel -Dorg.gradle.jvmargs=-Xmx2g -PlogseqRequireNativeCore=false :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.logseq.app.AndroidOutlinerParityTest
rtk proxy ./android/gradlew -p android --max-workers=2 --no-parallel -Dorg.gradle.jvmargs=-Xmx2g :app:assembleRelease
```

Instrumented tests must use a current matching native core; do not use `logseqRequireNativeCore=false` when shared OCaml or protocol inputs have changed since the native build.
Expected final result is passing relevant suites and a successful Release build, with separate pre/post measurement artifacts.

If shared code changes, run the required core gate serially:

```sh
rtk proxy opam exec --switch=5.5.0 -- dune build @shared/native/runtest
```

Apply @ocaml-development for core work and @test-driven-development for implementation.
If editing LUI OCaml views, first read its required reactive skill.
If Swift changes become necessary, use build-only validation with the native-link environment; never run `swift test`.

## Testing Details

Visible text, preserved annotations, actual link callbacks, formula pixels/layout, highlighted spans and scroll/edit/back behavior are the assertions.
Tests must fail for the missing behavior before implementation, and existing interaction tests must remain green afterward.
Performance evidence includes raw frame counts and trace slices rather than a single average FPS.
Simulator improvement does not establish a Redmi result, and unavailable real-device/login credentials are recorded as remaining release validation rather than fabricated success.

## Implementation Details

- Preserve the shared markup contract and recursively render children.
- Keep completed-state decoration compatible with nested formatting.
- Avoid new WebViews for math/code.
- Bound caches and cancel stale async render work.
- Keep accessibility, theme and large-font behavior in the renderer contract.
- Optimize demonstrated hot paths while preserving row identity and virtualization.
- Persist any dependency fix and its pin; do not ship an ignored local patch.
- Keep source/comments in English and retain unrelated user work.
- Update the plan after every phase with RED/GREEN and measurement evidence.

## Question

No user answer is required to start implementation.
Redmi hardware, authenticated two-device sync and production signing remain separate release-validation inputs when available.
The exact performance mechanism is deliberately trace-driven; any change of approach and measured outcome will be recorded here.

---

## Current status

Implementation and emulator verification are complete. The [result report](005-android-release-quality_report.md) retains the separate formal Release gaps.

- Rich text: eight real-wire instrumentation cases pass after expected content/accessibility failures. Formula/code: eight layout/pixel/span/contrast cases pass after expected failures.
- The accepted performance fix removes repeated JSON parsing/serialization and historical node-kind accumulation. It reads existing retained backend data and applies the decoded batch. Nine backend contract tests pass on both original and new implementations; this performance refactor preserves behavior rather than inventing a failing functional test.
- LUI change `1edf12691bcd78ee65b52355d5c2a35f4194524c` is published and pinned in `logseq.opam`. The same source tree was cherry-picked onto the current remote main and pushed normally as `e33a152120dff61a65217130d9479f0e974fde47`. Only `LuiBackend.kt` changes: a retained-kind query and public access to the existing decoded-batch method. No view/layout/style changes.
- Release pipeline CPU medians for the same 50-batch native stream/core: original 492.38ms, new 348.09ms, reverse original 1007.37ms (12 samples and six warmups each). The first pair is about 29% lower; host/ART/GC variance prevents a universal percentage or whole-app speed claim.
- Controlled Release scrolling with identical content and native libraries: original 93/743 janky frames (12.52%), new 59/949 (6.22%). Some rounds still miss the suggested budget; retain them as counterevidence.
- Final frozen integration APK, build revision `2ad7d02e` plus this task's workspace changes: 27/993 janky frames (2.72%), with three rounds at 3.40%, 2.08%, 2.70% and P95 26/23/21ms. All meet the emulator budget. This package has a newer core than the controlled pair, so do not attribute the entire difference to this optimization.
- Final default-native Debug/AndroidTest/Release build gate succeeded. Android JVM tests: 54 passed. Final frozen APK instrumentation: 17 passed, including the 10,000-row navigation/virtualization case. Measurement/seed tests: 10 passed. Existing E2E runner suite passes.
- Measurement rejects launch timeouts, dialogs, wrong foreground, zero frames and unchanged lists. Checkpoint metadata resolves the canonical graph folder. API36 system/ART instability is excluded; final measurements use API33 independently.
- Native `screenrecord` final demo: 24.829056 seconds, 1080×2400 H.264, unedited, no audio. Production screenshot and a frame from actual scrolling were visually checked. Recording is separate from timing.
- The root-menu overlay and candidate app Baseline Profile are withdrawn. No app-specific profile or extra menu/layout mechanism is shipped. Historical experiment logs remain explicitly separated.
- iOS layout/styling/source and its LUI pin are unchanged by this task. Concurrent Apple/shared-core/editor edits belong to other work and are preserved.

Redmi hardware, real authenticated editing/sync/attachments, Chinese IME and production signing remain formal Release validation gaps. Emulator completion does not assert that the Redmi issue is resolved.
