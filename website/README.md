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

- Final decision whether the clearly labelled CarPlay design preview is
  accepted or should also be replaced with a verified capture.
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

## App screenshots

The iPhone images in `public/screenshots/` are genuine Simulator captures
of the app built from `main`, using local example profiles. The capture harness
does not change the app's production UI or search behavior. The images show the
profile list, profile editor, and profile filters:

- `iphone-profiles.png`
- `iphone-profile-editor.png`
- `iphone-profile-filters.png`

The page uses the profile list and editor captures. The lower-filter capture is
retained with its provenance but is not displayed because the Simulator capture
contains a rendering artifact in the save button. The 500 m distance is instead
explained as text. A passing UI test does not replace visual review.

`app/page.tsx` displays each image at its native aspect ratio without a recreated
status bar or UI overlay. `app/globals.css` supplies only the surrounding device
frame. Keep the original files when refreshing the captures and record the exact
source revision and runner details alongside them. `npm test` checks that all
two selected images appear in the exported page and exist in the static output.

The CarPlay illustration is still a code-based design preview and remains
explicitly labelled as such. It must not be described as a Simulator screenshot.

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

Do not publish the site until the legal operator/contact information has been
added and the design-preview app images have either been accepted or replaced
with final captures.

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
- `public/screenshots/` contains original iPhone captures from the pinned `main`
  app, with the source commit, Actions run and PNG hashes in `provenance.json`.
  The CarPlay illustration remains explicitly labelled as a design preview.
- `public/og.png` is the generated social preview card.
