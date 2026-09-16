# Standard-display baseline review

[Native capture run 34953971279](https://github.com/nellesf/nextStop/actions/runs/34953971279)
reached all ten reference-flow screens on iOS 26.5 with Xcode 26.6. One hosted test
passed, with no failures or skips. All ten original PNG dimensions and SHA-256
hashes were verified before copying; no pixels were changed.

This is the separately preserved **800 × 480 baseline**, not a completed display
matrix. The exact run, source commit, timestamps and configuration are retained
in the original manifests. The current application production source has not
changed since this capture.

## Visual result

All ten PNGs were inspected at native resolution.

- **Fail — result heading:** the right edge of “Passende Ladestopps” is visibly
  clipped. OCR nevertheless recognizes the full string.
- **Fail — selected-result prompt:** “Wohin möchtest du fahren?” appears as
  “Wohin möchtest du fahr…”.
- The other eight initial views show no horizontal text clipping in this fixture.
  Rows outside a scrollable viewport are not evidence of horizontal clipping,
  and arbitrary user/provider text is not exhaustively covered.

The system owns both affected labels' font and truncation. No production font
fix or passing no-clipping result is claimed.

## Original images

- [carplay-profiles.png](carplay-profiles.png)
- [carplay-ride-summary.png](carplay-ride-summary.png)
- [carplay-criteria.png](carplay-criteria.png)
- [carplay-options-distance-range.png](carplay-options-distance-range.png)
- [carplay-options-charging-points.png](carplay-options-charging-points.png)
- [carplay-options-power.png](carplay-options-power.png)
- [carplay-options-food-chain.png](carplay-options-food-chain.png)
- [carplay-results.png](carplay-results.png)
- [carplay-result-actions.png](carplay-result-actions.png)
- [carplay-charging-places.png](carplay-charging-places.png)
