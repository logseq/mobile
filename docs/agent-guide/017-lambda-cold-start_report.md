# Lambda journal cold-start investigation

## Scope and current result

The target remains **at most 300 ms from process creation to the first visible journal-content frame**. It has not been achieved.

Measurements use the Mac VM's iPhone 17 Pro simulator, iOS 26, a fresh process, and an isolated copy of Lambda RTC containing 11 populated journal blocks on today. Five nonempty native outliner title labels must intersect the window at the first commit. The original graph is never modified. OS file caches and graph state remain warm between process launches.

The harness restores the local graph and authenticated renderer directly. Authentication restoration and networking are excluded: this is a lower bound, not a whole-app readiness result. The endpoint is a conservative display callback after the committed content's estimated presentation time. A Core Animation commit or logo does not count as success.

The uninstrumented production Release build, with the OCaml core rebuilt from mobile main revision `aed77e1f8ff14d677a9fa992818e57e584901971` and no Swift testability, measured **707.4 ms median over five launches**, maximum 769.3 ms. See [production samples](017-lambda-cold-start/production-visible.json). Diagnostic builds below contain temporary controls and are compared only against their own same-binary baseline.

## Proven launch-path fixes

1. QuickLook loaded before `main` even when no preview was open. SDK-only controls isolated approximately 167 ms of framework-loader cost; removing the app's eager import and presenting previews on demand reduced the full app's pre-main median from approximately 383 to 276 ms.
2. A closed compact drawer mounted its entire sidebar, including another navigation stack. LUI commit `3ccbbcfa97161dba207f4065ace8f72b068c00f5` removed the first-reveal guard. Restoring lazy first reveal reduced view creation from approximately 217 to 174 ms. After first reveal, the panel remains mounted and retains its state. Regular-width pinned drawers are unchanged.

