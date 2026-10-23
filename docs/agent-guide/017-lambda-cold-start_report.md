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

## Minimal native-content controls

Seven randomized interleaved rounds compare the unchanged production app-entry binary with three standalone native-content paths, using five drawn nonempty UILabels and a conservative display callback after their commit. The minimal controls contain no graph, authentication restoration, app navigation toolbar, composer, or feature tree. They are attribution aids, not app replacements or proof of a universal platform floor. The control source is included in [minimal-content-control.swift](017-lambda-cold-start/minimal-content-control.swift); raw samples, binary identities and phases are in [minimal-content-first-frame.json](017-lambda-cold-start/minimal-content-first-frame.json).

| Path | Median process-to-display | Difference from actual app |
| --- | ---: | ---: |
| Actual Logseq AppMain / Journals | 768.3 ms | — |
| UIKit with five native labels | 359.0 ms | 409.3 ms |
| UIKit hosting a SwiftUI native-label body | 360.9 ms | 407.4 ms |
| SwiftUI App with the native-label body | 393.3 ms | 375.0 ms |

Phase medians show **276.7 ms key-window-to-content-commit in the actual app versus 12.5 ms in the minimal SwiftUI App**. Main-to-key-window is 254.1 versus 138.8 ms, and process-to-main is 228.3 versus 198.5 ms. Medians are not additive. The minimal controls explicitly require their labels' drawText callbacks, whereas the actual probe checks visible native title labels; their commit-to-display medians differ, so the end-to-end difference is not an estimate of directly removable feature cost. An Android simulator was active throughout the batch; absolute values are local to this environment. The first actual-app launch is a retained high outlier, and every endpoint still has five titles.

This shifts the largest remaining app-specific investigation to first view construction/layout, including the previously observed conformance scanning, rather than assuming graph loading accounts for the whole difference.

## Rejected asynchronous local-loading experiment

Two diagnostic batches split the actual delegate's public startup operations. The first measured 7.2 ms runtime creation, 91.8 ms local graph loading, and 30.5 ms renderer startup. A second explicitly initializes the same native core before the first RPC to separate bootstrap: runtime creation 7.8 ms, native core bootstrap 6.2 ms, graph loading 116.2 ms, and renderer startup 38.1 ms. Graph loading used only 14.6 ms of main-thread CPU in the second batch; most of its synchronous wall interval waited for the core worker. These are instrumented subphase medians under variable host load, not production launch times or additive removable savings. In particular, the 6.2 ms bootstrap does not justify prioritizing OCaml initialization over the larger graph wait and UI construction. See [delegate subphases](017-lambda-cold-start/delegate-subphases.json) and [separated native bootstrap](017-lambda-cold-start/native-bootstrap-subphases.json).

An experimental implementation moved the local catalog/configure/open-graph sequence to the existing asynchronous core API from a detached task. The main actor started it once and continued UIKit launch; the renderer still waited for the real graph result. Duplicate starts and waiters shared the same task and applied the result once. Authentication restoration also started immediately; rendering did not wait for token refresh, preserving the existing progress interface. The launch cover remained until the renderer root existed, with first-content observation armed after that handoff. **This implementation and its routine-test registrations were reverted after the final measurements failed to establish a stable first-frame improvement.**

Two native integration probes were observed failing on the synchronous implementation before the experiment, then passing on the candidate. One blocks the actual core worker and verifies that starting local loading returns before that worker is released, then checks duplicate starts/waiters and the real selected graph reaching the renderer. The other hosts the actual `LogseqRootView`, restores isolated synthetic credentials, holds the core worker, and audits Core Animation commits through the cover-to-real-journal handoff. It rejects any uncovered empty commit. The checks use a copied graph and seed a real journal row, so an empty fixture cannot pass as visible content. Passing these correctness checks does not establish faster startup.

An early implementation had a 62.8 ms median paired saving, positive in 6/7 uninstrumented pairs. It still used synchronous RPC calls on a detached worker and awaited authentication before starting the renderer; the later candidate instead suspended through the asynchronous API and preserved the progress UI. A subsequent batch was also positive in 6/7 pairs, with 160.2 ms median paired saving, but coincided with a busy Android emulator and Node process. That batch is explicitly contended and cannot establish a stable 160 ms production gain. See [early paired samples](017-lambda-cold-start/async-local-preliminary.json) and [contended candidate samples](017-lambda-cold-start/async-local-contended.json).

Final uninstrumented confirmation reversed direction: **-126.9 ms median paired saving**, positive in only 2/7 pairs. Candidate median/maximum were 1,144.2/1,823.3 ms versus 1,017.4/1,280.3 ms for the unchanged production baseline. A subsequent replicate measured +86.1 ms median paired saving, positive in 5/7 pairs, but drifted from approximately 1,000 ms to 700 ms during the batch. All comparisons preserved the negative samples, binary identities, five visible titles, signed-in authentication, and post-commit display checks. See [confirmation](017-lambda-cold-start/async-local-confirmation.json) and [replicate](017-lambda-cold-start/async-local-replicate.json). These conflicting batches do not justify retaining extra launch coordination as a proven optimization.

