# CI / Release workflows

## `build.yml` — CI Build

Runs on pushes to `main`, on every pull request, and on demand
(**Actions → CI Build → Run workflow**).

Jobs:

| Job | What it does |
| --- | --- |
| Analyze & Test | `flutter pub get`, drift codegen, `flutter analyze`, `flutter test` |
| Android APK | Builds a release APK, uploaded as the `cashew-apk-<sha>` artifact |
| Web | Builds the web release, uploaded as the `cashew-web-<sha>` artifact |

Download an APK from the **Artifacts** section at the bottom of a completed
run's summary page to sideload it onto a device.

The three jobs are independent, so a failing test still leaves you with an
installable APK to test.

## `release.yml` — Release

Triggered by pushing a version tag:

```sh
git tag v5.4.3
git push origin v5.4.3
```

It runs the test suite, then builds a universal APK, per-ABI APKs, and an
`.aab` App Bundle, and publishes them to a GitHub Release named after the tag.
A tag containing a hyphen (e.g. `v5.5.0-beta1`) is published as a pre-release.

When the tag looks like `v<major>.<minor>.<patch>`, that version is passed to
Flutter as `--build-name`, so the released binary's version matches the tag.
Otherwise the version from `budget/pubspec.yaml` is used. The build number
always comes from `pubspec.yaml`.

You can also re-run it for an existing tag via
**Actions → Release → Run workflow**.

## Android signing

`budget/android/app/build.gradle` always reads its release signing config from
`budget/android/key.properties`, which is gitignored and therefore absent in
CI. Both workflows create that file before building.

**Without secrets configured** (the default), a throwaway keystore is generated
on each run. The builds are installable and fine for testing, but:

- every build is signed with a *different* key, so you must uninstall a
  previous CI build before installing a new one, and
- the resulting `.aab` cannot be uploaded to the Play Store.

**To sign with your real upload key**, add these repository secrets under
**Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `base64 -i your-keystore.jks` (the whole file, base64-encoded) |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_ALIAS` | Key alias |
| `ANDROID_KEY_PASSWORD` | Key password |

Both workflows pick these up automatically when present.

## iOS

Not built in CI. `ios/Runner.xcodeproj` uses automatic code signing with a
specific `DEVELOPMENT_TEAM`, so producing an installable `.ipa` would require
uploading an Apple distribution certificate and provisioning profile as
secrets, and macOS runners cost 10× the Actions minutes of Linux ones.

## Versions

The Flutter and Java versions are pinned at the top of each workflow:

```yaml
env:
  FLUTTER_VERSION: "3.24.5"
  JAVA_VERSION: "17"
```

Java 17 is required by the project's Android Gradle Plugin 7.3.1 / Gradle 7.5
combination. Flutter is held below 3.29 because `android/app/build.gradle`
still uses the legacy `apply from: "$flutterRoot/.../flutter.gradle"` plugin
style, which newer Flutter releases removed.

## Codegen

Every job runs `dart run build_runner build --delete-conflicting-outputs`
before building. `budget/lib/database/tables.g.dart` is committed but can
easily fall out of sync with `tables.dart`, so CI regenerates it rather than
trusting the checked-in copy.