Both changes are in [LUI PR 262](https://github.com/logseq/lui/pull/262), revision `3171aeaaec2125d8363e667eed439b9341b62fa6`. The mobile worktree pins that revision. The PR is open, not merged.

Other retained changes remove the launch cover's background fade, defer sidebar loading until the first content commit, and avoid decoding UI-owned response arrays a second time in the Swift host. The small host-decoding gain is not established as a major bottleneck.

## Same-binary component controls

Seven randomized, interleaved rounds used one Release binary. Each mode still presented five real journal titles. The binary's SHA-256 was checked after every run. These omissions are diagnostic controls, not proposed product behavior, and have all been removed from application source.

| Diagnostic mode | Median to display callback | Difference from complete UI |
| --- | ---: | ---: |
| Complete interface | 745.1 ms | — |
| Omit top toolbar | 678.5 ms | 66.6 ms |
| Omit bottom composer | 717.2 ms | 27.9 ms |
| Omit both | 624.0 ms | 121.1 ms |
| Omit navigation and both toolbars; retain journal body | 598.5 ms | 146.6 ms |

Source: [component samples and stage timings](017-lambda-cold-start/component-ablation.json).

The differences are not additive. Navigation and toolbar construction share framework initialization and affect when work happens relative to `onAppear`. For example, removing navigation shifts some work from the measured layout interval into creation. The navigation-only marginal difference relative to the mode without both toolbars is approximately 25.5 ms, not 146.6 ms.

A second same-binary experiment split individual toolbar contents over five interleaved rounds. Median paired improvements were 25.5 ms for the leading control, 30.4 ms for sync status, 11.7 ms for menu contents, and 8.4 ms for custom glass. Some rounds reversed the direction, particularly menu and glass. These smaller differences are **not sufficient to establish an individual control as the root cause**. See [individual toolbar samples](017-lambda-cold-start/toolbar-ablation.json).

## Main-thread CPU attribution

Time Profiler signposts isolate creation and first layout in the complete-interface diagnostic build. Instrumented wall time must not be substituted for the uninstrumented benchmark.

| Phase | Instrumented wall interval | Main-thread CPU samples | CPU coverage |
| --- | ---: | ---: | ---: |
| View creation | 225.0 ms | 183 ms | 81% |
| First layout to commit | 174.8 ms | 157 ms | 90% |

Across these two disjoint intervals, approximately 100 ms of main-thread samples contain `swift_conformsToProtocol*`. Type-metadata lookup (`swift_getTypeByMangled*`) accounts for 57 ms inclusive; dynamic-field discovery (`DynamicPropertyCache.fields(of:)` / `AGTypeApplyFields2`) accounts for 29 ms inclusive. **These categories overlap and cannot be summed.** Background AttributeGraph conformance scans are not added to the main-thread critical path.

Stacks locate costs in SwiftUI generic metadata, conditional view lists, dynamic-property field discovery, and navigation construction. The profiler does not identify every concrete generic type, so it does not yet prove which individual application view should change. A separate no-top trace was much slower under instrumentation and is not used to claim a causal CPU improvement.

Phase evidence: [profile attribution](017-lambda-cold-start/profile-phases.json). VM-local traces: `/tmp/logseq-startup-component-full.trace` and `/tmp/logseq-startup-component-no-top.trace`.

## Native row subphases

Timers accumulated across all five visible rows before the first commit. Medians below come from the complete-interface mode in the second diagnostic binary.

| Operation | Cumulative time |
| --- | ---: |
| Decode or retrieve row payloads | 4.88 ms |
| Create native rows | 5.29 ms |
| Update native rows | 21.54 ms |
| Measure native text rows | 1.48 ms |
| Draw title glyphs | 2.79 ms |

Inside row updates, bullet icons account for **18.59 ms**; markup assembly 0.25 ms; colors 0.14 ms; priority 0.54 ms; status 0.95 ms; disclosure 0.53 ms; tags 0.75 ms. Subphases are contained in the row-update total, not additional costs.

The source path is `OutlinerTextRowView.update` → `NodeIconExtension.image` → `NodeIconAssets.glyph`. The first lookup decodes the shared 250,934-byte catalog containing 1,931 emoji and 6,146 Tabler entries, then renders an image with `UIGraphicsImageRenderer`. The complete-interface profile has 16 ms inclusive in the icon path, with 5 ms in catalog decoding and 9 ms in image rendering. This explains a concrete portion of row initialization, but is smaller than framework loading and SwiftUI initialization.

An additional direct glyph/bitmap timer experiment overlapped simulator background activity and another simulator test; launch times rose to 1.9–3.0 seconds. Those wall-time results are rejected as performance evidence. Earlier stable component results are not replaced by these measurements.

After restoring every temporary application-source change, a fresh production build and one native launch passed the production-flag, FFI-export, binary-identity, and visible-content checks. The host was still contended; that launch took 1,859.9 ms and failed the 300 ms threshold. It is preserved in [the contended restored-source sample](017-lambda-cold-start/restored-source-contended.json), not treated as a directly comparable performance baseline.

## Rejected experiments and measurement safeguards

- Erasing the button-style conditional to `AnyView` produced no measured improvement and was reverted.
- Erasing the native/rich outliner-row dispatch to `AnyView` produced no measured improvement and was reverted.
- Adding another outliner-row equality boundary produced no measured improvement and was reverted.
- The old first-frame timestamp used the previous display-link frame and could precede the callback. The harness now rejects such results and checks real visible content.
- A shared `PageBenchmark` installation was replaced by an unrelated Demo check during the first component experiment. That experiment was discarded. Cold-start measurements now use a dedicated `com.logseq.logseq.ColdStartBenchmark` bundle, isolated keychain entitlement, and binary identity checking.
- The benchmark refuses modules built with `-enable-testing`, without `-O`, or with `-DDEBUG`. The final executable must export only the shipping app's five native FFI callbacks.

## Follow-up controls

Runtime type-name probes confirmed that the navigation root's nested `ToolbarModifier` types and the button label's nested `_ConditionalContent` types enter conformance checks. These probes identify types; their injected library changes the process and is not used as production timing evidence.

Extracting the unchanged button label into a concrete named View was tested against two immutable production binaries in seven randomized paired rounds. The median paired wall-time improvement was **-36.2 ms**: no consistent benefit. The extraction was reverted. A separate injected CPU-probe run appeared faster, illustrating why an instrumented comparison alone is insufficient. See [uninstrumented label comparison](017-lambda-cold-start/named-label-comparison.json).

A same-binary lifecycle comparison retained the identical journal renderer, native title rows, navigation, and toolbars, changing only SwiftUI `App` versus a UIKit app/scene delegate with a hosting controller. Seven paired rounds produced a median wall-time difference of **328.1 ms against UIKit** and a main-thread CPU difference of 161.3 ms against UIKit. The environment was variable; this rules out adopting this particular control as an established improvement, not all possible UIKit designs. No production lifecycle change was made. See [lifecycle evidence](017-lambda-cold-start/lifecycle-comparison.json).

Five interleaved SDK-only loader controls measured 194.4 ms to `main` without added frameworks, 274.4 ms with AuthenticationServices, 205.7 ms with Speech, and 269.5 ms with both. AuthenticationServices remains a concrete loader candidate; Speech alone is not a major loading cost in this control. These are standalone controls, not a promise of an equally large removable cost in the full app. See [loader controls](017-lambda-cold-start/framework-speech-isolation.json).

Root modal-host omissions kept the complete initial journal and toolbar UI, but temporarily skipped registration of unopened sheets/dialogs and/or the image preview cover. A diagnostic binary produced medians of 2,218.5 ms complete, 2,097.2 ms without backend modal hosts, 2,022.5 ms without the image-preview host, and 2,004.0 ms without either. Individual rounds varied substantially, including reversals. The control also added a common type-erasure boundary, so these values cannot be compared directly to the production binary. All omissions were reverted. A production candidate would need to keep the base view's identity stable when a presentation host first mounts, retain native modal behavior, and demonstrate a repeatable gain. See [modal-host samples](017-lambda-cold-start/modal-host-ablation.json).

The latest uninstrumented production-source check reported **826.1 ms median, 1,257.5 ms maximum**, with five real visible titles in all five launches. This does not establish an improvement over the earlier 707.4 ms sample and still fails the 300 ms target. See [follow-up production samples](017-lambda-cold-start/production-followup.json).

The benchmark now optionally records process and main-thread CPU counters at each stage with `--cpu-times`, using native CPU clocks without an injected library. Counters are disabled by default, and the emitted summary declares whether they were enabled. One native opt-in run verified positive counters; the default run verified their absence. Production timing refuses injected profiling libraries before installation. Dedicated cold-start bundles also have unique executable names to avoid ambiguous Instruments process selection. See [CPU-counter check](017-lambda-cold-start/cpu-counter-check.json).

## Next optimization priorities

1. Attribute pre-main loading remaining after QuickLook. It is still approximately 280 ms in the stable diagnostic runs. SDK controls already implicate AuthenticationServices as another loader cost, but that control is not proof of an equally large removable cost in the complete app.
2. Resolve which concrete navigation/control view types drive the approximately 100 ms of main-thread conformance scanning. Preserve navigation, native menus, focus, accessibility, gestures, and visual behavior while testing any smaller representation. Do not repeat the ineffective blanket type-erasure changes.
3. Investigate the icon catalog and first bitmap rendering after the larger launch costs. Preserve emoji skin variants, colored icons, font variants, appearance, and display-scale cache keys.
4. Run full authentication-restoration and actual app-root startup before claiming the 300 ms goal. The local renderer lower bound alone cannot satisfy it.

## Validation and reproduction

The retained fixes passed 1,063 native core tests, 104 Swift UI tests using a direct Swift Testing app host, and native launch-cover, once-only first-frame observer, first-reveal drawer, deferred file-preview, real-graph deferred-sidebar, and host-metadata rendering checks. No XCTest or `swift test` was run. The simulator core was rebuilt from the worktree's current-main source.

Build the production simulator app with `LOGSEQ_IOS_CONFIGURATION=release scripts/build-mobile-ios-simulator.sh`, then measure an isolated fixture:

```sh
python3 scripts/benchmark-ios-cold-start.py /path/to/isolated-documents \
  --graph-id lambda-latency --simulator SIMULATOR_UDID \
  --iterations 5 --maximum-ms 300 --minimum-rows 1 \
  --output /tmp/logseq-cold-start-results
```

The command deliberately exits nonzero while the threshold is missed. Run without concurrent builds, Instruments recording, or other simulator tests. Functional launch checks are available through `python3 scripts/test-ios-launch.py`; these build with testability, so rebuild production modules before timing.
