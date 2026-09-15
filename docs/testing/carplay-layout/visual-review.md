# Native CarPlay text review

## Outcome

The requested guarantee is **not met**. The current application's native
CarPlay templates clip, truncate, or wrap text on several configurations.
Production source and localization resources are unchanged. No font-size fix,
new line break, or rewording was introduced.

The public API limitation and official references are in [the audit](README.md#public-api-boundary).
Apple owns these templates' typography. A supported application-side shrink-to-fit
implementation is unavailable for the affected fields with the existing template
and exact wording.

## Evidence

**All eight selected display configurations have ten complete native captures
each (80 images), with visual review separate from capture-test success.**
The source app still fails the requested text-fitting guarantee.

Seven configurations use [run 34959786544](https://github.com/nellesf/nextStop/actions/runs/34959786544),
source commit `5f62cd904db3deb8d9677fc7e1b881ad9551ff2a`, Xcode 26.6,
iOS 26.5, and a fresh iPhone 17 Pro simulator for each display configuration.
The remaining 900 × 1200 @3x case uses
[run 34964912072](https://github.com/nellesf/nextStop/actions/runs/34964912072),
harness `3141c8f0d271caa18b1770de9bee97a7ee238447`, and app commit
`200e13d9bb151c88e9786cf96c5690f2ee733d19`, with the same Xcode/iOS versions.
It reuses the verified build from `34962890365` after capture-only corrections.
Each run's original provenance remains separate; no failed attempt is relabelled.
The app's entire `ios` tree is `9426d6d5b01b232fbf1e3883d9be98eefa12cb43`,
identical to main at branch creation (`356bf1c`).

Each admitted configuration has ten original native PNGs, verified SHA-256 hashes,
exact framebuffer dimensions, the verified runtime scale, and a hosted test with
one pass, zero failures, and zero skips. Capture success establishes that the
reference screens were reached; it is separate from the visual result below.

[Seven-configuration capture index](captures/README.md) ·
[Supplemental portrait capture](supplemental/README.md).
The per-run indexes intentionally show seven and one configurations, respectively;
together they cover the eight-case selection.

## Visual findings

All ten original images were inspected at native resolution for each reviewed
configuration. “Fits” below refers only to the visible text in these reference
screens, not every possible string or application state.

| Display | Result heading | Result-action prompt | Other findings |
| --- | --- | --- | --- |
| [748 × 456 @2x](captures/minimum) | Hard-clipped at right edge | Ellipsized: “Wohin möchtest du fa…” | Criteria title “Filter für diese Fa…”; EDEKA provider name wraps to two lines; detail summary absent |
| [800 × 480 @2x](captures/standard) | Hard-clipped at right edge | Ellipsized: “Wohin möchtest du fahr…” | Other visible labels fit; detail summary absent; also reproduced in the [separate baseline](baseline-800x480/README.md) |
| [960 × 540 @2x](captures/wide-960) | Fits | Fits | Other visible labels fit; detail summary absent |
| [1280 × 720 @2x](captures/wide-1280-2x) | Fits | Fits | Other visible labels fit; detail summary absent |
| [1280 × 720 @3x](captures/wide-1280-3x) | Fits | Fits | Other visible labels fit; detail summary absent |
| [1920 × 720 @3x](captures/high-resolution) | Fits | Fits | Other visible labels fit; detail summary absent |
| [768 × 1024 @2x](captures/portrait-2x) | Hard-clipped at right edge | Wraps to two lines | Summary is present; count wraps to two lines and EDEKA operator/count entry to three; other visible labels fit |
| [900 × 1200 @3x](supplemental/portrait-3x) | Hard-clipped at right edge | Wraps to two lines | Profile title “Fahrt wähl…” and criteria title “Filter für dies…”; EDEKA name wraps; both provider subtitles ellipsized; detail summary absent |

The result heading is “Passende Ladestopps” in every configuration. The detail
prompt is “Wohin möchtest du fahren?”. In all six landscape configurations and
the 900 × 1200 @3x portrait case,
the expected detail summary (distance, matching EVSE count, operator counts, and
power) is absent, despite those values being passed to the native template. This
is missing content, not evidence of intact single-line text.

The existing production detail summary intentionally joins separate facts with
newlines. The portrait findings identify additional wrapping inside individual
facts and the prompt. Rows partly or completely outside a scrollable list's
viewport are recorded as normal scrolling, not horizontal clipping. Dimmed ride
summary text is visible even where OCR misses it. Conversely, OCR can recognize
the complete result heading while its final glyphs are visibly cut off.

## Scope limits

- One German, light-mode reference journey with a fixed Leipzig/McDonald's
  profile and criteria; only the first result's detail and operator views.
- Initial scroll positions; no exhaustive checks of later rows, other results,
  operator pagination, favorites, or recents.
- Loading, empty/no-results, errors, alerts, the restaurant-free flow, availability
  variants, degraded/stale coverage, and attribution content are outside this
  capture fixture.
- Arbitrarily long user/provider strings, other iOS releases, and physical
  CarPlay devices remain unverified.
- Simulator accepts arbitrary dimensions. These eight selected configurations
  use documented/common sizes plus additional scale and portrait cases
  (including 900 × 1200 @3x); they do not cover every possible resolution.

These limits prevent a universal “text never clips or wraps” claim even on a
configuration where the captured visible labels fit.

## Capture recovery evidence

The 900 × 1200 @3x case required capture-helper corrections. Its two failed
attempts remain [explicitly incomplete diagnostics](failed-portrait-3x/README.md).
The successful final run used one native app-icon click, then confirmed two
profile frames at 62.6 and 66.9 seconds after activation polling began. Its
guarded second-click path was not needed in that run. The
[original activation log](supplemental/verification/root-activation.json) and
[build-reuse provenance](supplemental/verification/reused-build-source.json)
are retained with [source hashes](supplemental/verification/source.json).
