# Simulator screenshots

Use the existing GitHub macOS runner harness for native iPhone and CarPlay
screenshots. Do not recreate the UI or restart the simulator investigation.
This is the canonical operational entry point. Choose the harness for the task:

| Task | Branch | Workflow and implementation |
| --- | --- | --- |
| CarPlay resolution/text audit | `codex/carplay-text-fit` | [`carplay-layout.yml`](../../.github/workflows/carplay-layout.yml), [`scripts/carplay-capture`](../../scripts/carplay-capture/) |
| Website iPhone/CarPlay gallery | `codex/app-explainer-website` | `carplay-screenshots.yml`, website fixture and importers on that branch |

Both use a separate `screenshot-app` checkout and overlay only the hosted test
at `ios/NextStopAppTests/ProfileRepositoryTests.swift`. Production app, core,
CarPlay, Xcode project, configuration, and entitlements must remain unchanged
for capture. Dispatch works from any checkout with authenticated `gh`; local
Xcode is unnecessary. Work on the appropriate existing worktree, commit and push
authorized harness changes, then dispatch: local edits do not affect a runner.

## CarPlay layout: start here

The layout workflow is manual. `mode=matrix` builds and captures ten nextStop
CarPlay views per configuration; `mode=display` verifies the configured native
display without building the app; `mode=discover` inspects configuration controls.
`configuration` accepts `all` or an exact ID from
[`display-configurations.json`](../../scripts/carplay-capture/display-configurations.json).
Use one configuration while correcting a failure. Run the full matrix when
validating a new production layout; a capture-only correction can retain the
other completed configurations with their original provenance:

```bash
gh workflow run carplay-layout.yml --repo nellesf/nextStop \
  --ref codex/carplay-text-fit -f mode=display -f configuration=portrait-3x
gh workflow run carplay-layout.yml --repo nellesf/nextStop \
  --ref codex/carplay-text-fit -f mode=matrix -f configuration=portrait-3x
gh workflow run carplay-layout.yml --repo nellesf/nextStop \
  --ref codex/carplay-text-fit -f mode=matrix -f configuration=all
gh run list --repo nellesf/nextStop --workflow carplay-layout.yml \
  --branch codex/carplay-text-fit --limit 5
```

These are separate choices, not commands to dispatch together. Use
`-f mode=discover` only when controls or the runner image changed; preserve its
`carplay-layout-discovery` artifact before adapting the configurator.

For a Python/workflow-only correction, layout now accepts optional verified reuse:
`app_ref` (the full original app commit), `reuse_artifact_id` (an exact artifact ID
from this repository), and `reuse_sha256` (the build archive digest). Both reuse
inputs require all three values. Ubuntu validates them before allocating macOS
runners; they apply only to `mode=matrix`. The download extracts only the source
manifest and build archive to fixed temporary paths. `capture.sh` checks the
original app commit, app subtree, current Swift fixture hash, and archive digest
before using it. A Swift fixture change requires a fresh build. The website's
`reuse_run_id` flag is not a layout input.

