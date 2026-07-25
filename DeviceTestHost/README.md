# DeviceTestHost

Hosts the SPM `VelocityUITests` bundle so it can run on a physical iOS device.
`swift test` alone cannot execute on-device; this app target gives the test
bundle somewhere to attach to (see the `VelocityUITests` scheme below).

## Setup

`DeviceTestHost.xcodeproj` is a **generated build artifact** — it is not
checked in (see `.gitignore`). The checked-in source of truth is
`project.yml` ([XcodeGen](https://github.com/yonaskolb/XcodeGen) spec).
Generate the project before opening it in Xcode or running tests:

```sh
brew install xcodegen   # once
cd DeviceTestHost
xcodegen generate
```

Re-run `xcodegen generate` any time a file is added, removed, or moved under
`Tests/VelocityUITests` (in the root package) or `DeviceTestHost/Sources` —
the project picks it up automatically, no manual pbxproj editing.

## Running tests on a physical device

```sh
xcodebuild test \
  -project DeviceTestHost.xcodeproj \
  -scheme VelocityUITests \
  -destination 'platform=iOS,id=<device-udid>'
```

The `VelocityUITests` scheme is wired to `VelocityUITests.xctestplan` as its
default test plan — the scheme name must stay exactly `VelocityUITests`,
other tooling in this repo depends on it.
