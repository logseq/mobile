# Lambda journal cold-start investigation

## Scope and current result

The target remains **at most 300 ms from process creation to the first visible journal-content frame**. It has not been achieved.

Measurements use the Mac VM's iPhone 17 Pro simulator, iOS 26, a fresh process, and an isolated copy of Lambda RTC containing 11 populated journal blocks on today. Five nonempty native outliner title labels must intersect the window at the first commit. The original graph is never modified. OS file caches and graph state remain warm between process launches.

The original harness restores the local graph and authenticated renderer directly, excluding authentication restoration and networking. It remains available as a renderer-only lower bound. The new `--app-entry` mode compiles the actual production `AppMain`, delegate, quick-action declarations, and `LogseqRootView`; only the `@main` trampoline is replaced to observe the key window. It restores synthetic unexpired credentials from its own keychain and uses an offline API address. The endpoint is a conservative display callback after real nonempty titles commit with no opaque launch cover. A Core Animation commit or logo does not count as success.

Before deferring interactive authentication UI, the rebuilt current-main core's reproducible actual-entry mode measured **763.5 ms median, 817.7 ms maximum over five launches**. Each launch displayed five real native titles and reported `signedIn` at the endpoint. See [earlier actual-entry samples](017-lambda-cold-start/app-entry.json). Current paired authentication controls and a later production sample are recorded below. The goal remains unmet. These runs include local stored-session restoration, excluding expired-token refresh and successful server synchronization.

After rebasing onto main `651202c3fc11ff714bcaddfae4d01bc3a5e57989` and rebuilding the native core, the current production actual-entry sample measured **765.9 ms median / 884.4 ms maximum** over five launches, with five visible titles and `signedIn` throughout. This is a new baseline, not a controlled comparison with earlier batches. See [current-main production samples](017-lambda-cold-start/app-entry-main-651202c.json).

The earlier renderer-only uninstrumented production Release build, with the OCaml core rebuilt from mobile main revision `aed77e1f8ff14d677a9fa992818e57e584901971` and no Swift testability, measured **707.4 ms median over five launches**, maximum 769.3 ms. See [production samples](017-lambda-cold-start/production-visible.json). Diagnostic builds below contain temporary controls and are compared only against their own same-binary baseline.

## Actual application-entry phases

These are medians of each phase in the current-main `651202c` five-launch sample; medians are not additive.

| Phase | Median |
| --- | ---: |
| Process creation to `main` | 233.5 ms |
| `main` to delegate initialization | 35.8 ms |
| Delegate initialization, including local graph/renderer startup | 49.7 ms |
| Initialization complete to key window | 159.3 ms |
| Key window to committed visible content | 279.5 ms |
| Commit to observed display callback | 14.1 ms |

The first preliminary actual-entry control measured 818.4 ms median / 953.9 ms maximum. The reproducible driver is not treated as a further speed improvement: VM variation and executable differences prevent that inference. Both establish the same broad priority: loading before `main`, then window and first-content construction. The window-to-commit interval can also contain authentication/session application; it is not attributed entirely to text drawing or SwiftUI without profiling.

## Proven launch-path fixes

1. QuickLook loaded before `main` even when no preview was open. SDK-only controls isolated approximately 167 ms of framework-loader cost; removing the app's eager import and presenting previews on demand reduced the full app's pre-main median from approximately 383 to 276 ms.
2. A closed compact drawer mounted its entire sidebar, including another navigation stack. LUI commit `3ccbbcfa97161dba207f4065ace8f72b068c00f5` removed the first-reveal guard. Restoring lazy first reveal reduced view creation from approximately 217 to 174 ms. After first reveal, the panel remains mounted and retains its state. Regular-width pinned drawers are unchanged.

