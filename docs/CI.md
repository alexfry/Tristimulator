# CI and releases

GitHub Actions builds Tristimulator on a hosted Apple Silicon Mac. The build and test workflow does not use Apple secrets. The release workflow does.

## Workflows

| Workflow | When it runs | What it does |
| --- | --- | --- |
| CI (`.github/workflows/ci.yml`) | Pull requests, pushes to `main`, and **Run workflow** | vcpkg install, then `xcodebuild test` for the `Tristimulator` scheme |
| Release (`.github/workflows/release.yml`) | Push a tag such as `v1.2.3`, or **Run workflow** with that tag | Release archive, Developer ID sign, notarize, and staple a DMG, then upload it and attach it to a **draft** GitHub Release. If stapling fails, the notarized DMG is still attached to a draft marked unstapled and the job fails |

CI does not run on pushes to other branches. A pull request from one of those branches still runs CI.

Doc-only changes do not start CI: `*.md`, `docs/`, `LICENSE`, `ThirdPartyNotices/`, and `.gitignore`. A new commit on the same pull request or on `main` cancels the older run.

## Runner and Xcode

The job label is `xcode-27`, the runner image with macOS 27 (image `20261104.0337.1`). Its default Xcode is 27.1, but `Scripts/ci_prepare_runner.sh` pins **Xcode 27.2** (build `27B52`) at `/Applications/Xcode_27.2.app` with `xcode-select` and `DEVELOPER_DIR`, so the compiler does not change when the image default does. The script fails if the macOS SDK is older than 26.4.

Xcode 27.2 is required for two project settings:

- `ASSETCATALOG_COMPILER_APPICON_NAME = NewIcon2_v006_DarkOnly` compiles the Icon Composer bundle `Tristimulator/NewIcon2_v006_DarkOnly.icon`. `Scripts/ci_prepare_runner.sh` explains that the app icon was saved by Icon Composer in Xcode 27 and uses settings that crash Xcode 26.6's `actool`, so the build uses Xcode 27.2.
- `TristimulatorQuickLook` sets `MACOSX_DEPLOYMENT_TARGET = 26.4`, so the SDK must be 26.4 or newer. Xcode 27.2 satisfies that.

The standard runner is a 3-core M1 with 7 GB of RAM and a small disk, billed at **$0.062 per minute**. vcpkg is capped at two concurrent compiles so the OpenImageIO and libjxl links are less likely to be killed. If free disk is under 20 GB, the job deletes the other Xcode copies and the Android SDK before compiling. Larger macOS runners are not available on a GitHub Pro plan.

## Third-party cache

`Scripts/build_thirdparty.sh` installs the static libraries from `vcpkg.json` into `~/Library/Caches/Tristimulator/ThirdParty`. vcpkg binary caching uses the GitHub Actions cache (`VCPKG_BINARY_SOURCES=clear;x-gha,readwrite`). Each port is stored as its own cache entry. Build trees, downloaded sources, and the installed prefix are not stored again, so a manifest change does not upload a second full copy of the same binaries.

The repository cache limit is 10 GB. A current OpenColorIO / OpenImageIO / OpenEXR / libjxl static set should land around 1–3 GB. GitHub drops the least recently used entries if a later baseline bump pushes the repo over 10 GB. The next build then recompiles the ports that were evicted.

Pull requests from the same repository can fill the cache. A pull request from a fork can only read it. Caches written on a pull request are not copied to `main` when the pull request merges, so the first `main` build after a merge can be cold again.

The Xcode project still has header and library search paths under `/Users/alex/Library/Caches/Tristimulator/...`, and `ThirdParty.xcconfig` is not the target's base configuration. CI symlinks that location at the runner's cache and also passes the prefix with `xcodebuild -xcconfig`. The link line CI uses is the one `Scripts/build_thirdparty.sh` writes to `Generated/ThirdParty.generated.xcconfig` (every static archive in the install prefix), plus the SDK libraries `-lcompression` and `-liconv`. The project's own `-l` list is checked first so a renamed archive fails before `xcodebuild`, but that list is not what gets linked: the first run showed it omits bzip2, zstd, and lzma, which `libminizip-ng` and `libtiff` need. Those three flags are now in the Xcode project as well.

