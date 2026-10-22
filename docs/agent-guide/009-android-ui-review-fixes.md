# Android UI Review Fixes

Goal: Resolve UX-01, UX-02 and UX-03, adapt Settings and Sync status to Android, and use the Logseq theme for links and action buttons.

Scope: Preserve Apple rendering, layout and interaction. UX-04 is withdrawn as a device defect: the user verified that the iOS device retains its keyboard for both composer menus. Simulator evidence is not representative of that device behavior. Do not resume performance optimization or change concurrent search work.

## Validation plan

- [x] Write all behavior regressions first: normal/rich/quote long press, short tap and reference navigation, collapsed capture width/background/hit target, initial graph sheet actions, settings title/trailing switches, sync error scrolling/actions, and light/dark link/action colors.
- [x] Run the new tests before implementation and record genuine behavior failures.
- [x] Fix native Android layout and gesture ownership locally. Reuse Material components and existing events; do not add a second rendering or theme system.
- [x] Run focused tests, then relevant existing Android regressions and the serialized OCaml core gate if shared view code changes.
- [ ] Rebuild native core, install in the dedicated Android emulator and verify real entry paths, keyboard behavior and screenshots. Do not modify phone data.
- [ ] Commit separate coherent changes, push the authorized main branches, update the review status and mobile report with fresh evidence.

## Implementation boundaries

LUI Android fixes live under `duniverse/lui/platform/android/lui`. Keep its independent repository commit and update the application pin after its main push. Application view changes are restricted to KotlinHost branches; Android native code owns rich text and theme use. Run no swift test and edit no Dune files.

## Verification log

- RED: 39 installed tests executed; 20 expected failures reproduced the reviewed interaction/layout/color defects. One invalid link-variant fixture was corrected to use the supported text-button variant and independently observed failing on scoped color behavior.
- GREEN: all 39 focused installed tests pass in 48.288 seconds, including long press, accessibility editing, native sheet actions, capture hit regions and theme colors.
- Core gate: 901 tests pass in 43.960 seconds. The old Android settings assertions were updated for the requested flat native preferences and content-sized actions; Apple branches are unchanged.
- LUI and Android JVM tests pass; broad installed regressions and real entry screenshots are next.
- Additional user scope: reproduce and optimize repeated Enter insertion near the start of a 500-block Android page, with actual input timing and a separate change. iOS layout/styles must remain unchanged.

- Final focused run: 51 installed component/renderer regressions pass, including two new trailing-action layout assertions discovered during screenshot review. The opt-in IME cases are executed separately with verifyComposerIme=true.
- Existing broad installed regression run: 61 pass. Shared core: 902 pass in 42.402 seconds. Android JVM: 64 pass; LUI JVM: 29 pass.
- Actual app entry checks: rich-body long press reaches selection and unselect works; the 55%/92% Capture area opens the composer and outside touch dismisses it. Settings title, trailing switches and full-width server input were visually reviewed. Final Graph/Sync screenshots and report publication remain.
- LUI UI/layout commit d09197cbc70a986f4c0b6f43e37f7d6628d9f395 is pushed to main. Android editor reuse is a separate performance change.
