#!/bin/bash
set -euo pipefail

# The workflow first checks out this exact main commit into screenshot-app and
# successfully connects the real external CarPlay display before reaching here.
app_commit=5fe2fa2332d66d2499fc679617855d41cb0111be
capture_mode="${CARPLAY_CAPTURE_MODE:-profiles}"
test_method=testPrepareCarPlayScreenshotProfile
if [ "$capture_mode" = results ]; then
  test_method=testCaptureWebsiteResultScreenshots
elif [ "$capture_mode" != profiles ]; then
  echo "Unsupported capture mode: $capture_mode" >&2
  exit 1
fi
test "$(git -C screenshot-app rev-parse HEAD)" = "$app_commit"
cp ios/NextStopAppTests/ProfileRepositoryTests.swift \
  screenshot-app/ios/NextStopAppTests/ProfileRepositoryTests.swift
git -C screenshot-app diff --exit-code -- \
  ios/NextStopApp ios/NextStopCore ios/NextStopCarPlay ios/NextStop.xcodeproj ios/Config

mkdir -p CarPlay-Captures
if [ -n "${CARPLAY_REUSE_DIR:-}" ]; then
  python3 - <<'PY'
import hashlib, json, os, pathlib, shutil, subprocess
reuse = pathlib.Path(os.environ['CARPLAY_REUSE_DIR'])
source = json.loads((reuse / 'capture-source-base.json').read_text())
expected_commit = subprocess.check_output(['git', '-C', 'screenshot-app', 'rev-parse', 'HEAD'], text=True).strip()
expected_tree = subprocess.check_output(['git', '-C', 'screenshot-app', 'rev-parse', 'HEAD:ios/NextStopApp'], text=True).strip()
assert source['appCommit'] == expected_commit, 'Reused build must match the pinned main commit.'
assert source['appTree'] == expected_tree, 'Reused app tree must match the pinned main source.'
fixture_sha = hashlib.sha256(pathlib.Path('ios/NextStopAppTests/ProfileRepositoryTests.swift').read_bytes()).hexdigest()
assert source.get('profileFixtureSHA256') == fixture_sha, 'Reused test bundle must contain the current persistent-profile fixture.'
archive = reuse / 'CarPlayBuild.tar.gz'
archive_sha = hashlib.sha256(archive.read_bytes()).hexdigest()
assert archive_sha == os.environ['CARPLAY_REUSE_SHA256'], 'Reused build archive digest does not match the verified artifact.'
source['archiveSHA256'] = archive_sha
pathlib.Path('CarPlay-Captures/reused-build-source.json').write_text(json.dumps(source, indent=2) + '\n')
shutil.copy2(archive, 'CarPlay-Captures/CarPlayBuild.tar.gz')
print(f'Reusing verified main build from {source["runURL"]}; archive SHA-256 {archive_sha}.')
PY
  mkdir -p CarPlayDerivedData/Build
  tar -xzf CarPlay-Captures/CarPlayBuild.tar.gz -C CarPlayDerivedData/Build
else
  xcodebuild \
    -project screenshot-app/ios/NextStop.xcodeproj \
    -scheme NextStopApp -configuration Debug \
    -destination "platform=iOS Simulator,id=$CARPLAY_DEVICE_ID" \
    -derivedDataPath CarPlayDerivedData \
    "-only-testing:NextStopAppTests/ProfileRepositoryTests/$test_method" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    build-for-testing | tee CarPlay-Captures/build.log

  # Preserve a successful build even if entitlement verification or UI setup fails.
  tar -czf CarPlay-Captures/CarPlayBuild.tar.gz -C CarPlayDerivedData/Build Products
fi
app=CarPlayDerivedData/Build/Products/Debug-iphonesimulator/NextStopApp.app
codesign -d --entitlements :- "$app" \
  > CarPlay-Captures/signature-entitlements.plist \
  2> CarPlay-Captures/codesign.log
python3 scripts/carplay-capture/read-simulator-entitlements.py \
  "$app/NextStopApp" CarPlay-Captures/applied-entitlements.plist

