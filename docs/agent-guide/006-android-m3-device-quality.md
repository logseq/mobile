# Android M3 and Device Quality Implementation Plan

Goal: Make the LUI Android backend follow Material 3, align composer behavior with iOS, and reduce measured interaction stalls in the emulator.

Architecture: Keep shared product semantics and native platform renderers.
Android controls use official Material components and defaults; Apple rendering remains unchanged.
Fix measured causes without introducing a second menu manager, renderer or scheduling framework.

Tech Stack: Kotlin/Compose Material3, OCaml/LUI, Android instrumentation, Perfetto, physical Redmi.

Related: Builds on [005-android-release-quality_report.md](005-android-release-quality_report.md).

## Problem statement

The user observes nonnative composer attachment/status menus and continuing interaction stalls on a physical Redmi.
Component imports alone are not conformance evidence.
The migration target is the current Material 3 Expressive specification for all Android controls, as explicitly requested by the user.
Baseline components alone do not satisfy this target.
Composer menu nodes are mounted/unmounted through shared model state, interrupting native dismissal transitions.
Several LUI defaults intentionally mirror Apple typography or chrome and require an Android-wide audit.

Root workspace: `/Users/tiensonqin/Codes/projects/logseq-chat`.
LUI source: `/Users/tiensonqin/Codes/projects/logseq-chat/duniverse/lui`.
Preserve all concurrent work and the phone's graph, authentication, draft and attachments.
The user subsequently requested emulator-only interaction testing, then explicitly requested installation on the physical device.
Install and launch the validated preview on the Redmi, preserving data; continue automated interaction tests in the emulator without asking the user to change security settings.
Earlier physical-device traces/screenshots containing graph content stay local under `/tmp/logseq-redmi-qa-20261022`.
Only sanitized aggregate results belong in repository reports or upstream commits.

## Testing Plan

Add the complete menu regression set before implementation.
Use real Compose rendering and the real native bridge for composer cases.
Test entry/exit transitions, single-selection dismissal, selected-state persistence, disabled actions, outside/Back dismissal and reopening.
Validate draft preservation and focus/keyboard behavior against the existing iOS behavior without sending real captures.
Run write/action tests on the emulator, with physical-device checks confined to reversible navigation and menu opening unless a later scenario requires actual edits.

Measure the installed baseline on the physical device before replacing it.
Separate menu, keyboard and scrolling scenarios, retain frame deadlines/CPU scheduling traces and thermal/display state, and repeat the same scenarios after changes.
Do not interpret mixed lifetime gfx statistics as a controlled benchmark.
Do not compile or record video during timing runs.

For changes to shared views, run `rtk proxy opam exec --switch=5.5.0 -- dune build @shared/native/runtest` serially, then rebuild the actual Android core.
For Android UI, assemble matching Debug/test APKs and run the focused instrumentation class on `emulator-5556` before broader retained regressions.
Do not run `swift test`.

NOTE: I will write *all* tests before I add any implementation behavior.

## Work checklist

- [x] Read M3 overview, specifications and guidelines in a JavaScript-capable browser.
- [x] Inspect current composer and LUI rendering paths.
- [x] Confirm the physical Redmi is connected and collect initial diagnostics.
- [ ] Capture repeatable baseline menu/keyboard/scroll evidence in the emulator.
- [x] Automate interaction tests in the emulator and requested installs/captures on the phone; no user assistance required.
- [x] Write all failing behavior regressions for the first menu batch and verify RED.
- [x] Replace composer model-mounted menus with retained native menu triggers on Android only.
- [x] Preserve native dismissal transitions, checked/disabled semantics and component feedback for menus.
- [x] Verify GREEN and retained content/navigation regression gates for the validated batches.
- [ ] Audit LUI Android defaults across typography, buttons, fields, menus, dialogs/sheets, selection controls, lists and navigation against M3.
- [x] Record baseline versus Expressive API availability and the actual dependency/SDK constraints before any upgrade.
- [ ] Validate the official SDK/dependency upgrade and migrate controls to the current expressive APIs.
- [ ] Fix confirmed default/interaction mismatches with behavior tests, avoiding Apple-specific values as Android defaults.
- [ ] Diagnose emulator interaction stalls from trace and apply the smallest evidence-backed optimization.
- [ ] Repeat emulator measurements and install the validated package in the emulator.
- [ ] Publish tested LUI fixes to main, update the app pin, and report actual results plus any remaining gaps.

## First implementation batch

Validated progress on 2026-10-22:

