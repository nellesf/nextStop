# Native CarPlay capture evidence

Capture integrity and hosted-test success do not establish unclipped text. OCR may reconstruct clipped words or miss offscreen content. Every original PNG requires visual review; these are reference-flow captures.

Run: [GitHub Actions](https://github.com/nellesf/nextStop/actions/runs/34964912072).
App: `200e13d9bb151c88e9786cf96c5690f2ee733d19`. Harness: `3141c8f0d271caa18b1770de9bee97a7ee238447`.

Verified capture sets: **1/8**. The planned matrix is incomplete.

| Configuration | Pixels | Scale | Evidence |
| --- | --- | --- | --- |
| minimum | 748 × 456 | @2x | absent |
| standard | 800 × 480 | @2x | absent |
| wide-960 | 960 × 540 | @2x | absent |
| wide-1280-2x | 1280 × 720 | @2x | absent |
| wide-1280-3x | 1280 × 720 | @3x | absent |
| high-resolution | 1920 × 720 | @3x | absent |
| portrait-2x | 768 × 1024 | @2x | absent |
| portrait-3x | 900 × 1200 | @3x | [Gallery](#portrait-3x) · [Manifest](portrait-3x/layout-capture-source.json) |

## portrait-3x

[Profiles](portrait-3x/carplay-profiles.png) · [Ride summary](portrait-3x/carplay-ride-summary.png) · [Criteria](portrait-3x/carplay-criteria.png) · [Distance options](portrait-3x/carplay-options-distance-range.png) · [Charging-point options](portrait-3x/carplay-options-charging-points.png) · [Power options](portrait-3x/carplay-options-power.png) · [Restaurant options](portrait-3x/carplay-options-food-chain.png) · [Results](portrait-3x/carplay-results.png) · [Result actions](portrait-3x/carplay-result-actions.png) · [Operator selection](portrait-3x/carplay-charging-places.png)

[Hosted test summary](portrait-3x/profile-test-summary.json) · [Preflight](portrait-3x/preflight.json). OCR JSON files sit beside their original PNGs.