python3 - <<'PY'
import hashlib, json, os, pathlib, plistlib, subprocess
root = pathlib.Path('CarPlay-Captures')
preflight = json.loads((root / 'preflight.json').read_text())
display = preflight['carplayDisplay']
variants = json.loads(pathlib.Path('scripts/carplay-capture/display-variants.json').read_text())
variant = os.environ.get('CARPLAY_DISPLAY_VARIANT', 'default')
assert display == {'variant': variant, **variants[variant]}, 'Preflight must verify the requested native CarPlay geometry.'
entitlements = plistlib.loads((root / 'applied-entitlements.plist').read_bytes())
assert entitlements.get('com.apple.developer.carplay-charging') is True
source = {
    'appCommit': subprocess.check_output(['git', '-C', 'screenshot-app', 'rev-parse', 'HEAD'], text=True).strip(),
    'appTree': subprocess.check_output(['git', '-C', 'screenshot-app', 'rev-parse', 'HEAD:ios/NextStopApp'], text=True).strip(),
    'harnessCommit': os.environ['GITHUB_SHA'],
    'runURL': f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
    'device': 'iPhone 17 Pro with native external CarPlay display',
    'carplayDisplay': display,
    'locale': 'de_DE',
    'data': 'Example Leipzig profile seeded through the unchanged app persistence model by an opt-in hosted test in a fresh simulator store',
    'profileFixtureSHA256': hashlib.sha256(pathlib.Path('ios/NextStopAppTests/ProfileRepositoryTests.swift').read_bytes()).hexdigest(),
    'signing': 'Xcode simulator ad-hoc signing with the app source entitlement file unchanged',
    'entitlementsStorage': 'Verified directly in the built executable __TEXT,__entitlements Mach-O section; the simulator ad-hoc code-signature entitlement dictionary is recorded separately and may be empty',
    'appliedEntitlements': entitlements,
}
reused = root / 'reused-build-source.json'
if reused.exists():
    build_source = json.loads(reused.read_text())
    source['buildHarnessCommit'] = build_source.get('buildHarnessCommit', build_source['harnessCommit'])
    source['buildRunURL'] = build_source.get('buildRunURL', build_source['runURL'])
    source['reusedBuildArchiveSHA256'] = build_source['archiveSHA256']
else:
    source['buildHarnessCommit'] = source['harnessCommit']
    source['buildRunURL'] = source['runURL']
(root / 'capture-source-base.json').write_text(json.dumps(source, indent=2) + '\n')
# Explicitly opt in the generated test runner, without changing the application
# or its Xcode project. Tests outside this workflow skip profile preparation.
runs = list(pathlib.Path('CarPlayDerivedData/Build/Products').glob('*.xctestrun'))
assert len(runs) == 1, runs
run = plistlib.loads(runs[0].read_bytes())
targets = []
for configuration in run.get('TestConfigurations', []):
    targets.extend(configuration['TestTargets'])
if not targets:
    targets = [value for key, value in run.items() if not key.startswith('__') and isinstance(value, dict)]
found = False
for target in targets:
    if target.get('BlueprintName') == 'NextStopAppTests' or 'NextStopAppTests' in target.get('TestBundlePath', ''):
        target.setdefault('EnvironmentVariables', {})['NEXTSTOP_CARPLAY_CAPTURE'] = '1'
        target['CommandLineArguments'] = ['-AppleLanguages', '(de)', '-AppleLocale', 'de_DE']
        target['TestLanguage'] = 'de'
        target['TestRegion'] = 'DE'
        found = True
assert found, 'Generated xctestrun must contain the hosted app test target.'
runs[0].write_bytes(plistlib.dumps(run))
with open(os.environ['GITHUB_ENV'], 'a') as env:
    env.write(f'CARPLAY_XCTESTRUN={runs[0]}\n')
(root / 'xctestrun-path.txt').write_text(str(runs[0]))
PY

test_run="$(cat CarPlay-Captures/xctestrun-path.txt)"
if [ "$capture_mode" = results ]; then
  CARPLAY_SCREEN_TEXT="$RUNNER_TEMP/nextstop-screen-text" \
    python3 scripts/carplay-capture/results.py
else
TEST_RUNNER_NEXTSTOP_CARPLAY_CAPTURE=1 xcodebuild \
  -xctestrun "$test_run" \
  -destination "platform=iOS Simulator,id=$CARPLAY_DEVICE_ID" \
  -resultBundlePath CarPlaySetup.xcresult \
  -only-testing:NextStopAppTests/ProfileRepositoryTests/testPrepareCarPlayScreenshotProfile \
  -parallel-testing-enabled NO \
  test-without-building | tee CarPlay-Captures/profile-setup.log
fi

xcrun xcresulttool get test-results summary --path CarPlaySetup.xcresult \
  > CarPlay-Captures/profile-test-summary.json
python3 - <<'PY'
import json, pathlib
summary = json.loads(pathlib.Path('CarPlay-Captures/profile-test-summary.json').read_text())
assert summary['totalTestCount'] == 1 and summary['passedTests'] == 1 and summary['failedTests'] == 0
assert summary['skippedTests'] == 0, 'The persistent profile fixture must actually execute.'
PY
xcrun xcresulttool export attachments --path CarPlaySetup.xcresult \
  --output-path CarPlay-Captures/Profile-Setup-Attachments
test -x "$RUNNER_TEMP/nextstop-screen-text"
if [ "$capture_mode" = profiles ]; then
  CARPLAY_SCREEN_TEXT="$RUNNER_TEMP/nextstop-screen-text" \
    python3 scripts/carplay-capture/capture.py
fi