Both changes are in [LUI PR 262](https://github.com/logseq/lui/pull/262), revision `3171aeaaec2125d8363e667eed439b9341b62fa6`. The mobile worktree pins that revision. The PR is open, not merged.

Other retained changes remove the launch cover's background fade, defer sidebar loading until the first content commit, and avoid decoding UI-owned response arrays a second time in the Swift host. The small host-decoding gain is not established as a major bottleneck.

### Interactive authentication UI

The Swift provider's `import AuthenticationServices` linked the browser-authentication framework into stored-session launches. The implementation now keeps SDK-typed browser code in a small Objective-C target that disables automatic framework linkage. The public system framework loads through dyld on the first interactive request. Stored-token restoration stays in the existing provider, and the sign-in browser retains its ephemeral session, scene anchor, native callback and cancellation behavior. The bridge accepts one active request and ignores stale completions after cancellation/reopening.

Seven randomized paired rounds compared immutable eager and on-demand binaries using the actual application entry. To `main`, medians were **271.2 ms eager / 230.4 ms on demand**; the paired saving was **40.7 ms median**, positive in every pair. Complete-frame medians were 830.0 / 793.6 ms, with only **14.3 ms median paired saving**. Some later phases were slower in the on-demand sample, so the loading saving must not be presented as an equally large end-to-end improvement. See [paired authentication evidence](017-lambda-cold-start/lazy-authentication-pairs.json).

A diagnostic loader observer confirmed AuthenticationServices remained unloaded through the actual application's first content display, including real stored-session restoration. This rules out simply shifting that framework load to a later point on the same first-frame path. The observer is not production timing evidence. See [loader-state checks](017-lambda-cold-start/lazy-authentication-loader.json).

A separate subsequent production five-run sample measured **928.6 ms median / 1,115.7 ms maximum**, again with five visible titles and `signedIn` throughout. It demonstrates the continuing threshold failure and variability across separately run batches; it is not compared directly with the older 763.5 ms batch to claim a causal improvement or regression. See [current production sample](017-lambda-cold-start/lazy-authentication-production.json).

The native regression was first observed failing because the old executable loaded AuthenticationServices before any sign-in request. It now verifies unloaded stored-session restoration and invalid requests, then completes a real native browser OAuth callback through a local HTTP redirect, rejects overlapping requests, cancels exactly once, and reopens successfully. The native check uses its own keychain entitlement and synthetic credentials.

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

## Remaining pre-main loading

Seven randomized interleaved rounds used identical C entry code that immediately records process-birth-to-main wall time and process CPU, then exits. No Instruments, injected library, or loader logging is present. These controls isolate loader work; they do not mount UIKit or display journals and cannot satisfy the goal.

| Linked SDK layer | Median wall time to main | Median process CPU |
| --- | ---: | ---: |
| libSystem only | 182.9 ms | 177.7 ms |
| Foundation | 186.6 ms | 181.1 ms |
| UIKit | 194.3 ms | 188.4 ms |
| SwiftUI | 193.9 ms | 189.2 ms |
| Application framework list | 227.9 ms | 222.5 ms |

The last control links the application's framework list, not its executable or every Swift overlay. Differences between these standalone medians are not additive or guaranteed removable application cost. They show that a substantial simulator loader baseline exists even before application or OCaml code executes. A separate diagnostic confirms the minimal executable has only libSystem as its eager dependency, 45 mapped images, and no injected library. See [raw layer controls](017-lambda-cold-start/sdk-loader-layers.json).

The actual application's Time Profiler samples inside `dyld4::prepareSim` split into disjoint categories: **96 ms dependency resolution, 67 ms shared-cache override patching, 36 ms initializers/runtime registration, and 30 ms other loader work**, 229 ms total sampled main-thread CPU. The initializer category includes libSystem and Objective-C image/class registration; it is not 36 ms of application static initializers. A separate minimal libSystem trace has 40 ms dependency-resolution samples and 40 ms cache-override patching samples out of 82 ms loader CPU samples. Symbolication identifies `PatchTableV2::clientsExportsForImageAndClient`, `applyCachePatchesToOverride`, `JustInTimeLoader::loadDependents`, and repeated path/install-name comparisons. These are instrumented CPU attribution, not production durations, and the two traces are not used as a causal before/after comparison.

The App Launch template also introduced a **460.7 ms synchronous dyld-monitor notification wait** inside a 646.7 ms simulator-loader interval. The main thread blocks in `RemoteNotificationResponder::sendMessage` / `notifyMonitorOfImageListChangesSim`. This recording overhead must not be classified as an application bottleneck. An additional dyld-only recording was even slower and is likewise excluded from production timing. See [pre-main attribution and safeguards](017-lambda-cold-start/premain-loader-attribution.json).

## Main-thread CPU attribution

The latest actual-entry Time Profiler recording uses main `651202c`, the fresh native core, and the production benchmark executable. Unlike the older renderer-only trace below, it includes `AppMain` and `LogseqRootView`. The key-window-to-visible-commit interval was 791.4 ms under instrumentation, with 500 ms of sampled main-thread CPU. These instrumented wall times are not production launch results. Approximately 95 ms of main-thread samples in this interval contain conformance checking; 38 ms contain mangled-type lookup, with overlap between those categories. Native row icon creation accounts for 32 ms inclusive, JSON decoding 21 ms, and text drawing 6 ms. The call stacks also show significant SwiftUI graph construction, navigation/controller creation, and system toolbar work. This supports investigating initial UI construction before row-level micro-optimizations; it does not establish a causal saving from any proposed refactor.

In the preceding trace interval, 109 ms of samples are inside `dlopen`: 63 ms originate in UIKit's system-icon scene initialization, 28 ms in accessibility initialization, and smaller amounts in localization/font loading. These are system-initiated paths, so they are not attributed to an application feature that can simply be deleted. VM-local recording: `/tmp/logseq-current-main-app-entry-20261024.trace`.

A separate native CPU-clock launch confirms that window creation and first layout are predominantly main-thread execution rather than network or disk waits. Runtime-hook diagnostics identify many separate negative `DynamicProperty` checks and generic view types; their overhead and incomplete metadata inspection make them attribution aids only. No runtime hooks or speculative metadata-prewarming code are included in the app.

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

A compiler-level control disabled concrete metadata access through mangled names in all application/UI modules and the actual-entry trampoline. Seven randomized paired rounds used immutable separate bundles, the same journal fixture, real stored-session restoration, and five visible titles. The median paired improvement was only **19.0 ms**, with three pairs slower and four faster, amid substantial drift. This does not establish a stable launch improvement. The executable grew from 27,324,336 to 27,496,096 bytes, and its protocol-conformance record section stayed at 4,928 bytes. The experimental flag was not added to application build settings. See [metadata-accessor evidence](017-lambda-cold-start/direct-metadata-accessors.json). The [Swift compiler discussion](https://forums.swift.org/t/understanding-code-that-leads-to-swift-checkgenericrequirements-calls/35128) explains that this option changes metadata access through the demangler; it does not remove every source of runtime conformance checking.

Preparing the three public root View body metatypes on a background worker before first layout did not produce a stable improvement in seven randomized same-binary pairs. The worker completed in roughly 10–20 ms, but complete-frame differences were mixed and highly variable. No views or UIKit objects were created off-main. This experiment is not retained. See [root metadata preparation](017-lambda-cold-start/root-metadata-prewarming.json).

A separate actual-entry omission control targets the application's `LGPlatformPresentationHost`, which was outside the earlier renderer-only modal-host control. It retains the complete initial journal, navigation and toolbar UI, but omits idle sheet/importer/alert registrations. Both modes use the same immutable binary and type-erasure boundary. Seven randomized paired rounds with native CPU counters produced a median wall-time improvement of **-24.9 ms** and a main-thread CPU improvement of **-2.6 ms**. This does not identify idle platform presentation registration as a major removable cost. The temporary source change was restored. See [platform-host control](017-lambda-cold-start/platform-host-control.json).

An actual-entry render-count diagnostic found 58 node-body evaluations for 58 distinct nodes before the first frame, with five native outliner row extensions and no repeated node evaluations. Two initial patch batches took only a few milliseconds to apply. This rules out a broad repeated-node-render loop in this fixture; it does not prove every SwiftUI internal attribute is evaluated only once.

The concrete navigation experiment extracts the unchanged destination surface and shares its unchanged trailing toolbar through named view/content types. Two seven-pair batches with native CPU counters had median paired wall-time savings of 117.9 and 57.6 ms, positive in 11/14 pairs, but substantial VM variation. The first seven-pair **uninstrumented** replicate produced only **12.2 ms median paired saving**, positive in 5/7 pairs. A second uninstrumented replicate overlapped an Android emulator, two Xcode builds, and core tests; its 216.6 ms median paired difference is retained as explicitly contended evidence and is not a production performance claim. No navigation refactor is retained yet. Stable uninstrumented confirmation and native navigation/toolbar/focus checks are required before adopting it. See [all navigation controls](017-lambda-cold-start/named-navigation-controls.json).

## Next optimization priorities

1. Attribute the approximately 230 ms remaining before `main` after deferring preview and interactive authentication UI. Treat standalone SDK controls as attribution aids, rather than guaranteed removable cost in the complete app.
2. Resolve which concrete navigation/control view types drive the approximately 100 ms of main-thread conformance scanning. Preserve navigation, native menus, focus, accessibility, gestures, and visual behavior while testing any smaller representation. Do not repeat the ineffective blanket type-erasure changes.
3. Investigate the icon catalog and first bitmap rendering after the larger launch costs. Preserve emoji skin variants, colored icons, font variants, appearance, and display-scale cache keys.
4. Use the actual-entry trace and node-count evidence to isolate navigation and toolbar metadata construction. Validate any structural change with immutable paired binaries and real navigation/focus checks. A renderer-only lower bound cannot satisfy the 300 ms goal.

## Validation and reproduction

After rebasing onto mobile main revision `d0f1dc98343daf6369675f6e26cf3b337a07b51d` (including PRs 78 and 79), the retained fixes passed 1,071 native core tests, 104 Swift UI tests using a direct Swift Testing app host, and native launch-cover, once-only first-frame observer, first-reveal drawer, deferred file-preview, real-graph deferred-sidebar, and host-metadata rendering checks. No XCTest or `swift test` was run. The simulator core was rebuilt from this source; its native link-input fingerprint is `724324f7030b2a07bfea700021613b72b31ceada2d36c4f77bf63022e8e80ff2`. These functional checks use dedicated cold-start bundles so unrelated simulator checks cannot replace them.

After the authentication change, all 104 Swift UI tests and the full native launch regression script, including the new browser-flow check, passed again. The OCaml core is unchanged from its 1,071-test gate. A Release build confirmed AuthenticationServices is absent from the executable's eager framework dependencies; the browser target's object has no framework autolink directives or undefined AuthenticationServices class symbols.

After the subsequent rebase onto main `651202c3fc11ff714bcaddfae4d01bc3a5e57989`, the native core was rebuilt again with link-input fingerprint `4e5bcf1282b9d0569d086ab3c5964dc869608e97e158f17c8cbdd3a24ccbb21b`. All **1,090 native core tests**, **104 Swift UI tests**, and the complete native launch regression script passed. The first-frame measurement regression and a Release macOS `LogseqModel` build also passed. Production modules were rebuilt without testability before measuring the current-main sample above.

The first-frame measurement regression was observed failing when the old probe accepted the initial blank commit (`nonempty_rows=0`). It now waits through blank and covered commits, then passes only after the test's real title is revealed. Run it with `python3 scripts/test-ios-cold-start-measurement.py`. The actual-entry driver also verifies production module flags, exact FFI exports, unchanged binary identity, synthetic-session preparation, real visible titles, and actual authentication state.

Build the production simulator app with `LOGSEQ_IOS_CONFIGURATION=release scripts/build-mobile-ios-simulator.sh`, then measure an isolated fixture:

```sh
python3 scripts/benchmark-ios-cold-start.py /path/to/isolated-documents \
  --graph-id lambda-latency --simulator SIMULATOR_UDID \
  --iterations 5 --maximum-ms 300 --minimum-rows 1 --app-entry \
  --output /tmp/logseq-cold-start-results
```

The command deliberately exits nonzero while the threshold is missed. Omit `--app-entry` only for the explicitly narrower renderer control. The actual-entry bundle rejects capture directories outside its own sandbox and never uses the production app's keychain access group. Run without concurrent builds, Instruments recording, or other simulator tests. Functional launch checks are available through `python3 scripts/test-ios-launch.py`; these build with testability, so rebuild production modules before timing.