- The first preview Release was installed over the existing Redmi app without clearing data. Android reported `Success`; launching the activity reported `Status: ok`.
- The next Android renderer batch now uses official Expressive `DropdownMenuPopup`, `DropdownMenuGroup`, shaped menu items and `SelectableDropdownMenuItem`. Retained composer menus preserve native dismissal transitions and native single-selection semantics.
- Checkbox, switch and radio labels participate in one native selection target. Tabs use `PrimaryTabRow`/`Tab` and follow model selection updates.
- The combined composer, Material defaults and selection/tab instrumentation run passed all 19 tests in 68.207 seconds on the emulator. JVM tests passed all 57 cases. These are behavior gates, not performance benchmarks.
- The user requested another reinstall. The next batch Release passed packaging/signature validation and was installed over the Redmi app with `Success`; launching returned `Status: ok`. The native core matches the Debug APK used for the 19 behavior tests. Artifact identity and receipt: `android-m3-quality/2026-10-22/expressive-apk.json`.
- Remaining component defaults/modern APIs and controlled Release performance measurements are still pending.

Next validated native-surface batch:

- Nine native-surface tests and fourteen typography/default tests first reproduced thirteen real failures; the complete focused gate now passes 35 tests in 96.569 seconds, including the previous composer and selection controls.
- The drawer uses `ModalNavigationDrawer`/`ModalDrawerSheet`, native motion, scrim, accessibility dismissal and predictive Back. Its settled native state emits a single model event; model updates animate without echo events.
- Popovers use the official popup window rather than inline layout. Buttons use Expressive shapes, and icon-only variants use their corresponding native icon buttons. Lists use current interactive/selected APIs.
- Relative fonts use inherited `em` or Material body `rem` sizes. Semantic headline weights follow the host typography; explicit semibold styling remains supported. Android `glass`/`bar` defaults resolve to opaque Material surfaces.
- The 17 retained rich text, math/code and 10,000-row outliner regressions pass in 36.203 seconds. JVM tests still pass all 57 cases.
- A new signed Release was installed on the Redmi at the user's request; startup returned `Status: ok`. See `android-m3-quality/2026-10-22/native-surfaces-apk.json`.
- Raw logs, profiles, captures and replay dumps remain local and are ignored by Git. Small JSON results, Markdown reports and reproduction scripts remain visible. The root README and QA READMEs are explicitly verified as not ignored.
- Still pending: remaining component API/default review, controlled Release timing and CPU/frame traces, final iOS isolation audit, and upstream publication. No claim of completed performance optimization is made from behavior tests or a single launch.

Latest verification and steering:

- The user reiterated that Android should use native components and native interaction conventions. Preserve functional parity with iOS while keeping platform-specific presentation independent.
- The signed native-surface Release completed a three-run emulator measurement with no concurrent builds or recording. Scroll samples were 5/334 (1.50%), 10/308 (3.25%), and 6/332 (1.81%) janky frames; aggregate 21/974 (2.16%). P95 was 23/22/22 ms. Idle produced zero frames. Results are in `android-m3-quality/2026-10-22/native-surfaces-release/android-performance.json`.
- The earlier baseline was 22/973 (2.26%). This small difference does not establish an improvement, and the native core differs between those artifacts. CPU/frame tracing and a controlled optimization comparison remain required.
- Native accessibility actions completed the requested real Redmi screenshots in 10.952 seconds: main screen, drawer, attachments and status menu. No draft text or selection was changed. Private screenshots remain under `/tmp/logseq-redmi-m3-*.png` and are not committed. The phone was returned to a normal app launch afterward.
- The initial Compose-rule screenshot probe interfered with normal startup on the physical device and was stopped; it is not a product pass. The replacement driver uses platform accessibility actions with no Compose rule, activity replacement or input-injection permission. Its asynchronous drawer-close wait was corrected before the successful run.
- The user asked whether a complete native M3 composer exists. Official Material provides input fields and action controls, and Google's Jetchat sample composes its own input area. Our composer still has a shared custom capsule, borderless `BasicTextField` and Apple-oriented send styling; this is an explicit remaining migration item. Implement an Android-only composition of Material input/actions while preserving draft, attachments, status, IME/focus and outside-dismiss behavior. Add behavior tests first and leave the iOS branch intact.

Composer references:

- https://developer.android.com/develop/ui/compose/text
- https://developer.android.com/develop/ui/compose/text/user-input
- https://github.com/android/compose-samples/blob/main/Jetchat/app/src/main/java/com/example/compose/jetchat/conversation/UserInput.kt

