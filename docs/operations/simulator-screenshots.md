# Simulator screenshots

Use the existing GitHub macOS runner harness for native iPhone and CarPlay
screenshots. Do not recreate the UI or restart the simulator investigation.
This guide is available on `main`; the workflow, scripts, test fixture, website,
and importers live on **`codex/app-explainer-website`**.

## Start here

The current app source is pinned to
`5fe2fa2332d66d2499fc679617855d41cb0111be` (version 0.1.0, build 1).
The harness checks out that commit separately as `screenshot-app`, overlays only
`ios/NextStopAppTests/ProfileRepositoryTests.swift`, and verifies that the app,
core, CarPlay, Xcode project, and configuration have no production changes.
Do not change those sources or entitlements to make a screenshot work.

Dispatch works from any checkout with authenticated `gh`; no local Xcode is
needed. This command reuses the verified build and runs the result capture:

```bash
gh workflow run carplay-screenshots.yml --repo nellesf/nextStop \
  --ref codex/app-explainer-website \
  -f capture_mode=results \
  -f reuse_run_id=34928718397 \
  -f reuse_sha256=febc9e8ac73e8b361eebfc353825de13a4c732a65f446a6b9bf72a3a211d093c
gh run list --repo nellesf/nextStop --workflow carplay-screenshots.yml \
  --branch codex/app-explainer-website --limit 5
```

Use `capture_mode=profiles` for the two CarPlay profile/preparation images.
To build afresh, omit **both** reuse inputs. Artifacts expire after seven days;
the historical reuse command stops working after expiry. Reuse also requires
the same pinned app commit/tree and the exact current hosted-test source hash.
Python or workflow fixes can reuse a build; changing the Swift fixture or app
revision requires a fresh build. The script checks all these hashes.
For a request for the latest `main`, fetch first and compare the actual iOS tree:

```bash
git fetch origin
git rev-parse origin/main:ios
git rev-parse 5fe2fa2332d66d2499fc679617855d41cb0111be:ios
```

Documentation-only commits do not change that app tree. If the trees match,
the existing build represents the same app source; retain its real capture
commit in provenance. If the app tree changed, update the pin in both workflow
and `capture.sh`, build afresh, and pass the new full app SHA to the importer.
Never relabel an old build or image with a newer commit.

For imports or harness edits, first run `git worktree list` and use an existing
website-branch worktree. Otherwise create an isolated worktree:

```bash
git fetch origin
git worktree add /tmp/nextstop-screenshots codex/app-explainer-website
```

Do not switch a dirty checkout or overwrite an untracked `website/` directory.
The workflow runs the **pushed** website branch; local edits do not affect it.
Its concurrency group cancels an older run on the same branch, so dispatch one
intentional run at a time. Commit and push authorized changes as required by
the repository instructions.

## Verified status and evidence

Status recorded on **2026-09-15**; inspect the linked run before treating a later
attempt as successful.

