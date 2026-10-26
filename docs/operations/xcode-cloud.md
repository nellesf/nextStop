# Xcode Cloud release channels

## Branch and release process

nextStop uses one repository, `nellesf/nextStop`, with three permanent branches,
following the Gone Sour release model:

| Branch | Xcode Cloud workflow | Distribution |
| --- | --- | --- |
| `testflight` | [Testflight](https://appstoreconnect.apple.com/teams/adcbc239-2b37-429e-83f7-5d7766433306/xcode-cloud/products/D1BFA185-7C14-4703-A24A-B714162C7CD9/workflows/8FC2BD0B-75AB-4D92-A695-D3285700B39D) | Internal TestFlight only |
| `testflightExt` | [Testflight External](https://appstoreconnect.apple.com/teams/adcbc239-2b37-429e-83f7-5d7766433306/xcode-cloud/products/D1BFA185-7C14-4703-A24A-B714162C7CD9/workflows/130ff15f-12a5-4556-984f-297f5f7c6b50) | App Store Connect archive and external TestFlight group |
| `main` | [Release](https://appstoreconnect.apple.com/teams/adcbc239-2b37-429e-83f7-5d7766433306/xcode-cloud/products/D1BFA185-7C14-4703-A24A-B714162C7CD9/workflows/56036873-25f9-4a2e-9d73-8c11f0c100e2) | App Store Connect archive; no post-actions |

Develop features on a `codex/<description>` branch and push completed work there.
Prefer one active feature branch where practical. After the owner confirms the
device check, integrate the approved change into `testflight`. Promote to
`testflightExt` when external testing is intended. Merge into `main` only on the
owner's explicit instruction. Creating or changing a workflow does not authorize
a main merge, a build, external distribution, or an App Store submission.

Distributable builds and their build numbers come from Xcode Cloud. Keep local
device checks separate from cloud-build success, Apple processing, TestFlight
availability, external beta review, and App Store release.

## Setup record: 26 October 2026

The remote branches `main`, `testflight`, and `testflightExt` were initialized at
the same existing commit:
`ad9f043a7c6d7a9c5d52d0109cfa9652648f022b`. The beta branches were created before
their Xcode Cloud triggers were configured. No application changes were merged
into `main` during this setup.

The GitHub Actions workflows `iOS App`, `Swift Core`, and `Backend` were paused
for branch creation and restored to their active state immediately afterward.
They normally run on pushes independently of Xcode Cloud. Backend deployment
continues to require the existing main-branch conditions and environment gates.

The existing `Default` workflow was renamed `Testflight`; its identity is
`8FC2BD0B-75AB-4D92-A695-D3285700B39D`. Its branch condition now matches exactly
`testflight`. The existing internal TestFlight group remains
`0c8f185a-66c9-47b3-a071-00de19a3527e`, and its archive remains internal-only.

All three workflows were saved and verified after reloading. They retain the
previous nextStop build settings, apart from the intended branch/distribution
separation and documentation exclusions:

- Project `ios/NextStop.xcodeproj`, scheme `NextStopApp`.
- Xcode and macOS: `Latest Release`.
- Clean build and automatic cancellation enabled.
- No workflow environment variables.
- Existing archive action. No Xcode Cloud test action was added, preserving the
  original configuration; the separate GitHub Actions test suites are unchanged.

`Release` matches exactly `main`, archives for App Store Connect, and has no
post-actions. `Testflight External` matches exactly `testflightExt`, archives for
App Store Connect, and targets `Externe Tests`, group
`2e060aa7-e3e0-4956-9e50-db9e675707cc`. At setup this group has zero testers and
zero builds. Apple required `restrictEditing` for this workflow; the owner
explicitly approved that setting after comparison with Gone Sour. The saved external
workflow has it enabled. No testers were invited and no build was assigned.

External distribution still requires the missing beta review metadata, including
the description and feedback/contact details. The workflow is saved, but this
does not establish readiness for the first external distribution. No contact
information was invented or submitted as part of this setup.

The all-workflow build history was unchanged after setup: the latest successful
cloud run remained
[build 25](https://appstoreconnect.apple.com/teams/adcbc239-2b37-429e-83f7-5d7766433306/xcode-cloud/products/D1BFA185-7C14-4703-A24A-B714162C7CD9/builds/4ac0c874-dba7-4c53-8335-e923fb9f8f71/summary).
No new or queued cloud builds appeared. All seven GitHub workflow enabled states
matched their baseline; neither beta branch had a GitHub Actions run. The three
remote permanent branches still pointed to the commit recorded above. This
verification precedes the documentation-branch push and does not claim a new
build or distribution success.

Application source, shared schemes, archive configuration, bundle identifiers,
entitlements, signing settings, API endpoints, backend deployment configuration,
and application/backend security controls are unchanged. All shared schemes
still archive with `Release`, using the existing production API and production App Attest behavior.
The pre-existing untracked cost-dashboard directory and Xcode Cloud manifest
are outside this documentation change.

## Documentation-only changes

Each workflow's saved branch start condition in App Store Connect uses Files
and Folders mode **Do not start if all files match**:

- Any file under `/docs/`, including its subdirectories.
- Exact filename `README.md` in any folder.
- Exact filename `AGENTS.md` in any folder.

All changed files must match these exclusions to suppress the build. A mixed
change containing application or other non-excluded files still starts the
workflow for its matching branch. Do not replace the exact branch selections
with a prefix: `testflight` must not also match `testflightExt`.

These rules are stored in Xcode Cloud on Apple's servers. The local
`ios/NextStop.xcodeproj/xcshareddata/xcodecloud/manifest.json` is not the workflow
definition and does not establish the exclusions. Save and reload the workflow
to verify its actual branch and file conditions.

For this setup's documentation commit only, `[skip ci]` in the commit message
suppresses GitHub Actions push and pull-request runs. It is not the protection
against Xcode Cloud builds. Keep ordinary code changes subject to their normal
checks. The documentation remains on `codex/xcode-cloud-release-channels` until
an explicitly authorized integration.

## Verification and rollback

Before future changes, record the saved workflow settings and current latest
build. For a change that must not start a build, prevent matching triggers before
creating or pushing refs. Save the final exact branch conditions only after the
refs exist, then reload the workflows and check the build history. Do not use a
manual build as a configuration test when no build was authorized.

If the channel setup needs rollback, disable the new `Release` and
`Testflight External` workflows; retain them for inspection rather than deleting
them. Keep the original workflow identity above and its internal-only archive
and existing group. Restore its recorded pre-change name and start condition
only after checking that no pending push will trigger a build. Re-enable only
the intended workflows after reviewing their saved conditions. Never reset a
branch, merge source, or roll back an app or backend deployment merely to undo
workflow settings.
