# Mobile feedback regression evidence

This batch covers the Android feedback screenshots and [db-test#1466](https://github.com/logseq/db-test/issues/1466). Sync disconnects (item 6) and block selection are outside the requested scope.

## Method

The normal baseline is `250a098`. Both phases use the same canonical graph, real OCaml session, native renderer and native asset loader. The fixture generator is `shared/src/logseq/entry/logseq_feedback_fixture.ml`. Each video has adjacent test observations/logs and in-app screenshots. Android recordings run on a dedicated Android 16 emulator; iOS recordings run on a dedicated iOS 26 simulator.

Camera and file-picker completion use a deterministic generated image because the iOS simulator has no camera. Opening the real toolbar, saving the draft, importing the file into the graph, projecting the asset, and rendering its preview use production code. The graph API points at an unreachable local endpoint for these cases. The after checks require the imported file to exist, the preview to appear, and `prepareAssetDownload` to return that file without a remote request. Upload completion is not a prerequisite for insertion or preview.

Language checks inject the same `systemLanguage: zh-CN` host signal sent by the production platform adapter; they do not change the simulator operating system language. Responsiveness checks use a real HTTP server that delays `/graphs` for five seconds, and assert that Settings opens before the request completes. Platform animations are included in measured UI latency.

Two very short static baseline clips hold the recorded frame for readability; no interactions are synthesized.

The LaTeX fixture uses the production rich-content views with inline formulas, display equations, underbraces, text annotations, fractions and roots. The iOS after check inspects the actual WKWebView DOM in addition to the video, including vertical clipping.

A before-phase pass means the reproduction flow completed, with the baseline defect still visible. After-phase runs require the corresponding regression assertions to pass.

## Paired recordings

| Problem | Android before / after | iOS before / after | Platform finding |
| --- | --- | --- | --- |
| Previous page remains visible after following references | [before](before/navigation.mp4) / [after](after/navigation.mp4) | [before](before/ios-navigation.mp4) / [after](after/ios-navigation.mp4) | Android regression; iOS navigation also checked |
| Public built-in tags missing from search | [before](before/search-tags.mp4) / [after](after/search-tags.mp4) | [before](before/ios-search-tags.mp4) / [after](after/ios-search-tags.mp4) | Shared |
| Bare YouTube URL does not become a player | [before](before/youtube.mp4) / [after](after/youtube.mp4) | [before](before/ios-youtube.mp4) / [after](after/ios-youtube.mp4) | Shared |
| No following-block entry while editing a final code/math block | [before](before/special-block.mp4) / [after](after/special-block.mp4) | [before](before/ios-special-block.mp4) / [after](after/ios-special-block.mp4) | Shared |
| Code language picker missing | [before](before/code-language.mp4) / [after](after/code-language.mp4) | [before](before/ios-code-language.mp4) / [after](after/ios-code-language.mp4) | Shared |
| Slow graph catalog blocks Settings | [before](before/responsiveness.mp4) / [after](after/responsiveness.mp4) | [before](before/ios-responsiveness.mp4) / [after](after/ios-responsiveness.mp4) | Shared |
| Comments look like ordinary blocks | [before](before/comments.mp4) / [after](after/comments.mp4) | [before](before/ios-comments.mp4) / [after](after/ios-comments.mp4) | Shared |
| Existing emoji reaction counts missing | [before](before/reactions.mp4) / [after](after/reactions.mp4) | [before](before/ios-reactions.mp4) / [after](after/ios-reactions.mp4) | Shared; this adds display of existing reactions |
| Image import does not finish editing / show immediately | [before](before/attachment-refresh.mp4) / [after](after/attachment-refresh.mp4) | [before](before/ios-attachment-refresh.mp4) / [after](after/ios-attachment-refresh.mp4) | Shared; offline import checked |
| Image import creates an empty parent block | [before](before/image-parent.mp4) / [after](after/image-parent.mp4) | [before](before/ios-image-parent.mp4) / [after](after/ios-image-parent.mp4) | Shared; Android file attachment entry checked |
| First image preview requests a download / shows Retry | [before](before/image-retry.mp4) / [after](after/image-retry.mp4) | [before](before/ios-image-retry.mp4) / [after](after/ios-image-retry.mp4) | Original intermittent Retry is not claimed as reliably reproduced; local preview is now explicitly checked |
| Android controls use iOS-style rounded surfaces | [before](before/android-controls.mp4) / [after](after/android-controls.mp4) | [before](before/ios-android-controls.mp4) / [after](after/ios-android-controls.mp4) | Android adaptation; iOS editor checked |
| Search field overlaps editing controls in a result | [before](before/search-toolbar.mp4) / [after](after/search-toolbar.mp4) | [before](before/ios-search-toolbar.mp4) / [after](after/ios-search-toolbar.mp4) | Android; iOS native search also checked |
| System language remains English on a Chinese system | [before](before/language.mp4) / [after](after/language.mp4) | [before](before/ios-language.mp4) / [after](after/ios-language.mp4) | Shared |
| Inline math breaks sentences / annotated formulas fail (#1466) | [before](before/math.mp4) / [after](after/math.mp4) | [before](before/ios-latex-1466.mp4) / [after](after/ios-latex-1466.mp4) | Inline layout shared; iOS renderer replaced with bundled offline KaTeX |

## Validation

- Full native core gate: 1,133 passed. After the final localization and Android layout adjustments, the focused regression suites passed 11 tests and the app suite passed 239 tests. Logs are in [validation/](validation/).
- Swift UI suites, run directly with Swift Testing: 107 passed across 12 suites. No XCTest runner was used.
- Android JVM suites: 66 passed, zero failures/errors/skips. Native Android and iOS simulator builds succeeded.
- Final paired evidence: 15 Android scenarios and 16 iOS scenarios in each phase, with 62 playable videos. [verification.json](verification.json) records per-scenario results; iOS navigation and visual styling were also inspected in the recordings.
- With a five-second catalog delay, Settings opened in 5,303 ms before and 843 ms after on Android. The after request was still pending when Settings appeared. iOS measured 6,307 ms before and 1,266 ms after. These include platform animation and instrumentation overhead.

## Fix commits

- [2d317de](https://github.com/logseq/mobile/commit/2d317de60645a0bac4bc6e24912da8ed9115d5ca) — Fix Android navigation showing previous page contents
- [c161f76](https://github.com/logseq/mobile/commit/c161f76b103125e1ed92dea9a660b967fe63b71d) — Include public built-in tags in graph search
- [dbe8880](https://github.com/logseq/mobile/commit/dbe8880db15fcc45fad89a97ea9eaa5417f9f41a) — Render bare YouTube links as embedded video players
- [8ed957f](https://github.com/logseq/mobile/commit/8ed957f2e64689c6dbd0c61e85e6963cdf77d8ac) — Keep the next-block entry available while editing math and code
- [7b86dba](https://github.com/logseq/mobile/commit/7b86dbab10574b392c19f381345ff53849940c10) — Add a language picker for code blocks on both mobile clients
- [32e9c3c](https://github.com/logseq/mobile/commit/32e9c3cfcf44edb84d4a23ed7584007c2d44dce3) — Keep mobile controls responsive during graph catalog requests
- [d8eabba](https://github.com/logseq/mobile/commit/d8eabba35a9e7c9ced1b9a1a4720daec85650a19) — Distinguish comment threads from ordinary blocks
- [19aacf4](https://github.com/logseq/mobile/commit/19aacf480bf43e3550f2cf3bfabfb0911bc9aa1c) — Display existing emoji reaction counts on mobile
- [a50b08f](https://github.com/logseq/mobile/commit/a50b08f3f0d38cc8666bd072fdf744780936ecf5) — Finish editing before presenting image capture or attachments
- [816988d](https://github.com/logseq/mobile/commit/816988dba3900aab43c142d9cee857b15a46640e) — Reuse empty image insertion targets without blank parent blocks
- [9546cc2](https://github.com/logseq/mobile/commit/9546cc2321639cdef581e5c9bc0fd1ce801a32a2) — Use Android control shapes and keep keyboard dismissal reachable
- [ccd8d48](https://github.com/logseq/mobile/commit/ccd8d48de53340720eda29e490d5264d4c486f59) — Separate search input from editing a search result on Android
- [a7c5789](https://github.com/logseq/mobile/commit/a7c57890a34f7b9695c52f56b2e6febed7a55c2d) — Translate shared mobile controls and follow the system language
- [86cf984](https://github.com/logseq/mobile/commit/86cf984a0781deb68d4a43c17c8835663803a282) — Keep imported asset previews local while offline
- [90d2db7](https://github.com/logseq/mobile/commit/90d2db7b43dfd2f103666047bc5d87b7c1295e2b) — Render inline math within paragraphs and support annotated iOS equations

## Re-running

Build each platform as described in the repository README, then run:

```sh
ANDROID_SERIAL=<dedicated-emulator> python3 scripts/record-android-feedback.py after <scenario...>
python3 scripts/record-ios-feedback.py after <dedicated-simulator-UDID> <scenario...>
```

The before recorder accepts `before`; iOS also accepts `--build-root` pointing at an independently built baseline checkout. Use the current recording harness against each build. The scripts operate only on their QA app/graph; select an isolated device and do not point them at personal data.