Files:

- `shared/src/logseq/view_composer.ml`: Android attachment and task-status triggers own retained menu metadata; keep iOS branches unchanged.
- `duniverse/lui/platform/android/lui/src/main/kotlin/dev/lui/LuiNodeView.kt`: official trigger controls, native open/close state and single-action dismissal without waiting for the model roundtrip.
- `android/app/src/androidTest/kotlin/com/logseq/app/AndroidComposerMenuTest.kt`: native-bridge composer transitions/selection/focus and actual backend menu interaction boundaries.
- `shared/test/logseq/app_test.ml`: only add targeted shared behavior coverage, preserving existing concurrent edits.

The native menu owns visibility; the shared model owns chosen status, attachment services, capture contents and persistence.
A single selected item emits one action.
Disabled items emit no action and leave the menu open.
Outside/Back dismissal must not activate a background control.
Transitions use the official Material component rather than manually copied durations or a root overlay.

## Platform-wide review

Inventory every interactive LUI kind and map it to its Material component, default tokens and interaction contract.
Keep explicit app styling distinct from renderer defaults; do not ignore authored layout values globally.
Use Material typography/color/shape/motion and touch targets by default, with inherited custom typography as an explicit override.
Treat popover-as-inline-column, Apple-size typography defaults, missing selected semantics and fixed native-control dimensions as audit candidates, not automatically verified defects.

The original Material3 1.4.0 dependency provides baseline menus.
Official Material3 1.5.0-beta01 includes Expressive menu APIs but declares minCompileSdk 37 and Compose 1.12.0.
The original app compiled with SDK36 and LUI standalone with SDK35.
Official SDK37.0 has now been installed and the build uses the explicit minor API 0 DSL, Compose BOM 2026.09.00 (UI 1.12.1), and Material3 1.5.0-beta01.
Keep targetSdk 36 for this component migration.
The standalone LUI AGP minimum moves from 9.1.0 to 9.1.1 for SDK37.0 support.
An Expressive upgrade therefore needs compatible SDK/dependency validation and regression checks; do not silently force incompatible dependencies or hand-copy new widgets.

References:

- https://m3.material.io/components/menus/overview
- https://m3.material.io/components/menus/specs
- https://m3.material.io/components/menus/guidelines
- https://developer.android.com/jetpack/androidx/releases/compose-material3
- https://developer.android.com/develop/ui/compose/components/menu

## Testing Details

Tests exercise displayed native controls, semantics, callback counts, actual state changes and retained transitions.
Trace comparisons use the user's actual graph and report the physical device separately from the earlier emulator study.
A menu package change must not inherit an untested core revision without rebuilding and identifying the artifact.

## Implementation Details

- Android defaults follow M3; iOS continues using native Apple behavior and styling.
- Composer actions and outcomes match across platforms.
- Keep menu visibility in the native control, product state in the shared model.
- Preserve system back/outside handling and keyboard/draft behavior.
- Prefer official components over custom imitations.
- Remove duplicated work only after profiling confirms it.
- Keep source/comments English and changes simple.
- Push only tested LUI changes, with no private device evidence.

## Question

Use emulator automation for editing tests and performance comparisons, with no manual assistance.
The user subsequently authorized physical-device installs and screenshots. Preserve all phone data;
use read-only capture and accessibility navigation there, and do not request a security-setting change.
The previous LUI main push authorization remains valid.
If an official component needs an incompatible toolchain, report the exact constraint and keep progress on independent fixes.

---

## Composer migration verification

- The new real-native-bridge composer gate ran seven emulator tests before implementation. Six failed for the intended product differences: 36dp input, unbounded 288dp multiline growth, an invisible focus button, custom black Send fill, and legacy camera/Send sizing. Unicode draft/status retention already passed.
- The Android branch now composes the official Material input and filled/tonal icon buttons. Long input is bounded to five visible lines, and empty toolbar space is a spacer. The Apple capsule and Apple-specific control values are retained in their existing branch.
- The obsolete test requiring Android to copy iOS chrome was replaced with an actual capture contract check: Unicode/multiline input, dismissal/reopen, enabled state, trimmed submission and draft clearing. The existing iOS layout/style contract remains unchanged.
- The first complete 59-case emulator run passed 58 cases. The remaining camera assertion incorrectly required a 40dp semantic slot even when the parent reserves 48dp; it now verifies the native tonal color and 48dp touch target. The corrected check was verified failing against the previous APK and passing against the composer APK. All seven composer tests pass.
- The shared gate passed 897 cases for the composer batch, including the existing Apple composer layout/style checks. Final combined toolbar validation and screenshots are pending.

