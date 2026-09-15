# CarPlay text layout audit

## Scope

The requested behavior is unchanged wording on one line without clipped text,
including on the smallest CarPlay displays. The production application uses
Apple-owned CarPlay templates. This audit captures the real application through
its existing application interfaces; it does not redraw screenshots or change
production strings, typography, entitlements, or template families.

## Public API boundary

Apple states that the CarPlay framework controls font size and renders the UI.
`CPPointOfInterestTemplate.title`, `CPPointOfInterest` content, `CPListItem.text`
and `detailText`, and `CPBarButton.title` accept plain strings. They expose no
font, minimum scale factor, text width, or line-count property. Consequently an
application cannot implement a shrink-to-fit fix for the result heading while
preserving the existing template and exact wording.

Sources checked on 2026-09-15:

- [CarPlay framework](https://developer.apple.com/documentation/CarPlay)
- [POI template](https://developer.apple.com/documentation/carplay/cppointofinteresttemplate)
- [POI content](https://developer.apple.com/documentation/carplay/cppointofinterest)
- [List item](https://developer.apple.com/documentation/carplay/cplistitem)
- [Simulator configurations](https://developer.apple.com/documentation/carplay/using-the-carplay-simulator)
- [Common display sizes](https://developer.apple.com/design/human-interface-guidelines/carplay)

## Resolution coverage

Simulator accepts arbitrary width, height, and scale values, rather than providing
a finite list of every supported resolution. The audit targets the documented
minimum, standard, portrait, and high-resolution configurations, plus the common
960 × 540 and 1280 × 720 displays. Actual framebuffer dimensions must be checked
against each requested configuration. A successful build or matching OCR text is
not proof of unclipped glyphs; native PNGs require visual review.

## Harness

The runner harness originates from `codex/app-explainer-website` at `b48c7fe`.
See [the established screenshot procedure](../../operations/simulator-screenshots.md).
All simulator preferences, UI interactions, and location grants apply only to a
fresh disposable GitHub runner. The local Mac and existing website directory are
not capture targets.

The hosted fixture is overlaid into a separate checkout for testing. Production
source diffs are checked before the build. Counts and power are example data;
places, route calculation, and driving distances use MapKit.

## Baseline reproduction

The existing original 800 × 480 result capture from
[run 34938078711](https://github.com/nellesf/nextStop/actions/runs/34938078711)
visibly clips the right edge of “Passende Ladestopps”. Its entire `ios` Git tree
(`9426d6d5b01b232fbf1e3883d9be98eefa12cb43`) matches the main commit
`356bf1cfa33a6ee848aef5d0143eefc86d5f07b2` from which this branch was created.
This establishes the defect in the current application, rather than a website
composition or scaling error.

No production font change is claimed. A successful capture run establishes that
the screens were reached and recorded; it does not mean the no-clipping
requirement passed.

## Planned matrix

| Configuration | Framebuffer pixels | Scale |
| --- | --- | --- |
| minimum | 748 × 456 | @2x |
| standard | 800 × 480 | @2x |
| wide-960 | 960 × 540 | @2x |
| wide-1280-2x | 1280 × 720 | @2x |
| wide-1280-3x | 1280 × 720 | @3x |
| high-resolution | 1920 × 720 | @3x |
| portrait-2x | 768 × 1024 | @2x |
| portrait-3x | 900 × 1200 | @3x |

The 1280 × 720 configuration is exercised at both supported scale factors;
this avoids treating pixel resolution alone as the complete layout configuration.
The initial scroll position is captured for each of the ten reference-flow views.

## SDK verification

The public CarPlay headers shipped with Xcode 26.6 (build 17F113) were also
inspected in [discovery run 34953004743](https://github.com/nellesf/nextStop/actions/runs/34953004743).
They confirm that the POI picker title is a plain `NSString` property and expose
no font or fitting property. That run connected a native display successfully,
but its configuration accessibility probe timed out; it is not resolution-matrix
evidence. Header hashes and the runner SDK path are retained in its artifact.