The targeted verification below uses the build from `34962890365`, whose app and
Swift fixture are unchanged. Its capture failed, so the archive is a verified
build input, not completed screenshot evidence. Reuse verification run
[34964912072](https://github.com/nellesf/nextStop/actions/runs/34964912072) is pending.

```bash
gh workflow run carplay-layout.yml --repo nellesf/nextStop \
  --ref codex/carplay-text-fit -f mode=matrix -f configuration=portrait-3x \
  -f app_ref=200e13d9bb151c88e9786cf96c5690f2ee733d19 \
  -f reuse_artifact_id=10394194384 \
  -f reuse_sha256=8d7527500fbcb67430f6b164664a2ffc5d5a2c57a496f588ac9eb3aab23fd41c
```

Artifact retention is seven days. After expiry, build once from the required
app/fixture and record the new exact artifact ID and archive digest; do not
remove the checks or silently switch to another archive.

The layout app checkout defaults to the dispatched commit. The manifest's
`appTree` is specifically `HEAD:ios/NextStopApp`; compare the complete `ios` tree
separately when verifying unchanged production sources. The eight cases cover
documented configurations and common sizes,
including both scales at 1280 × 720 and an additional 900 × 1200 @3x portrait
case. Simulator accepts arbitrary dimensions: eight cases are not every possible
display or content state. See the [audit](../testing/carplay-layout/README.md)
and [visual review](../testing/carplay-layout/visual-review.md) for API limits,
coverage, and observed defects.

### Native display acceptance and bounded startup

Preflight enables `com.apple.iphonesimulator CarPlayExtraOptions` before opening
Simulator. The observed **I/O → External Displays → CarPlay…** menu then opens
**TV Out Extended Setup**; the default CarPlay path alone produced 800 × 480.
The proven input path is in `configure-display.py`: locate the observed Width
and Height controls, **triple-click** their actual positions, type each value,
and press **Tab** to commit. Simulator intercepts Command-A; AX `setValue` and
`AXFocused` did not reliably commit the actual configuration. For Scale, click
the real popup and then its observed `2.0` or `3.0` entry (exposed as
`AXTextField` in the verified runner). Do not type a scale into the combo box or
hard-code unobserved screen coordinates.

Matching AX readback is necessary but insufficient. Preflight must establish:

- Exact native PNG framebuffer width and height, before app build and again for
  every final PNG.
- The requested runtime scale from `xcrun simctl io "$CARPLAY_DEVICE_ID" enumerate`:
  inspect the active **Connected Screens → TVOut → Preferred UI Scale**, not the
  integrated phone screen or creatable-screen defaults.
- `display-configuration.json` with requested/readback values, `runSubmitted`,
  `runtimeScale`, and `framebufferSize`, plus the identical configuration in
  `preflight.json` and the same fresh device ID.

For display/matrix mode, compile the Vision OCR helper **before booting** the
fresh simulator; its first compilation can be slow. Use Simulator from the selected Xcode and keep the
runner awake with `caffeinate -diu`. Preflight allows **240 seconds** for the
first readable CarPlay frame, then **one** native close/reconnect and **180
seconds** more. Individual calls also have bounded timeouts. Failure after that
budget stops capture and preserves diagnostics; do not add indefinite polling or
repeated blind reconnects.

Discovery intentionally skips OCR compilation and default-display readiness.
Its bounded probe enables the extra options and restarts Simulator itself.
Capture the configuration screenshot first, then use bulk properties and shallow,
bounded accessibility reads of that dialog. Recursive per-property traversal of
the whole Simulator tree timed out in run `34953004743`; the focused probe worked
in `34953971279`.

In the seven successful jobs of
[run 34959786544](https://github.com/nellesf/nextStop/actions/runs/34959786544),
preflight took 5.9–8.3 minutes and build plus ten-screen capture 6.2–8.2 minutes:
about **13–16 minutes per job, plus queue time**. Do not cancel normal compilation
or cold boot prematurely. `max-parallel: 8` is a ceiling; that run initially had
five macOS jobs running and three queued. The layout workflow does not cancel
older runs automatically. Check active runs before dispatching another matrix.

### Layout evidence and import

Status recorded on **2026-09-15**: run `34959786544` completed seven of eight
configurations (70 native PNGs, each configuration's hosted test passed).
`portrait-3x` failed root readiness because the title under audit was ellipsized.
The corrected single-configuration
[run 34962890365](https://github.com/nellesf/nextStop/actions/runs/34962890365),
harness `200e13d9bb151c88e9786cf96c5690f2ee733d19`, verified its display and built
successfully, but the native app-icon click left CarPlay on its home screen.
It has no completed capture manifest. [Selected original diagnostics](../testing/carplay-layout/failed-portrait-3x/README.md)
preserve both failures after artifact expiry.
The activation correction is being checked separately in `34964912072` using
the verified existing build; this pending run does not yet add a completed case.
The [capture index](../testing/carplay-layout/captures/index.json) records admitted
evidence; neither pending nor failed configurations count as completed.

Artifacts are named `carplay-layout-<configuration>`. Download each newest
non-expired artifact ID as described below into its own directory under one
fresh run/attempt directory, then use:

```bash
python3 scripts/carplay-capture/import-layout-captures.py \
  /tmp/nextstop-layout-RUN-ATTEMPT
```

The importer requires exactly ten PNGs with matching original SHA-256 hashes and
dimensions, corresponding OCR, display/preflight provenance, a completed
`layout-capture-source.json`, and a hosted summary of one test passed, zero failed,
zero skipped. It copies only that evidence into `docs/testing/carplay-layout/captures`;
build archives, bulk diagnostics, and Apple SDK copies stay outside Git. Selected
failure evidence may be preserved separately and labelled incomplete. It reports
missing/failed configurations and exits nonzero after importing a valid subset.
Use `--allow-partial` only for an explicitly partial import, and `--replace` only
to intentionally replace different existing evidence. Run/harness/app provenance
must agree within one destination: use `--destination` for a separate run, including
a corrected single-configuration run; never combine it into a fictitious full run.

Readiness uses short visible anchors, while phase metadata retains the complete
`expectedTexts` and template content. For the seeded profile root, wait for
`Profile` + `Leipzig` twice, two seconds apart; **do not require the full
`Fahrt wählen` title**, whose clipping is part of the audit. Similar short anchors keep
long option titles from blocking their own capture. Preserve the actual strings;
an OCR match can reconstruct clipped words, and missing OCR can indicate an
offscreen row. Neither OCR nor a passed capture test establishes a visual pass.
Review every original PNG at native size and distinguish horizontal clipping,
ellipsis, extra wrapping, missing detail content, and ordinary scroll boundaries.

Root activation has a shared 120-second budget, including native commands and
delays. It requires two stable profile frames at least two seconds apart. It may
send at most two icon clicks, separated by at least 30 seconds, and only after
two fresh home observations plus another check immediately before mouse input.
Any partial/full profile observation disables further icon clicks. Unknown or
transition frames never justify a click. `root-activation.json` records each
observation/decision; its PNGs retain what the helper actually saw.

## Website capture and verified build reuse

The verified website app source is pinned to
`5fe2fa2332d66d2499fc679617855d41cb0111be` (version 0.1.0, build 1).
This command reuses the successful six-image build and runs the result capture:

```bash
gh workflow run carplay-screenshots.yml --repo nellesf/nextStop \
  --ref codex/app-explainer-website \
  -f capture_mode=results \
  -f reuse_run_id=34938078711 \
  -f reuse_sha256=a585a0ab7558aa0a4a6dbe20cf6d900c66fd118c38ad76b0f900ffd71df28329
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

### Verified website status and evidence

Status recorded on **2026-09-15**; inspect the linked run before treating a later
attempt as successful.

| Run | What is established |
| --- | --- |
| [34880309048](https://github.com/nellesf/nextStop/actions/runs/34880309048) | Successful CarPlay profile/preparation capture and passing hosted test. |
| [34928718397](https://github.com/nellesf/nextStop/actions/runs/34928718397) | Historical verified result-test build; capture failed. Its older Swift fixture is not the current six-image fixture. |
| [34932855914](https://github.com/nellesf/nextStop/actions/runs/34932855914) | Four native nextStop images reached: CarPlay results, result actions, charging-provider list, and iPhone results. The full eight-image set did **not** finish. |
| [34933714967](https://github.com/nellesf/nextStop/actions/runs/34933714967) | Earlier introduction-handling attempt using harness `63f10b4`; superseded by the verified six-image run below. |
| [34938078711](https://github.com/nellesf/nextStop/actions/runs/34938078711) | Six original result/place images imported, all image hashes verified, hosted test 1 passed / 0 failed / 0 skipped. Harness/build `f8c9390a44b1ae17f3875cbfb125ff3c5034aaaa`; archive SHA-256 is in the quick start. The native CarPlay results heading clips; capture success is not a layout pass. |

After a complete run, update this table with its run/attempt, harness commit,
archive hash, and visual-review result. A build, partial PNGs, or a green unrelated
test do not establish that all requested screens were captured.

## Download originals by artifact ID

Artifacts contain original PNGs, provenance, fixture evidence, and diagnostics.
On a rerun, downloading by name can select an older attempt's artifact. Resolve
the newest non-expired artifact ID instead. The example is for the website;
for layout use its run and `carplay-layout-<configuration>` artifact name:

```bash
capture_run=34938078711 # Replace with the run being reviewed.
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

### Website visual review and import

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
| `iphone-results.png` | nextStop | 1206 × 2622 |
| `iphone-restaurant-place.png`, `iphone-charging-place.png` | Apple Maps | 1206 × 2622 |

A complete current website result run requires the six result/place images
(excluding the separate profile/preparation pair),
`result-capture-source.json`, and a hosted-test summary with one passed test,
zero failures, and zero skips. Run the importer from the website worktree root:

```bash
node website/scripts/import-result-screenshots.mjs \
  /tmp/nextstop-capture-review 5fe2fa2332d66d2499fc679617855d41cb0111be
```

The earlier eight-image target also included two Apple Maps CarPlay place views.
In [run 34936686885](https://github.com/nellesf/nextStop/actions/runs/34936686885),
the handoff succeeded and the iPhone displayed the resolved place, but CarPlay
remained blank. The current fixture/importer omits those two views and records
that limitation; this is not proof of a general Simulator support limitation.

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

The two captured iPhone place views belong to **Apple Maps**, not nextStop.
The omitted CarPlay place views would also belong to Maps. Name the owner in
captions and preserve `ownerApp` in provenance. The app selects a restaurant or
charging location/provider, not an individual EVSE or connector. Never add fake
pixels, draw substitute app screens, or change production behavior for capture.

## Troubleshooting without repeating the investigation

Start with `phase-*.json`, `website-capture-state.json`, `profile-setup.log`, and
`profile-test-summary.json`. Compare `diagnostic-<phase>-*.png` with their OCR
JSON and `capture-actions.log`. `website-capture-fixture.json` records successful
MapKit queries, candidates, and any later result/place evidence. Partial fixture
metadata is useful for diagnosis; it is not complete capture provenance.

For failures before app build, inspect `preflight.json`, `readiness-*.json`,
`display-configuration.json`, configuration screenshots/AX observations, and the
preflight command logs first. A successful menu action or process launch alone
does not establish a working display.

During an active matrix, a completed job's artifact may already be available even
when `gh run view RUN --job JOB --log-failed` refuses to return logs until the
whole run completes. The portrait diagnosis in
[34959786544](https://github.com/nellesf/nextStop/actions/runs/34959786544) used
`diagnostic-external-0-9.png` and its OCR from the completed job's artifact.
Download that evidence instead of repeatedly polling unavailable run logs.

| Symptom | Established cause and working approach |
| --- | --- |
| Configuration fields read back correctly but PNG size is wrong | [34955002133](https://github.com/nellesf/nextStop/actions/runs/34955002133) reported 748 × 456 / 1280 × 720 in AX, but native frames remained 748 × 480 / 1280 × 480. Use the committed triple-click/type/Tab path and actual Scale popup selection above. Validate display-input corrections with `mode=display`; the matrix also verifies framebuffer and runtime scale before building, so do not add a redundant display-only run for an unchanged configurator. |
| Width/Height edits or Scale selection do not commit | Follow the observed controls from [34953971279](https://github.com/nellesf/nextStop/actions/runs/34953971279), using real mouse and keyboard events. Command-A, AX `setValue`, and setting `AXFocused` were unreliable. If the UI differs, run `mode=discover` and inspect its bounded observation; do not guess indexes or loop through blind edits. |
| Fresh display starts just as the harness reconnects | [34957774780](https://github.com/nellesf/nextStop/actions/runs/34957774780) created its launcher about 113 seconds after configuration; the old 90-second budget interrupted it. The current harness allows 240 seconds initially plus 180 seconds after one reconnect. Run [34959786544](https://github.com/nellesf/nextStop/actions/runs/34959786544) had already started on the older 90-second limits and nevertheless completed seven configurations; the longer allowance first applies to the targeted follow-up. |
| Swift waits for the first ACK but Python sees no phase | XCTest can reinstall the app into a new data-container UUID. `results.py` / `layout.py` re-resolve the container every 3 seconds until a state appears and bind state, command, and fixture paths to that same live container. Tolerate a bounded lookup timeout during installation and reapply the simulator location grant afterward. This path completed in [34938078711](https://github.com/nellesf/nextStop/actions/runs/34938078711). |
| Profile handler completes but no ride summary appears | The root template's transition gate can still be active. Wait for two stable rendered root frames before ACK, then await the actual public push/pop completion. Handler completion also fires when an action is rejected early; `topTemplate` alone can precede the completed animation. Do not pre-click Leipzig and invoke its handler a second time. |
| Portrait root stays visible while capture waits for its full title | The 900 × 1200 @3x job in [34959786544](https://github.com/nellesf/nextStop/actions/runs/34959786544) rendered an ellipsized `Fahrt wählen`. The corrected harness uses `Profile` + `Leipzig` readiness anchors, preserving the full title in `expectedTexts`. The follow-up stopped earlier at app activation; do not classify the original failed capture as a missing app screen. |
| The native app-icon click is dispatched but home remains visible | [34962890365](https://github.com/nellesf/nextStop/actions/runs/34962890365) shows the pointer on nextStop, then twelve unchanged home frames. Click dispatch is not readiness. The bounded correction waits for two profile frames and permits one additional click only after delayed, fresh, unambiguous home observations; it does not retap during a transition. Preserve the failed attempt and verify the correction in a new run. |
| A result is highlighted but no destination buttons appear | `selectedIndex = 0` and the delegate callback only establish focus. The harness clicks the first observed `… km Fahrstrecke` row through the real Simulator UI. |
| Clicking an app or row has no effect | Use the observed window and OCR coordinates. The proven mouse helper moves the pointer, verifies its position, and sends down/up with click state 1. Tap the nextStop icon above its caption. System Events `click at` and caption-only taps failed. |
| Blank/delayed external display | Use the explicit Simulator from the selected Xcode, fresh device, and existing bounded preflight/reconnect logic. `caffeinate -diu` keeps the disposable runner session awake. Do not infer readiness from successful menu opening alone. |
| First-boot status-bar command times out | A transient first-boot failure has occurred before app testing. Inspect preflight logs and rerun once; do not change app code for it. |
| Maps introduction or permission dialog covers a place | Handle only the exact observed screen before validating the place name. The harness allows simulated location while using Maps, declines notification setup with `Not Now`, and declines the separate widgets prompt with `Don't Allow`. An early blanket Maps location grant caused a delayed widgets dialog and was removed. |
| Test stops progressing after opening Maps | Maps can background the hosted nextStop process. `returnToAppAfterCapture` activates nextStop after the screenshot and before writing the phase ACK. |
| Downloaded diagnostics do not match the rerun | Select the artifact by newest `created_at`/ID, not only its shared name. |

After a failure, preserve that attempt's evidence, identify the failed stage,
and rerun only the affected configuration after a concrete correction. A transient
first-boot timeout can justify one unchanged retry. Stop repeated unchanged
failures and inspect the native evidence; do not change production presentation
or permission policy to make a capture pass. A Swift fixture change requires a
fresh build even when the production app is unchanged. In preflight, exporting
the fresh device ID to `GITHUB_ENV` only affects later workflow steps: also set
`os.environ["CARPLAY_DEVICE_ID"]` before invoking a child configurator in the
same Python process.

The runner uses `macos-26`, Xcode 26.6, iOS 26.5, and iPhone 17 Pro in the
verified captures. Record actual versions in each run; do not assume a future
runner image is identical. Simulator CarPlay entitlement verification reads the
executable's `__TEXT,__entitlements` section; an empty ad-hoc code-signature
entitlement dictionary is not a failure by itself.

All UI clicks, permission handling, and simulated location changes above are
for the **fresh disposable GitHub runner only**. They are not instructions to
operate the user's local Mac, unlock it, change its permissions, or replace its
personal app data.
