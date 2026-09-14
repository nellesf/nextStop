#!/bin/bash
set -euo pipefail

# The workflow first checks out this exact main commit into screenshot-app and
# successfully connects the real external CarPlay display before reaching here.
app_commit=5fe2fa2332d66d2499fc679617855d41cb0111be
test "$(git -C screenshot-app rev-parse HEAD)" = "$app_commit"
cp ios/NextStopAppUITests/ProfileEditorUITests.swift \
  screenshot-app/ios/NextStopAppUITests/ProfileEditorUITests.swift
git -C screenshot-app diff --exit-code -- \
  ios/NextStopApp ios/NextStopCore ios/NextStopCarPlay ios/NextStop.xcodeproj ios/Config

mkdir -p CarPlay-Captures
xcodebuild \
  -project screenshot-app/ios/NextStop.xcodeproj \
  -scheme NextStopApp -configuration Debug \
  -destination "platform=iOS Simulator,id=$CARPLAY_DEVICE_ID" \
  -derivedDataPath CarPlayDerivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  build-for-testing | tee CarPlay-Captures/build.log

# Preserve a successful build even if entitlement verification or UI setup fails.
tar -czf CarPlay-Captures/CarPlayBuild.tar.gz -C CarPlayDerivedData/Build Products
app=CarPlayDerivedData/Build/Products/Debug-iphonesimulator/NextStopApp.app
codesign -d --entitlements :- "$app" \
  > CarPlay-Captures/signature-entitlements.plist \
  2> CarPlay-Captures/codesign.log
python3 scripts/carplay-capture/read-simulator-entitlements.py \
  "$app/NextStopApp" CarPlay-Captures/applied-entitlements.plist

python3 - <<'PY'
import json, os, pathlib, plistlib, subprocess
root = pathlib.Path('CarPlay-Captures')
entitlements = plistlib.loads((root / 'applied-entitlements.plist').read_bytes())
assert entitlements.get('com.apple.developer.carplay-charging') is True
source = {
    'appCommit': subprocess.check_output(['git', '-C', 'screenshot-app', 'rev-parse', 'HEAD'], text=True).strip(),
    'appTree': subprocess.check_output(['git', '-C', 'screenshot-app', 'rev-parse', 'HEAD:ios/NextStopApp'], text=True).strip(),
    'harnessCommit': os.environ['GITHUB_SHA'],
    'runURL': f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
    'device': 'iPhone 17 Pro with native external CarPlay display',
    'locale': 'de_DE',
    'data': 'Example Leipzig profile created through the normal app UI in a fresh simulator store',
    'signing': 'Xcode simulator ad-hoc signing with the app source entitlement file unchanged',
    'entitlementsStorage': 'Verified directly in the built executable __TEXT,__entitlements Mach-O section; the simulator ad-hoc code-signature entitlement dictionary is recorded separately and may be empty',
    'appliedEntitlements': entitlements,
}
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
    if target.get('BlueprintName') == 'NextStopAppUITests' or 'NextStopAppUITests' in target.get('TestBundlePath', ''):
        target.setdefault('EnvironmentVariables', {})['NEXTSTOP_CARPLAY_CAPTURE'] = '1'
        found = True
assert found, 'Generated xctestrun must contain the iPhone UI-test target.'
runs[0].write_bytes(plistlib.dumps(run))
with open(os.environ['GITHUB_ENV'], 'a') as env:
    env.write(f'CARPLAY_XCTESTRUN={runs[0]}\n')
(root / 'xctestrun-path.txt').write_text(str(runs[0]))
PY

test_run="$(cat CarPlay-Captures/xctestrun-path.txt)"
TEST_RUNNER_NEXTSTOP_CARPLAY_CAPTURE=1 xcodebuild \
  -xctestrun "$test_run" \
  -destination "platform=iOS Simulator,id=$CARPLAY_DEVICE_ID" \
  -resultBundlePath CarPlaySetup.xcresult \
  -only-testing:NextStopAppUITests/ProfileEditorUITests/testPrepareCarPlayProfile \
  -parallel-testing-enabled NO \
  test-without-building | tee CarPlay-Captures/profile-setup.log

xcrun xcresulttool export attachments --path CarPlaySetup.xcresult \
  --output-path CarPlay-Captures/Profile-Setup-Attachments
xcrun swiftc scripts/carplay-capture/screen-text.swift \
  -o "$RUNNER_TEMP/nextstop-screen-text"
CARPLAY_SCREEN_TEXT="$RUNNER_TEMP/nextstop-screen-text" \
  python3 scripts/carplay-capture/capture.py