| Run | What is established |
| --- | --- |
| [34880309048](https://github.com/nellesf/nextStop/actions/runs/34880309048) | Successful CarPlay profile/preparation capture and passing hosted test. |
| [34928718397](https://github.com/nellesf/nextStop/actions/runs/34928718397) | Verified reusable result-test build; capture failed. Archive SHA-256 is in the quick start. |
| [34932855914](https://github.com/nellesf/nextStop/actions/runs/34932855914) | Four native nextStop images reached: CarPlay results, result actions, charging-provider list, and iPhone results. The full eight-image set did **not** finish. |
| [34933714967](https://github.com/nellesf/nextStop/actions/runs/34933714967) | Maps location and notification introductions were handled; capture then stopped at the Maps advertising introduction. |
| [34936034192](https://github.com/nellesf/nextStop/actions/runs/34936034192) | Attempt using harness `fae083f`, with the observed Maps introductions, 180-second bootstrap installation, and retried container discovery. Full success is **not yet verified**. |

After a complete run, update this table with its run/attempt, harness commit,
archive hash, and visual-review result. A build, partial PNGs, or a green unrelated
test do not establish that all requested screens were captured.

## Download, inspect, and import

The `carplay-captures` artifact contains original PNGs, provenance, fixture
evidence, and diagnostics. On a rerun, downloading by name can select an older
attempt's artifact. Resolve the newest non-expired artifact ID instead:

```bash
capture_run=34936034192 # Replace with the run being reviewed.
capture_artifact_id=$(gh api \
  "repos/nellesf/nextStop/actions/runs/${capture_run}/artifacts?per_page=100" \
  --jq '[.artifacts[] | select(.name == "carplay-captures" and .expired == false)] | max_by([.created_at, .id]) | .id')
gh api "repos/nellesf/nextStop/actions/artifacts/${capture_artifact_id}/zip" \
  > /tmp/nextstop-carplay-captures.zip
unzip /tmp/nextstop-carplay-captures.zip -d /tmp/nextstop-capture-review
```

Use a fresh destination for each attempt. Check the selected artifact's creation
time and attempt against the run. If the ID is `null`, fetch more pages or build
again after retention expiry. Do not combine files from different attempts into
a supposedly complete manifest.

Inspect every final PNG at native resolution. Confirm the intended screen,
readable content, no permission dialog or loading overlay, and correct selected
place. OCR success does not guarantee a good composition. A partial bottom row
with native scroll controls can be normal. Prefer a readable native list position;
if the requested app revision itself clips a heading or row, record that limitation
in the review and retain the original pixels. Do not redesign the app for capture.

| Files | Owner | Native dimensions |
| --- | --- | --- |
| `carplay-profiles.png`, `carplay-ride-summary.png` | nextStop | 800 × 480 |
| `carplay-results.png`, `carplay-result-actions.png`, `carplay-charging-places.png` | nextStop | 800 × 480 |
| `carplay-restaurant-place.png`, `carplay-charging-place.png` | Apple Maps | 800 × 480 |
| `iphone-results.png` | nextStop | 1206 × 2622 |
| `iphone-restaurant-place.png`, `iphone-charging-place.png` | Apple Maps | 1206 × 2622 |

A complete result run requires all eight result/place images,
`result-capture-source.json`, and a hosted-test summary with one passed test,
zero failures, and zero skips. Run the importer from the website worktree root:

```bash
node website/scripts/import-result-screenshots.mjs \
  /tmp/nextstop-capture-review 5fe2fa2332d66d2499fc679617855d41cb0111be
```

For profile mode use `import-carplay-screenshots.mjs` with the same arguments;
it reads `capture-source.json`. The separate iPhone profile workflow is
`ios-app.yml`, `test_scope=screenshots`, with a full `app_ref`; its artifact is
`ios-ui-attachments` and importer is `website/scripts/import-screenshots.mjs`.
See the website branch's
[website README](https://github.com/nellesf/nextStop/blob/codex/app-explainer-website/website/README.md#app-screenshots).

Importers verify provenance and copy the original bytes into
`website/public/screenshots/`. Add reviewed result gallery entries to
`website/content/result-screenshots.ts`, then run `npm test` and `npm run lint`
from `website/`. Keep the PNGs and manifests in Git so later website or App Store
design work does not depend on expiring Actions artifacts. Compose marketing
layouts separately; never overwrite the originals or their hashes. Native
capture dimensions alone do not establish App Store submission suitability.

## Data and ownership

Result fixtures query real MapKit restaurant and charging-place names, Apple
place IDs, and coordinates around the public Nürnberg-to-Leipzig example route.
The unchanged app calculates routes and driving distances, applies its filters,
groups results, and resolves places. **EVSE counts and power are example values**
(8 per supplied charging place, 150 kW); availability is unknown. Display this
distinction beside the images. Grouping can show 16 example charging points;
that is not a verified capacity at the named real location.

The four place views belong to **Apple Maps**, not nextStop. Name that owner in
captions and preserve `ownerApp` in provenance. The app selects a restaurant or
charging location/provider, not an individual EVSE or connector. Never add fake
pixels, draw substitute app screens, or change production behavior for capture.

## Troubleshooting without repeating the investigation

Start with `phase-*.json`, `website-capture-state.json`, `profile-setup.log`, and
`profile-test-summary.json`. Compare `diagnostic-<phase>-*.png` with their OCR
JSON and `capture-actions.log`. `website-capture-fixture.json` records successful
MapKit queries, candidates, and any later result/place evidence. Partial fixture
metadata is useful for diagnosis; it is not complete capture provenance.

| Symptom | Established cause and working approach |
| --- | --- |
| Swift waits for the first ACK but Python sees no phase | XCTest can reinstall the app into a new data-container UUID. `results.py` re-resolves the container every 3 seconds until a state appears and rebinds state, command, and fixture paths together. A lookup timeout while installation is running is retried within the overall deadline. Reapply the app's simulator location grant after installation. |
| Profile handler completes but no ride summary appears | The root template's transition gate can still be active. Wait for two rendered `Fahrt wählen` + `Leipzig` frames before ACK. Handler completion is necessary after an accepted push, but also fires when an action is rejected early. Do not pre-click Leipzig and then invoke it a second time. |
| A result is highlighted but no destination buttons appear | `selectedIndex = 0` and the delegate callback only establish focus. The harness clicks the first observed `… km Fahrstrecke` row through the real Simulator UI. |
| Clicking an app or row has no effect | Use the observed window and OCR coordinates. The proven mouse helper moves the pointer, verifies its position, and sends down/up with click state 1. Tap the nextStop icon above its caption. System Events `click at` and caption-only taps failed. |
| Blank/delayed external display | Use the explicit Simulator from the selected Xcode, fresh device, and existing bounded preflight/reconnect logic. `caffeinate -diu` keeps the disposable runner session awake. Do not infer readiness from successful menu opening alone. |
| First-boot status-bar command times out | A transient first-boot failure has occurred before app testing. Inspect preflight logs and rerun once; do not change app code for it. |
| Bootstrap `simctl install` times out | A cold runner exceeded the generic 45-second command limit. Installation now has an explicit 180-second timeout; keep shorter limits for ordinary UI actions. |
| Maps introduction or permission dialog covers a place | Handle only the exact observed screen before validating the place name. The harness allows simulated location while using Maps, declines notification setup with `Not Now`, continues past the observed Maps advertising information page, and declines the separate widgets prompt with `Don't Allow`. An early blanket Maps location grant caused a delayed widgets dialog and was removed. |
| Test stops progressing after opening Maps | Maps can background the hosted nextStop process. `returnToAppAfterCapture` activates nextStop after the screenshot and before writing the phase ACK. |
| Downloaded diagnostics do not match the rerun | Select the artifact by newest `created_at`/ID, not only its shared name. |

The runner uses `macos-26`, Xcode 26.6, iOS 26.5, and iPhone 17 Pro in the
verified captures. Record actual versions in each run; do not assume a future
runner image is identical. Simulator CarPlay entitlement verification reads the
executable's `__TEXT,__entitlements` section; an empty ad-hoc code-signature
entitlement dictionary is not a failure by itself.

All UI clicks, permission handling, and simulated location changes above are
for the **fresh disposable GitHub runner only**. They are not instructions to
operate the user's local Mac, unlock it, change its permissions, or replace its
personal app data.