## Editor and selection toolbars

- The user explicitly added editor and selection toolbars to this migration. Horizontal LUI toolbars now use official `HorizontalFloatingToolbar`, retaining a horizontally scrollable action area and the pinned final action. Shared Android code delegates container size, shape and color to Material; Apple toolbar branches remain unchanged.
- Four failures were reproduced before implementation: both toolbar containers used custom row metrics, and forward/reversed native text selections collapsed after a shared caret acknowledgement. A local equality check now distinguishes that acknowledgement from an external caret request, preserving the native selection without adding a second selection manager.
- The toolbar test fixture verifies native-bridge command delivery rather than assuming a bare bridge executes host effects. Overflow tests check the pinned action remains stationary and emits exactly one typed `hideKeyboard`/`unselect` command. External caret requests remain covered.
- The shared gate passes 898 cases, and all 57 JVM tests pass. Fresh native APK and the complete combined emulator instrumentation gate are pending.
- Native reference: https://developer.android.com/reference/kotlin/androidx/compose/material3/HorizontalFloatingToolbar.composable.

## Profile-guided investigation

- A 16-second `simpleperf` task-clock profile of the native-surface Release collected 1,425 samples with zero lost samples during automated scrolling, with no concurrent build. Interpreter dispatch (`ExecuteNterpImpl`) accounted for 7.58% self time; Compose layout and prefetch dominated inclusive stacks. JNI polling was not a major sampled hotspot.
- The current release configuration explicitly disables R8, while referring to a nonexistent `proguard-rules.pro`. Official Android guidance recommends enabling release optimization. Audit native lookup entry points, then compare optimized and unoptimized builds with an identical core and source snapshot before claiming a speedup.
- References: https://developer.android.com/develop/ui/compose/performance and https://developer.android.com/topic/performance/app-optimization/enable-app-optimization.

## Remaining component audit

This inventory is based on the current Android renderer, not on component imports alone.

| Surface | Current evidence | Remaining work |
| --- | --- | --- |
| Buttons and icon buttons | Official Expressive shapes/variants; native semantics, disabled state, touch targets and press shape tested | Broader app theme review |
| Checkbox, switch, radio and tabs | Native components; label interaction, single callback, disabled/selected state tested | Dark mode and large text review |
| Menus | Current popup/group/item APIs; retained transitions, Back/outside, action counts and radio semantics tested | Full anchor/alignment/offset contract; landscape and IME placement; detached inline fallback |
| Drawer | Native modal drawer, scrim, motion and accessibility dismissal tested | Actual-device predictive Back capture |
| Popover | Native popup and Material surface; Back tested | Full wire anchor contract |
| Composer | Material field and action buttons; draft/status/Unicode/outside preservation and five real-IME flows tested; combined gate passes | Release keyboard timing and landscape coverage |
| Editor and block-selection toolbars | Official horizontal floating toolbar; real swipe reaches overflow with pinned final action; combined gate passes | Vertical toolbar remains a custom column |
| Native text selection | Caret acknowledgement preserves noncollapsed selection; external caret requests tested | Actual platform selection-menu/clipboard scenario |
| Text entry and slider | Material controls are present | Current state APIs and IME/composition audit; slider uses deprecated value API |
| Tooltip | TooltipBox anchor exists, but content is plain Text | PlainTooltip surface and current position API; long-press/dismiss behavior |
| Dialog and sheet | AlertDialog and ModalBottomSheet | Focus/keyboard/dismiss gates; replace deprecated sheet state API |
| Card, toggle and toast | Card uses stack layout; toggle maps to FilterChip; toast uses Card | Use appropriate official Material surfaces/controls and test actual semantics/dismissal |
| Bottom navigation and progress | Native NavigationBar and progress indicators | Focused selection/disabled and current defaults review |
| App defaults | Renderer uses Material typography/surfaces | Remove remaining Apple-derived app semantic-color overrides and editor text-style overrides with behavior coverage |

Layout/data primitives (rows, columns, lazy lists, tables, images, media and custom document structure)
do not acquire a new interactive control merely to resemble a Material component. Preserve their
authored layout and behavior while checking the Material defaults they inherit.

## Screenshot-driven spacing correction

