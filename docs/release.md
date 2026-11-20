# Release

Maintainer notes for publishing Droves. The workflow is
[`.github/workflows/release.yml`](../.github/workflows/release.yml); it runs on a
`v*` tag and publishes APKs, an unsigned IPA, the bridge binaries, the web build
and two generated manifests as GitHub Release assets.

## Versioning

`pubspec.yaml` carries `version: <name>+<number>`. The name is what users see;
the number must increase on every build so Android and iOS recognise a new one.
For local builds that number is taken from pubspec directly. Release builds
override both from the tag and run number:

```sh
flutter build apk --release --split-per-abi \
  --build-name="${GITHUB_REF_NAME#v}" --build-number="$GITHUB_RUN_NUMBER"
```

The bridge binary gets the same name injected with
`-ldflags "-X main.bridgeVersion=…"`. Without these overrides a tagged release
keeps reporting the pubspec version and the in-app update prompt never clears.
Bump `pubspec.yaml` anyway when tagging, so source builds do not collide with a
previous one.

Asset filenames are stable (`droves-arm64.apk`, `droves.ipa`, `droves-web.tar.gz`,
`droves-bridge-<os>-<arch>`, …). `update.json` and `source.json` are generated
from the tag by the publish job, so a release never ships a manifest pointing at
the previous version. Both installers use the `releases/latest/download/<asset>`
URL and verify `SHA256SUMS.txt` before installing.

## Android signing

Published APKs must be signed with a stable upload key. A debug key is generated
per machine, so a debug-signed release cannot be upgraded in place by any later
build — Android rejects the signature mismatch and the user has to uninstall
first. That defeats the in-app update flow entirely.

`android/app/build.gradle.kts` reads `android/key.properties` when it exists and
falls back to the debug key otherwise, so local `flutter build apk --release`
keeps working without any secret. The release workflow refuses to build when the
signing secrets are missing, and fails again if the resulting APK turns out to be
debug-signed.

Create the key once, outside the repo:

```sh
keytool -genkeypair -v -keystore ~/droves-upload.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias droves
```

Then add four repository secrets:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 ~/droves-upload.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore password |
| `ANDROID_KEY_ALIAS` | `droves` |
| `ANDROID_KEY_PASSWORD` | the key password |

Keep `~/droves-upload.jks` and its passwords backed up offline. Losing the key
means no future build can update an installed copy, and the Play Store will not
accept a replacement for the same application ID.

For a local signed build, write `android/key.properties` yourself:

```properties
storeFile=/absolute/path/to/droves-upload.jks
storePassword=…
keyAlias=droves
keyPassword=…
```

Both the keystore and `key.properties` are gitignored; no credential is committed.

## iOS

The `ios` job makes an **unsigned** IPA. SideStore or AltStore re-signs it with
the user's own certificate, so signing it here would only fit one device. The
publish job also generates `source.json` in AltStore/SideStore source format,
pointing at the IPA. See the [README](../README.md#ios-without-the-app-store)
for the user-facing steps and the free-account limits.

## License assets

Fonts in `assets/fonts/` are OFL-1.1. `assets/fonts/OFL.txt` must stay in
`flutter.assets` in `pubspec.yaml` and be registered through `LicenseRegistry`
in `lib/main.dart`, so the notice travels inside every APK, IPA and web build.
`LICENSE` and `NOTICE` cover the code; see the [License section](../README.md#license).