## Rough cost

The standard rate is $0.062 per minute. The first CI run on `macos-26` built the third-party libraries and compiled the app in about 13 minutes, then failed at the link. A cold run that gets through the tests should land near that, not the earlier 45–90 minute guess. The "~3 minutes" line in the app README is a local incremental build.

| Run | Minutes | Cost |
| --- | --- | --- |
| CI, cold, measured through the first link failure | ~13 | ~$0.80 |
| CI, cold, once the link succeeds and tests run | 15–25 | $0.95–$1.55 |
| CI, warm binary cache | 10–20 | $0.60–$1.25 |
| Release, warm cache, including notarization | 20–40 | $1.25–$2.50 |

A job that hangs is stopped at 180 minutes (CI) or 210 minutes (release).

## Release secrets

Create these as **repository** Actions secrets (Settings → Secrets and variables → Actions → Repository secrets). Do not use an environment that waits for approval unless you want tag builds to pause. Do not commit the `.p12`, the `.p8`, or any of these values.

The Xcode project team is `8R4GM92NHK`. `APPLE_TEAM_ID` should be that team if the Developer ID certificate belongs to it.

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_CERT_P12_BASE64` | Developer ID Application certificate and private key, exported as a `.p12`, then base64 |
| `DEVELOPER_ID_CERT_PASSWORD` | Password you chose in that export |
| `APPLE_TEAM_ID` | 10-character Team ID from [developer.apple.com/account](https://developer.apple.com/account) → Membership details |
| `ASC_KEY_ID` | App Store Connect API key id (10 characters) |
| `ASC_ISSUER_ID` | Issuer UUID at the top of the App Store Connect API page |
| `ASC_KEY_P8_BASE64` | The downloaded `AuthKey_XXXXXXXXXX.p8`, base64 |
| `KEYCHAIN_PASSWORD` | A password you invent for the temporary keychain on the runner. Not an Apple ID password. `openssl rand -base64 32` is fine |

The release job stops immediately, with the missing names in the log, if any of these are unset or the wrong shape. It does that before the vcpkg build.

### Developer ID `.p12`

1. Open Keychain Access. Choose the login keychain and **My Certificates**.
2. Find **Developer ID Application: Your Name (TEAMID)**. It has to be Developer ID Application, not Apple Development and not Mac App Distribution.
3. Expand the certificate so the private key is visible. Select the certificate and the private key together.
4. File → Export Items…. Format: Personal Information Exchange (`.p12`). Set a password. That password is `DEVELOPER_ID_CERT_PASSWORD`.
5. In Terminal, copy the base64 onto the clipboard and paste it into `DEVELOPER_ID_CERT_P12_BASE64`:

   ```bash
   base64 -i ~/Desktop/DeveloperID.p12 | pbcopy
   ```

6. Delete the `.p12` from the Desktop after the secret is saved.

### App Store Connect API key

Notarization uses `xcrun notarytool` with an API key. An app-specific password is not used.

1. Open [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api).
2. Create a **Team** key with the **Developer** role. Admin also works. App Manager cannot notarize.
3. Download `AuthKey_XXXXXXXXXX.p8`. Apple only allows that download once. The key id shown on the row is `ASC_KEY_ID`. The issuer UUID at the top of the page is `ASC_ISSUER_ID`.
4. Encode the key:

   ```bash
   base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8 | pbcopy
   ```

   Paste that into `ASC_KEY_P8_BASE64`.
5. Delete the `.p8` from Downloads after the secret is saved.

## What the release uploads

The asset is `Tristimulator-v1.2.3.dmg` (the tag you pushed). For a plain `vMAJOR.MINOR.PATCH` tag, the archive's `MARKETING_VERSION` is set from the tag. Other suffixes, such as `v1.2.3-rc1`, keep the version already in the Xcode project.

`CURRENT_PROJECT_VERSION` (10) and `MARKETING_VERSION` (1.0) are set on the Xcode project. The Tristimulator app and the TristimulatorQuickLook extension both inherit them, so the extension's `CFBundleVersion` matches the app. The test targets keep their own version numbers.

The app is archived without a signature, then signed inside-out: nested frameworks, dylibs, and other bundles first, then `TristimulatorQuickLook.appex` with `TristimulatorQuickLook/TristimulatorQuickLook.entitlements`, then `Tristimulator.app` with `Tristimulator/Tristimulator.entitlements`. Every Mach-O signature uses Developer ID Application, `--options runtime`, and a timestamp. The DMG is signed and submitted to notarytool. The app is not notarized on its own, so it is not stapled before the DMG is built.

### Certificate trust on the runner

Apple Root CA - G3 is already in System Roots on the `macos-26` image. The release script leaves that root where it is. It does not download a second copy, and it does not call `security add-trusted-cert` on that root or on the WWDR and Developer ID intermediates.

`security add-certificates` only adds a certificate to a keychain. `security add-trusted-cert` writes trust settings. Admin trust on Apple's roots, or a duplicate Apple Root CA - G3 next to the System Roots copy, makes `stapler` fail with Error 65 and the text `Could not validate ticket`. Stapler found a ticket and rejected it during local trust evaluation. That return is a fraction of a second. It is a different failure from a ticket that is not on Apple's CDN yet, which logs `Record not found` and takes longer. The v0.1.0 release runs hit the trust-evaluation form: notarytool returned Accepted, then every staple attempt exited in about 0.2 seconds with `Could not validate ticket`.

`security find-identity` still has to accept the Developer ID Application certificate. When it does, nothing else is imported. When it does not, the script imports the WWDR and Developer ID intermediate certificates into the temporary signing keychain with `security add-certificates`, after that keychain exists. The temporary keychain is deleted at the end of the job. System trust settings are left unchanged.

Before stapling, the log includes `security dump-trust-settings` and `security dump-trust-settings -d`. Those listings are noisy and do not contain the signing private key. The staple command is `xcrun stapler staple -v`, so the log shows whether the ticket was downloaded (`Downloaded ticket has been stored`), was not on the CDN yet (`Record not found`), or failed validation (`Could not validate ticket`).

### Stapling

On a GitHub Actions macOS runner the script blocks outbound UDP port 443 before stapling, which forces `stapler` onto HTTPS over TCP. That is the workaround in [actions/runner-images#14924](https://github.com/actions/runner-images/issues/14924) for stapler Error 68 (HTTP/3 to CloudKit being dropped). Both `GITHUB_ACTIONS` and `RUNNER_OS` have to say this is a GitHub Actions macOS runner. A developer Mac is left alone. If `pfctl` fails, the log has a warning and the job continues.

notarytool can report Accepted before Gatekeeper can see the ticket. Each attempt runs `xcrun spctl --assess --type open --context context:primary-signature --ignore-cache`. The first attempt also runs `xcrun stapler staple -v` immediately, so a trust-evaluation failure is in the log before any sleep. Later attempts staple once that assessment succeeds. The last attempt staples once more if Gatekeeper never accepts the DMG on the runner. Sleep between the six attempts is 15, 30, 60, 120, and 240 seconds (about eight minutes). That is the same shape as Node's `tools/osx-notarize.sh`, and it is the whole retry budget. `Record not found` stays inside that budget. `Could not validate ticket` without `Record not found` stops the loop on the attempt that produced it, because another wait will fail the same way.

When the staple succeeds, `xcrun stapler validate` has to succeed. `spctl` on the runner is logged either way, because Gatekeeper on the hosted Mac can still disagree after a valid staple.

If stapling still fails, the signed, notarized DMG is uploaded and attached to a **draft** GitHub Release. The release title is `Tristimulator v1.2.3 (UNSTAPLED - do not publish)` and the notes repeat that warning. The workflow artifact name gains an `-unstapled` suffix (`Tristimulator-v1.2.3-unstapled`); the file inside is still `Tristimulator-v1.2.3.dmg`. The package step records `stapled=false`. A later step then fails the job, so the run is not green. A published release is not created. If that tag already had a published release, the unstapled upload moves it back to a draft before replacing the asset.

Publish a draft from the Releases page only after installing the DMG on a Mac and confirming Gatekeeper. Leave an unstapled draft unpublished.