A separate five-pair diagnostic used the existing opt-in native CPU clocks, without Instruments or injection. Median paired main-thread CPU saving was **23.6 ms**, positive in 4/5 pairs, but total process CPU increased **32.8 ms**, increasing in every pair. The candidate reduced delegate-init wall time from 47.2 to 3.2 ms and init-end-to-key-window from 153.2 to 95.7 ms, while key-window-to-content-commit rose from 270.4 to 337.9 ms. These phase medians are not additive and this diagnostic is not production wall-time evidence. The experiment moved substantial work to the later layout interval and added process work; it did not remove the dominant UI construction cost. See [CPU phase evidence](017-lambda-cold-start/async-local-cpu.json).

An additional public Observation probe checked the actual renderer's first root assignment in three synthetic valid-session launches. All three saw `signedIn` at assignment, although authentication was still `restoring` when the window first became key. Thus a transient authentication-progress renderer is not the explanation for the extra work in this fixture. This observation-only binary is excluded from performance comparisons. The exact cause of the extra process CPU remains unproven. Native startup source was restored before the subsequent production rebuild; the next priority remains the measured first-content construction/layout path.

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

A further caller grouping of the existing actual-entry trace isolates approximately 96 ms of main-thread samples containing conformance lookup in the first-layout window. The immediate caller path through `DynamicPropertyCache.fields(of:)` and `AGTypeApplyFields2` accounts for 22 ms; mangled-type decoding appears across several other caller paths. Generic string interpolation in `NodeIconExtension.image` is also a concrete application-triggered path: its bitmap cache key interpolates the complete `NodeIconPayload` value. This is a narrower source lead, not a measured optimization. It does not explain the whole conformance cost or justify prioritizing a small cache-key change over larger view-construction paths. See [conformance caller grouping](017-lambda-cold-start/conformance-callers.json). These are instrumented CPU samples with inclusive stacks, not production durations.

Phase evidence: [profile attribution](017-lambda-cold-start/profile-phases.json). VM-local traces: `/tmp/logseq-startup-component-full.trace` and `/tmp/logseq-startup-component-no-top.trace`.

## Simulator protocol-conformance cache attribution

The largest exclusive leaf in the actual first-layout CPU sample is the Swift runtime's protocol-descriptor scan, with 82 ms of leaf samples and approximately 95 ms inclusive in conformance lookup. Counting executable symbols alone is misleading: the diagnostic executable has **1,232 registered protocol records**, but the process has **108,905 mapped records in 245 images** by its first-content endpoint.

An after-endpoint C helper observes `dyld_shared_cache_some_image_overridden() == true` in the actual AppMain launch, the three minimal-content controls, and standalone SDK-layer controls. It uses a dedicated executable with no interposer or injected library. The private dyld query runs only in diagnostic binaries at exit and is not added to application sources. [Raw cache/section evidence](017-lambda-cold-start/protocol-cache-diagnostics.json) and the [diagnostic helper](017-lambda-cold-start/protocol-cache-control.c) are preserved for review.

