# nextStop Website

German product website for nextStop. The site is a static, responsive one-page
experience and is prepared for Firebase Hosting in a Google Cloud project.

## Local development

Requires Node.js 22.13 or newer.

```bash
npm install
npm run dev
```

The local preview is available at `http://localhost:3000`.

## Validation and static export

```bash
npm test
npm run build:firebase
```

`npm run build:firebase` creates the deployable, ignored `firebase-public/`
directory. The export contains no request-time application state and no forms,
analytics, cookies, or external font requests.

## Inputs still needed before a public launch

### Personal imprint data

All personal imprint fields live in exactly one file:
[`content/imprint.ts`](content/imprint.ts). Replace the placeholder values there
and set `placeholdersActive` to `false`. Do not add a personal tax number or tax
identification number. The page deliberately shows a yellow placeholder warning
until this switch is changed.

- If the activity later uses a registered business/company: decide whether
  additional register, VAT-ID or consumer-dispute information applies.
- Privacy owner/contact and confirmation of the Firebase contracting entity,
  log-retention setup and data-processing agreement. The current site does not
  add analytics, marketing scripts, external fonts, maps or a contact form.

The final legal text depends on the operator. Relevant official references are
[§ 5 DDG](https://www.gesetze-im-internet.de/ddg/__5.html),
[Article 13 GDPR](https://eur-lex.europa.eu/eli/reg/2016/679/oj?locale=de) and,
where applicable,
[§ 36 VSBG](https://www.gesetze-im-internet.de/vsbg/__36.html).

## Page story and shared-link image

The page explains one combined charging and food break through the ordered flow
**create a trip profile → drive off → find a matching stop**. Keep screenshots
inside the step they explain. Apple Maps shows one selected place per action.

`public/social-card.svg` is the editable, code-native source for the shared-link
image. `public/og.png` is its 1200 × 630 browser render at a device scale of 1.
Both depict charging and food at one stop. After changing the SVG, render the
complete image again and keep the metadata dimensions synchronized. This graphic
is separate from the unchanged native app screenshots below.

## App screenshots

The iPhone profile images in `public/screenshots/` are genuine Simulator captures
of the app built from `main`, using local example profiles. The capture harness
does not change the app's production UI or search behavior. The images show the
profile list, profile editor, and profile filters:

- `iphone-profiles.png`
- `iphone-profile-editor.png`
- `iphone-profile-filters.png`

The page uses the profile list and editor captures. The lower-filter capture is
retained with its provenance but is not displayed because the Simulator capture
contains a rendering artifact in the save button. A passing UI test does not
replace visual review.

`app/page.tsx` displays each image at its native aspect ratio without a recreated
status bar or UI overlay. `app/globals.css` supplies only the surrounding device
frame. Keep the original files when refreshing the captures and record the exact
source revision and runner details alongside them. `npm test` checks that the
selected images appear in the exported page and exist in the static output.

The page follows one ordered journey, with images at their corresponding step:

1. Create the upcoming trip profile on iPhone: editor, then saved profiles.
2. Drive off and recall the prepared trip in CarPlay: profile selection and ride summary.
3. Find a combined charging/food stop: CarPlay results beside iPhone results,
   followed by destination actions and provider selection. The two Apple Maps
   place cards are available in an expandable disclosure after that selection.

The hero uses one shared charging-and-food stop, rather than separate route
markers. Keep the product copy conversational: restaurant nearby, actual distance
to the stop, and the user's preferences. Routing implementation names and spatial
terminology belong in developer documentation, not the landing page. Do not imply
automatic search on departure, a verified walking route, guaranteed availability,
or a multi-stop Apple Maps itinerary.

`content/result-screenshots.ts` holds the reviewed captures for the additional
result and place-selection galleries. Six reviewed captures from
[run 34938078711](https://github.com/nellesf/nextStop/actions/runs/34938078711)
are retained in `public/screenshots/`. Its three iPhone images remain displayed.
The result and selection views in CarPlay use the separate native wide capture
set in `public/screenshots/carplay-wide/`, at 1920 × 720 pixels and @3x UI scale.
These three completed CarPlay captures come from
[run 34969883976](https://github.com/nellesf/nextStop/actions/runs/34969883976),
artifact `10397352942`, capture harness
`b49400d2a15edc89adcfefb015bcac7ce7101b74`. All three were visually reviewed:
their native titles and subtitles fit. The overall run **failed later**, at the
iPhone Apple Maps advertising introduction after 90 seconds; XCTest was aborted
and there is no passing result-test summary. This is a scoped CarPlay refresh,
not a successful six-screen capture. Its separate
`carplay-result-provenance.json` records `captureScope: "carplay-results-only"`
and the failed run with supporting evidence. The eleven earlier original PNGs,
their manifests, and the displayed iPhone set remain unchanged.
Empty collections render no empty gallery or
missing-image references. Populate each entry with the imported path, accurate alt text and a
caption that identifies the screen, including Apple Maps when it owns the view.
Keep the images beside the action they explain rather than collecting them in
a separate gallery. Keep screenshot provenance separate when the capture run or
data fixture differs from the existing profile images.

For result captures, dispatch the workflow in `results` mode. Download the
successful run's artifact and inspect the six original screenshots before
importing them:

```bash
gh workflow run carplay-screenshots.yml --ref codex/app-explainer-website -f capture_mode=results
gh run download <run-id> -n carplay-captures -D /tmp/nextstop-result-captures
node website/scripts/import-result-screenshots.mjs /tmp/nextstop-result-captures <full-main-commit-sha>
```

The importer reads `result-capture-source.json`. It verifies the requested app
commit and its Git tree, the fixture source hash against the recorded build
harness commit, the complete six-file set, native dimensions, display, owning
app and PNG hashes before writing anything. Source commits must be available
in the local Git history. Originals are copied unchanged; fixture details,
owners and source metadata remain in `result-provenance.json`.

Expected result captures:

- `iphone-results.png`: nextStop results, 1206 × 2622.
- `iphone-restaurant-place.png` and `iphone-charging-place.png`: native
  **Apple Maps** place views, 1206 × 2622.
- `carplay-results.png`, `carplay-result-actions.png` and
  `carplay-charging-places.png`: nextStop result overview, destination actions
  and charging-operator selection, each 800 × 480.

For the website's wide CarPlay format, add `-f display_variant=wide` to dispatch.
Run `34969883976` verified native 1920 × 720 at @3x through Simulator field
readback, the connected display's actual scale, and the PNG dimensions. A resized
default image is not accepted. A future complete six-screen wide run can use
`import-result-screenshots.mjs` with a separate output directory as its third
argument; that importer still requires the entire set.

The current three-image refresh instead uses the dedicated
`import-wide-carplay-screenshots.mjs` importer. It retains only the completed
CarPlay originals in `public/screenshots/carplay-wide/`, together with their
scoped manifest and evidence of both capture completion and the later failure.
From the repository root, after downloading the artifact and its evidence:

```bash
node website/scripts/import-wide-carplay-screenshots.mjs \
  /tmp/nextstop-wide-capture-review 5fe2fa2332d66d2499fc679617855d41cb0111be \
  /tmp/nextstop-wide-capture-review/carplay-captures.zip
```

The optional fourth argument overrides the output directory. The original ZIP's
SHA-256 must match GitHub's artifact `digest`; original PNG and capture evidence
bytes are read directly from that verified ZIP. The artifact directory must also
contain `run-evidence.json`, `artifact-evidence.json`, and `capture-run.log`.
The output keeps those records and the source, display, fixture, phase, and OCR
evidence under `evidence/`, with hashes in the scoped manifest.
Its `fixtureSnapshotScope` explains that preserved `fixture.renderedResults`
describes the later iPhone comparison, not an exact transcript of the earlier
CarPlay screen. Keep the PNG/OCR evidence as the record of its visible values.

Do not manufacture `result-capture-source.json`, a passing test summary, or a
six-image provenance record for this partial run. See the
[capture guide](../docs/operations/simulator-screenshots.md#scoped-wide-carplay-refresh)
for the exact evidence download/import commands and compatible build reuse.

Apple Maps place views in CarPlay are excluded from this capture set. The
restaurant handoff in
[Actions run 34936686885](https://github.com/nellesf/nextStop/actions/runs/34936686885)
succeeded, but its external-display image remained blank. The charging-place
phase was not reached. Both CarPlay place views are therefore excluded from the
supported set. This is an observed runner capture limitation; the website does
not use blank images or recreate their content.
The supported CarPlay images show nextStop's results, destination actions and
charging-provider selection. Apple Maps place views are shown on the iPhone.

Result captures use example EVSE counts and charging power, with real MapKit
places and calculated driving distances. Availability in this fixture is unknown.
Apple Maps shows its own place data, so its charger counts can differ from the
nextStop example values. Its captured system UI uses English and miles; the
nextStop app screens are German.
The website must say so beside these images; the example capacities are not
verified site facts or live availability.
Selection is of a restaurant or charging operator, never an individual connector.
The import does not activate image references. Add the visually reviewed images
to `content/result-screenshots.ts` afterwards, with Apple Maps named in its two
iPhone place-view captions. CarPlay images use at most two desktop columns and one
column on narrower screens. Each screenshot links to its original PNG and has
an accessible label identifying the full-size image; no modal or image editing
is involved.

### Original PNGs for App Store design

Keep the imported PNGs checked into `website/public/screenshots/` together with
their provenance manifests, so design work does not depend on the retention of
GitHub Actions artifacts. Use these original files as source images for later
App Store layouts. iPhone originals are 1206 × 2622 pixels; CarPlay originals
include 800 × 480 pixels and the separate 1920 × 720 wide set. The website's
device frames and captions are CSS/HTML and
are not embedded in the PNGs. Save composed marketing images separately and
retain the source PNGs unchanged, with their manifest hashes intact.

The currently pinned `main` revision is
`5fe2fa2332d66d2499fc679617855d41cb0111be`: app version **0.1.0**, build **1**,
as declared by `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in that
revision's `ios/project.yml`. The provenance manifests record the app commit,
capture/build harness revisions, Actions run URL and image hashes; result
provenance additionally records the owning app and fixture data. Preserve those
details when reusing the images, and identify the two iPhone Apple Maps place views
as Apple Maps. These are native capture dimensions, not a claim that every PNG
already meets every App Store submission format or presentation requirement.

The website branch's on-demand **CarPlay Screenshots** workflow boots a fresh iPhone
Simulator, opens the native CarPlay display, and builds the pinned `main` source.
In `profiles` mode, an opt-in hosted test seeds an example Leipzig profile through the app's
unchanged SwiftData repository, then the job selects it through the actual CarPlay
interface. This avoids making the capture depend on iPhone UI-test accessibility
or a live place search. The sample coordinates describe central Leipzig; no live
charging results are seeded. This profile capture never
starts a charging search or navigation. Simulator entitlements are verified in
the compiled executable; app code and the entitlement source file are unchanged.

```bash
gh workflow run carplay-screenshots.yml --ref codex/app-explainer-website -f capture_mode=profiles
```

Download the successful run's `carplay-captures` artifact, visually inspect both
PNGs, and import them from the repository root:

```bash
gh run download <run-id> -n carplay-captures -D /tmp/nextstop-carplay-captures
node website/scripts/import-carplay-screenshots.mjs /tmp/nextstop-carplay-captures <full-main-commit-sha>
```

`carplay-provenance.json` records source revisions, run URL, embedded entitlements,
capture times, dimensions and SHA-256 hashes. The importer verifies the full set
before copying any assets. Tests verify the original bytes and ensure both
iPhone and CarPlay captures use the same app source revision.

For capture-only retries, manually dispatch the workflow with `reuse_run_id` and
the verified SHA-256 of that run's `CarPlayBuild.tar.gz` as `reuse_sha256`. The
script verifies the pinned source commit, app tree, fixture source hash, and archive digest before
reuse, then prepares the profile again in a fresh simulator. Build provenance
remains separate from the current capture run. Leave both inputs empty to build
from source; the normal workflow does not depend on retained artifacts.

## First Firebase Hosting deployment

The production website project is `nextstop-tech-prod-website`. Authenticate
the Firebase CLI, build, deploy a short-lived preview, and then promote that
tested version:

```bash
npx firebase-tools login
npm run build:firebase
npx firebase-tools hosting:channel:deploy prelaunch --expires 1d --project nextstop-tech-prod-website
npx firebase-tools hosting:clone nextstop-tech-prod-website:prelaunch nextstop-tech-prod-website:live --project nextstop-tech-prod-website
```

Then, in **Firebase Console → Hosting → Add custom domain**, add both
   `nextstop.tech` and `www.nextstop.tech`. Make `nextstop.tech` canonical and
   redirect `www` to it.

Before a public launch, add the legal operator/contact information. The existing
Cloud Run preview remains restricted to the owner's Google account.

## Private Google Cloud preview

Firebase Hosting and its preview channels are link-accessible, not restricted
to one Google account. For a genuinely private review, deploy the supplied
container to Cloud Run and protect its `run.app` URL directly with
Identity-Aware Proxy (IAP). The project must have an active Cloud Billing
account first; do not use `--allow-unauthenticated`.

```bash
gcloud run deploy nextstop-website-preview \
  --source . \
  --project nextstop-tech-preview-website \
  --region europe-west3 \
  --port 8080 \
  --no-allow-unauthenticated \
  --iap \
  --min 0 \
  --max 1 \
  --memory 256Mi \
  --cpu 1 \
  --cpu-throttling \
  --concurrency 80 \
  --ingress all
```

Allow the IAP service agent to invoke Cloud Run, then grant only the intended
Google account access (do not grant `allUsers` or `allAuthenticatedUsers`):

```bash
PROJECT_NUMBER="$(gcloud projects describe nextstop-tech-preview-website --format='value(projectNumber)')"
gcloud run services add-iam-policy-binding nextstop-website-preview \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com" \
  --role=roles/run.invoker \
  --region=europe-west3 \
  --project=nextstop-tech-preview-website

gcloud iap web add-iam-policy-binding \
  --member=user:YOUR_GOOGLE_ACCOUNT \
  --role=roles/iap.httpsResourceAccessor \
  --region=europe-west3 \
  --resource-type=cloud-run \
  --service=nextstop-website-preview \
  --project=nextstop-tech-preview-website
```

For a project without a Google Cloud organization, complete the one-time OAuth
setup in the Google Cloud console: configure **Google Auth Platform** with an
external audience, then open **Security → Identity-Aware Proxy**, select the
Cloud Run service, open **Settings**, choose **Custom OAuth**, create the
credentials automatically and save. No client secret belongs in this
repository. After that, the normal `run.app` URL presents Google sign-in and
admits only the granted user.
The service has `min=0`, is not publicly invokable and sends an
`X-Robots-Tag: noindex, nofollow` response header. Direct Cloud Run IAP does not
require a load balancer.

Keep source-deployment images bounded with the checked-in Artifact Registry
cleanup policy. It preserves the five newest versions of every package and
deletes older versions only after 30 days:

```bash
gcloud artifacts repositories set-cleanup-policies cloud-run-source-deploy \
  --policy=cloud-run/cloud-run-source-cleanup.json \
  --location=europe-west3 \
  --project=nextstop-tech-preview-website \
  --no-dry-run
```

### Expected preview and production costs

- Classic Firebase Hosting on the Spark plan needs no billing account. Hosting
  includes 10 GB storage and, per the current Hosting usage documentation,
  10 GB monthly CDN transfer at no cost. On Spark, exceeding the quota disables
  deploys/site delivery instead of creating usage charges.
- A private Cloud Run preview requires Cloud Billing. With request-based
  billing, `min=0`, one viewer and a single small container, expected monthly
  cost is USD 0 within the Cloud Run, Cloud Build and Artifact Registry free
  tiers. It is still pay-as-you-go, not a hard spending cap.
- The preview project has a project-wide monthly EUR 5 budget alert. It covers
  Cloud Run, Cloud Build, Artifact Registry and network charges but does not stop
  resources. A second EUR 5 **Spend cap enforcement** budget is configured for
  Cloud Run. It pauses Cloud Run around that amount; metering delay means it is
  not an absolute cap, and Cloud Build, Artifact Registry and network charges
  remain covered only by the alert.
- Linking Cloud Billing to a Firebase project changes it from Spark to Blaze.
  Budget alerts notify but do not cap spending.

The private preview therefore uses the separate billed project
`nextstop-tech-preview-website`. The public Firebase Hosting project
`nextstop-tech-prod-website` remains on Spark without a billing account, so a
traffic spike can disable public delivery but cannot create Hosting overage
charges.

References: [Firebase Hosting usage](https://firebase.google.com/docs/hosting/usage-quotas-pricing),
[Firebase plans](https://firebase.google.com/docs/projects/billing/firebase-pricing-plans),
[Cloud Run pricing](https://cloud.google.com/run/pricing),
[Cloud Build pricing](https://cloud.google.com/build/pricing), and
[Artifact Registry pricing](https://cloud.google.com/artifact-registry/pricing).

## IONOS DNS records

Firebase's domain wizard is authoritative. With the current Firebase Hosting
quick setup, add these records in the IONOS DNS area:

| Type | Hostname | Value | TTL |
| --- | --- | --- | --- |
| TXT | `@` | Exact verification value shown by Firebase | `3600` |
| A | `@` | `199.36.158.100` | `3600` |
| A | `www` | `199.36.158.100` | `3600` |

- In IONOS, use `@` (or the empty host field) for the apex, not
  `nextstop.tech`.
- Use only `www` as the subdomain host, not the full hostname.
- Remove conflicting A, AAAA, or CNAME records only for `@` and `www`.
- Keep `api.nextstop.tech` and all MX, SPF, DKIM, and DMARC records unchanged.
- Do not change the nameservers and do not add an IONOS web redirect.
- Keep the Firebase TXT verification record in place for certificate renewal.
- If CAA records already exist, permit both `pki.goog` and
  `letsencrypt.org`. If no CAA records exist, no new CAA record is needed
  unless the Firebase wizard requests one.
- Wait until Firebase marks both domains **Connected** before treating the
  domain as live. DNS and certificate provisioning can take up to 24 hours.

Official references:

- [Firebase Hosting](https://firebase.google.com/docs/hosting)
- [Connect a custom domain](https://firebase.google.com/docs/hosting/custom-domain)
- [IONOS A/AAAA records](https://www.ionos.com/help/domains/configuring-your-ip-address/changing-a-domains-ipv4/ipv6-address-a/aaaa-record/)
- [IONOS TXT records](https://www.ionos.com/help/domains/configuring-txt-and-srv-records/managing-txt-records/)
- [IONOS CAA records](https://www.ionos.com/help/domains/caa-records-konfigurieren/add-change-or-delete-a-caa-record/)

## Content and assets

- Product copy is based on the accepted nextStop architecture and domain rules.
- `public/app-icon.png` is copied from the iOS asset catalog.
- `public/screenshots/` contains original iPhone and CarPlay captures from the
  pinned `main` app, plus Apple Maps place views once result captures are
  imported. Source commits, Actions runs and PNG hashes are recorded in
  `provenance.json`, `carplay-provenance.json` and, after result import,
  `result-provenance.json`.
- `public/og.png` is the generated social preview card.
