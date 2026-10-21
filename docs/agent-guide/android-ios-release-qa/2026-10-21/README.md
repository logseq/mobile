# Evidence for Android / iOS release QA — 2026-10-21

Revision: `5db32d18`; app version: `2.0.2`.

- `android-demo.mp4`: unedited Android `screenrecord` output, H.264, 1080×2400, 101.07 seconds, no audio. Profile variant.
- `android-rich-content.png`: first frame extracted from the native recording.
- `ios-rich-content.png`: production iOS renderer and core in the repository's offline UI test host, same 8-journal fixture. Authentication and platform presenters are not exercised by this host.
- `android-performance.json`, `launch-*.log`, `scroll-*-gfxinfo.txt`: profile variant, initial rich-content workload. Host compilation activity overlapped parts of this exploratory sample; these are diagnostic samples, not release acceptance measurements.
- `scroll-rich.perfetto-trace`, `scroll-rich-trace-summary.csv`, `scroll-rich-cpu.csv`: 15-second Android system trace of rich-content scrolling; nested trace durations overlap and must not be added.
- `release-system-anr-invalid/`: excluded scrolling samples. A system ANR dialog intercepted gestures; zero rendered frames does not mean smooth scrolling. Launch callbacks were recorded while the dialog was present and are not end-to-end readiness results.
- `ios-navigation-*.log`: attempted UI automation. A screenshot path was rejected by Maestro; a later Settings assertion failed in the isolated host. Neither establishes an iOS shipping-app regression.
- `measure-android.py`: reproducible exploratory measurement driver. Confirm the foreground screen and absence of system dialogs before running. It does not automatically validate screen state.

Fixture creation uses the existing `logseq_e2e_seed.exe --fixture` / `--performance=100x8`. Android migrates the graph to `files/graphs/UI_Regression-uiregression`; replacing the legacy `files/graphs/uiregression` after migration does not change the active graph. An exploratory attempt against the legacy path was excluded.

Trace analysis follows [Perfetto trace analysis](https://perfetto.dev/docs/quickstart/trace-analysis) and uses `trace_processor query`. Emulator frame timing does not establish Redmi device timing.

- `release-100x8/`: post-reboot Release samples using the canonical active graph directory; 100 journals × 8 blocks, without WebViews. Includes frame statistics, memory, screenshots, and a separate 12-second system trace. Startup samples remain affected by OS/host load and are not treated as normal launch acceptance measurements.

Rerun after installing the desired variant and preparing the active graph:

```sh
rtk proxy python3 docs/agent-guide/android-ios-release-qa/2026-10-21/measure-android.py --device emulator-5554 --variant release --runs 3 --output /tmp/logseq-qa-rerun
```

The script now rejects scrolling samples with zero App frames; this is a basic validity check, not proof that every gesture reached the intended list. Inspect the foreground screen as well.