[Swift 6.2's runtime source](https://github.com/swiftlang/swift/blob/swift-6.2-RELEASE/stdlib/public/runtime/ProtocolConformance.cpp#L790-L843) explains the consequence: when any shared-cache image is overridden, registering protocol sections must include shared-cache images instead of excluding them in favor of prebuilt tables. Its subsequent lookup slow path scans the registered sections after cache lookup fails. This observed condition and the profiler's descriptor-scan stack explain the broad scan candidate set. Mapped totals do not prove every lookup visits every record; they are not per-query scan counters.

All three minimal-content lifecycle paths load **106,058 records in 237 images** by their first display. The actual application's additional 2,847 records include its own executable and Photos/AV overlays. SDK-only entry controls stop before UIKit creates a scene and have 68,700 records with SwiftUI or 83,945 with the application framework list. This establishes substantial system loading after main even in the minimal interface. The actual-app trace locates 63 ms inclusive dlopen samples in UIKit scene icon-appearance setup and 28 ms in accessibility initialization; these are system paths, not proof of an app feature that can be removed.

The actionable implication is to reduce avoidable application-triggered construction and distinct cold view/type lookups while preserving behavior. Removing a few application Codable conformances cannot remove most of the process's candidate records. No private runtime override, debug cache flag, interposition, or speculative prewarming is retained.

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
- Erasing the immutable wire-node kind's surface dispatch to `AnyView`, while preserving every modifier and callback, produced a **-5.5 ms median paired saving** in seven uninstrumented rounds. It was reverted; the original LUI source was restored before the asynchronous-loading production build. See [surface dispatch comparison](017-lambda-cold-start/node-surface-comparison.json).
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

A subsequent surface-style omission keeps sizing, padding, margins, graph data and native controls while skipping generic surface foreground/background/shadow/border/clip modifiers. The styled and unstyled modes share one immutable binary and a common AnyView boundary. Seven randomized three-way rounds also retain a separate production control. Styled-minus-unstyled paired savings have a median of 84.1 ms but are positive in only 4/7 rounds, with large reversals; production-minus-styled extraction savings have a median of only 3.7 ms. The second half overlaps two Android emulators and a Java build/test process, and absolute times drift substantially. No stable removable style cost or extraction gain is established. All temporary source is restored. See [surface omission evidence](017-lambda-cold-start/surface-visual-control.json).

## Next optimization priorities

1. Prioritize the approximately 277 ms actual-app window-to-content-commit phase, compared with 13 ms for the minimal SwiftUI content control. Attribute concrete construction/layout paths while preserving the complete app UI. The minimal control is not a smaller substitute for the goal.
2. Resolve which concrete navigation/control view types drive the approximately 100 ms of main-thread conformance scanning. Preserve navigation, native menus, focus, accessibility, gestures, and visual behavior while testing any smaller representation. Do not repeat the ineffective blanket type-erasure changes.
3. Investigate the icon catalog and first bitmap rendering after the larger launch costs. Preserve emoji skin variants, colored icons, font variants, appearance, and display-scale cache keys.
4. Use the actual-entry trace and node-count evidence to isolate navigation and toolbar metadata construction. Validate any structural change with immutable paired binaries and real navigation/focus checks. A renderer-only lower bound cannot satisfy the 300 ms goal.

## Validation and reproduction

After rebasing onto mobile main revision `d0f1dc98343daf6369675f6e26cf3b337a07b51d` (including PRs 78 and 79), the retained fixes passed 1,071 native core tests, 104 Swift UI tests using a direct Swift Testing app host, and native launch-cover, once-only first-frame observer, first-reveal drawer, deferred file-preview, real-graph deferred-sidebar, and host-metadata rendering checks. No XCTest or `swift test` was run. The simulator core was rebuilt from this source; its native link-input fingerprint is `724324f7030b2a07bfea700021613b72b31ceada2d36c4f77bf63022e8e80ff2`. These functional checks use dedicated cold-start bundles so unrelated simulator checks cannot replace them.

After the authentication change, all 104 Swift UI tests and the full native launch regression script, including the new browser-flow check, passed again. The OCaml core is unchanged from its 1,071-test gate. A Release build confirmed AuthenticationServices is absent from the executable's eager framework dependencies; the browser target's object has no framework autolink directives or undefined AuthenticationServices class symbols.

After the subsequent rebase onto main `651202c3fc11ff714bcaddfae4d01bc3a5e57989`, the native core was rebuilt again with link-input fingerprint `4e5bcf1282b9d0569d086ab3c5964dc869608e97e158f17c8cbdd3a24ccbb21b`. All **1,090 native core tests**, **104 Swift UI tests**, and the complete native launch regression script passed. The first-frame measurement regression and a Release macOS `LogseqModel` build also passed. Production modules were rebuilt without testability before measuring the current-main sample above.

The subsequently rejected asynchronous-local-loading candidate passed all **104 Swift UI tests** and all **nine native launch checks**, including the two experimental blocked-worker/content-handoff probes. The first-graph check reached only the saved self-hosted HTTP endpoint, and the first-frame measurement regression passed again. An initial attempt stopped at a simulator launch-console FIFO `File exists` error after the UI tests; the subsequent complete run passed. Functional success did not override the conflicting performance evidence. The candidate, its benchmark adaptation, and its new routine-test registrations were restored to the previously validated production source. No core or LUI implementation changed in this step.

After restoring source, a fresh production Release build passed again and the benchmark's module-flag validator confirmed optimization without testability. The pinned LUI source checksum remained `7c5753ae0f9d0f27f259adcffad391b9b6e0b9f38f95044f4be87dbcc5fa4e20`, matching the original source used by the production control. Remote main was rechecked at `651202c`; no functional implementation from this rejected experiment remains.

The first-frame measurement regression was observed failing when the old probe accepted the initial blank commit (`nonempty_rows=0`). It now waits through blank and covered commits, then passes only after the test's real title is revealed. Run it with `python3 scripts/test-ios-cold-start-measurement.py`. The actual-entry driver also verifies production module flags, exact FFI exports, unchanged binary identity, synthetic-session preparation, real visible titles, and actual authentication state.

Build the production simulator app with `LOGSEQ_IOS_CONFIGURATION=release scripts/build-mobile-ios-simulator.sh`, then measure an isolated fixture:

```sh
python3 scripts/benchmark-ios-cold-start.py /path/to/isolated-documents \
  --graph-id lambda-latency --simulator SIMULATOR_UDID \
  --iterations 5 --maximum-ms 300 --minimum-rows 1 --app-entry \
  --output /tmp/logseq-cold-start-results
```

The command deliberately exits nonzero while the threshold is missed. Omit `--app-entry` only for the explicitly narrower renderer control. The actual-entry bundle rejects capture directories outside its own sandbox and never uses the production app's keychain access group. Run without concurrent builds, Instruments recording, or other simulator tests. Functional launch checks are available through `python3 scripts/test-ios-launch.py`; these build with testability, so rebuild production modules before timing.
