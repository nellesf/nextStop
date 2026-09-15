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