- The user requested a smaller bullet-to-text gap and a common vertical guide with the page title.
- Six geometry/interaction tests were added first. Four reproduced real failures: a missing priority still reserved about 7dp, affecting reading, editing and priority removal, and the title edge was 7.5px away from the bullet center at emulator density.
- A missing priority now mounts no view. The Android journal heading inset uses half of the 24dp bullet slot, keeping its leading edge on the bullet center line. Native bullet touch targets and nested indent steps are covered.
- The shared gate passes 898 cases. The aligned native build passes all 72 combined emulator cases in 174.327 seconds. Updated captures are `/tmp/logseq-m3-aligned-editor-toolbar.png` and `/tmp/logseq-m3-aligned-selection-toolbar.png`.
- A broader 66-case run initially passed 64 cases. The other two assertions were corrected to respect native selection-direction normalization and to use actual horizontal swipes instead of `performScrollTo`, whose clipped target bounds were zero. All seven toolbar cases then passed in 34.262 seconds, including visible overflow and one typed command per action. This is behavior verification, not a performance benchmark.

## Composer menus and the real software keyboard

- The requested parity is to retain an already visible keyboard for both status and attachment menus, and to leave an already hidden keyboard hidden.
- Installed-app instrumentation reproduced the keyboard closing for both menus, outside dismissal and status selection. These checks use `dumpsys input_method` and real input events on the dedicated `uiregression` emulator graph; they do not mock the input method.
- The Android popup now uses the native `FLAG_ALT_FOCUSABLE_IM` policy alongside outside-touch observation. The popup retains native focus, Back handling, accessibility focus and exit transitions, while avoiding becoming an input-method target. No keyboard hide/show cycle or global menu controller was added.
- Native touch-modal popups intentionally move accessibility focus away from the underlying input while open. Tests check the real IME and menu geometry during that interval, then verify the input focus, position, draft, caret and continued typing after dismissal.
- Run installed-app methods in separate instrumentation invocations so each gets a fresh native host. The opt-in `verifyComposerIme=true` checks reject physical devices and graphs other than `uiregression`; they restore the draft without submitting content. Combined class execution exposed activity/native-host teardown races and is not a passing gate.
- All five installed-app keyboard flows pass. During each open menu, screenshot samples verify the actual keyboard remains visually unchanged, in addition to input-method service state. Status selection preserves the caret as verified by inserting a real key at that position; direct accessibility selection indexes were not a reliable native-platform assertion.
- The current native UI regression passes all 72 cases in 205.323 seconds. The Android host JVM suite passes 57 cases; standalone LUI Android passes 29 cases, including its Paparazzi run, with compiler warnings retained. These are functional gates, not performance measurements.
- The validated Android renderer batch was pushed to LUI main as `ab4c1e2d20d9b3ef9caa7451c5b5ecceb0e6d9a3`; `logseq.opam` now pins it. Apple renderer sources and the Apple package manifest were not changed by this batch. The remaining component audit above remains open.


## Block editor task status feedback

- Installed-app automation reproduced a visible-feedback failure: Todo and Doing updated the accessible label and persisted graph state, but the settled toolbar icon had exactly the same strokes. The regression test failed with zero differing icon pixels before the fix. It ignores background/ripple color changes rather than accepting any screenshot difference.
- The Android task button now derives its icon and foreground from the edited block's current status, using the same status helpers as composer and outline rows. The existing core cycle, native button, toolbar geometry and Apple branch remain unchanged.
- The new installed-app test passes the None → Todo → Doing → Done → None cycle, checks an actual settled icon change, keeps the real IME open and the toolbar anchored, and verifies Done after leaving and reopening the editor. It restores the original block status.
- The persisted-graph core regression also checks the cycle, unchanged Unicode block text and status after reopening the graph. The shared gate passes all 900 cases. The synthetic performance graph used in earlier QA lacked canonical task entities; the emulator fixture was backed up and rebuilt with canonical schema before these UI results. No production migration or phone data reset was added to address that fixture defect.
- Actual post-fix captures: `/tmp/logseq-block-task-todo-after.png` and `/tmp/logseq-block-task-doing-after.png`. The tested APK is `/tmp/logseq-block-task-fixed-debug.apk`, SHA-256 `824863b1a074c8079a292f70edfaa20bfe9662bfa9042b15d1fcedd30c556024`.
- Follow-up emulator regressions pass all five real-IME composer flows and all seven native-bridge toolbar cases. The same frozen APK installed successfully on Redmi `4a23a2e9` using `adb install -r`; existing phone data was retained. These are functional checks, not a new performance measurement.
