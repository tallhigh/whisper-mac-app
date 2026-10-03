# Building, signing and releasing

Target: Apple Silicon (arm64). Distribution: a `.dmg` signed with a Developer ID,
notarized and stapled → GitHub Releases. No App Store, no sandbox.

## Verified environment (2026-10-01)

| Component | Version / value |
|---|---|
| Machine | Apple Silicon (arm64), macOS 27.0 (26A428) |
| Xcode | 26.4 (17E192), Swift 6.3 |
| XcodeGen | 2.46.0 — the project is generated from `app/project.yml` (ADR-011) |
| notarytool | 1.1.1 (40) — `xcrun notarytool` |
| Signing identity | `Developer ID Application: Talha Turhan (AL9CGWVTYB)` |
| Certificate validity | 2026-09-10 → **2027-02-01** (coincides with the membership renewal date; renew before it lapses) |
| Team ID | `AL9CGWVTYB` |
| Deployment target | macOS 14.4 — the Core Audio process-tap API arrived in 14.2 and the capture permission flow settled in 14.4 |
| Architecture | `arm64` (Intel is not targeted) |

Checking the certificate: `security find-identity -v -p codesigning`

## Prerequisites (one-off)

### 1. Notarization credentials
At appleid.apple.com → Sign-In and Security → **App-Specific Passwords**, generate a
password (not your account password), then:

```bash
xcrun notarytool store-credentials "WHISPER_NOTARY" \
  --apple-id "your-apple-id@example.com" \
  --team-id "AL9CGWVTYB" \
  --password "xxxx-xxxx-xxxx-xxxx"
```
The password is written to the keychain; it is stored nowhere in the repository. The
scripts only ever use the name `--keychain-profile WHISPER_NOTARY`.

If you run it without `--password`, it asks for the password at a secure prompt; that
is the preferred route, so it never reaches your shell history.

Verification — this should return an empty list without erroring:
```bash
xcrun notarytool history --keychain-profile "WHISPER_NOTARY"
```

### 2. The Sparkle signing key

Updates carry a second signature besides Apple's: an Ed25519 signature the installed app
checks against `SUPublicEDKey` before it will install anything (ADR-020). Generate the pair
once:

```bash
make bootstrap                      # fetches Sparkle's tools into vendor/
./vendor/sparkle/bin/generate_keys  # prints the public key, stores the private one
```

The **private** key goes into the keychain and nowhere else — not into the repository, not
into `scripts/local.env`. The **public** key it prints belongs in `app/project.yml` under
`SUPublicEDKey`; it is public by design and is committed.

To read the public key again later: `./vendor/sparkle/bin/generate_keys -p`

> **Back this key up with the Developer ID certificate.** Losing it means no copy already
> installed will ever accept another update — users would have to download the app by hand
> again. `make_appcast.sh` refuses to build a feed if the key in the built bundle is not the
> counterpart of the one in the keychain, so a mismatch stops the release instead of
> shipping an update nothing accepts.

### 3. GitHub access
```bash
gh auth login
```

### 4. Local variables
`scripts/local.env` (not committed; `scripts/local.env.example` is the template kept in
the repository):
```sh
SIGN_IDENTITY="Developer ID Application: Talha Turhan (AL9CGWVTYB)"
TEAM_ID="AL9CGWVTYB"
NOTARY_PROFILE="WHISPER_NOTARY"
GH_REPO="<user>/whisper-mac-app"
```

## Embedded binaries

The `uv` binary is copied into the `.app`. Executables go under
**`Contents/MacOS/`** rather than `Resources/` (that's where Apple expects them;
otherwise notarization can report an "unsealed contents" warning):

- Repository path: `app/WhisperTranscriber/Resources/bin/uv` (not committed,
  `make bootstrap` downloads it)
- Bundle path: `WhisperTranscriber.app/Contents/MacOS/uv` (an Xcode "Copy Files"
  phase, destination: Executables)
- The Swift side finds it with `Bundle.main.url(forAuxiliaryExecutable: "uv")`

Nested binaries are signed **inside-out**: `uv` first, then the `.app`.
`codesign --deep` is not used (Apple doesn't recommend it and it hides errors).

> **Verified in Phase 0:** Xcode does **not** re-sign the `uv` copied by the Copy Files
> phase — Astral's signature (`TeamIdentifier=2DC432GLL2`) stays exactly as it was.
> Even though the bundle's own signature looks valid, re-signing `uv` with our own
> Developer ID before release is **mandatory**:
> ```bash
> codesign --force --options runtime --timestamp \
>   --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/uv"
> ```
> Skip this step and notarization fails over the mixed team identifier.

## Entitlements

`WhisperTranscriber.entitlements` holds exactly **one** entitlement. Hardened Runtime
is on (a notarization requirement) and nothing else is granted:

```xml
<key>com.apple.security.device.audio-input</key><true/>
```

The microphone entitlement was added against measured evidence: without it, under
Hardened Runtime the system denies access **without showing the TCC prompt at all** and
the app doesn't even appear in the Privacy list (ADR-016). System audio capture needs
no entitlement.

Nothing else is granted, because torch's and numba's JIT runs in a separate Python
child process, not in ours. That child process has its own signing context and does not
inherit our entitlements — which is why `allow-jit` and `disable-library-validation` are
**not needed**. App Sandbox is not added; adding it would break writing to the folders
the user chooses.

If a genuine runtime failure ever requires one, write the failure and the fix into
`docs/DECISIONS.md` as an ADR and then add it — entitlements are never added "just in
case" (ADR-007).

## Verified release round (2026-10-01, v0.1.0)

The pipeline was run end to end on this machine:

| Step | Command | Result |
|---|---|---|
| Archive + export + sign | `make archive` | `dist/export/WhisperTranscriber.app` — 36 MB, `flags=0x10000(runtime)`, team `AL9CGWVTYB` |
| Notarizing the app | `make notarize` | `status: Accepted` (~40 s), `stapler validate` passes |
| dmg + notarization + Gatekeeper | `make dmg` | `WhisperTranscriber-0.1.0.dmg` — **18 MB**, `Accepted`, stapled |
| Gatekeeper | `spctl -a -t install` | `accepted · source=Notarized Developer ID` |
| Quarantine (downloaded-file) test | inside `make dmg` | both the dmg **and** the app inside it `accepted` |
| Re-signed embedded binary | `…/Contents/MacOS/uv --version` | `uv 0.12.21` — works |

Bundle contents (this and nothing more):

```
Contents/MacOS/WhisperTranscriber
Contents/MacOS/uv
Contents/Resources/python/whisper_worker.py
Contents/Resources/python/requirements.txt
Contents/Info.plist
```

Expected `.dmg` size: **~18 MB**. If a model or the Python environment had made it into
the bundle, `make dmg` would stop at its 50 MB threshold.

### Why notarization happens twice

The `.app` is notarized and stapled first, and the dmg is produced and notarized
**afterwards**. Stamping only the dmg is not enough: when the user copies the app from
the dmg into Applications, if the `.app` has no ticket of its own, Gatekeeper falls back
to online verification and — with no internet — reports "app is damaged and can't be
opened". `make dmg` refuses to start if the `.app` isn't stamped.

## The steps

### Build and archive

The project is generated before archiving (the `.xcodeproj` isn't kept in git):

```bash
cd app && xcodegen generate --spec project.yml && cd ..
```

```bash
xcodebuild -project app/WhisperTranscriber.xcodeproj \
  -scheme WhisperTranscriber -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath dist/WhisperTranscriber.xcarchive \
  archive
```

```bash
xcodebuild -exportArchive \
  -archivePath dist/WhisperTranscriber.xcarchive \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath dist/export
```

`scripts/ExportOptions.plist`:
```xml
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>AL9CGWVTYB</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
```
> Xcode 15.3 renamed the values of the export `method` key. If `developer-id` isn't
> accepted on Xcode 26, read the valid value from
> `xcodebuild -help | grep -A20 exportOptionsPlist` and update this file.

### Signature verification
```bash
codesign --verify --deep --strict --verbose=2 dist/export/WhisperTranscriber.app
codesign -dv --verbose=4 dist/export/WhisperTranscriber.app   # the Runtime flag must appear
```
`Contents/MacOS/uv` is additionally verified on its own.

### Building the DMG
The `.app` is copied into a staging folder with **ditto** (`cp -R` can drop some xattrs
and break the signature) and an `/Applications` symlink is placed beside it:

```bash
mkdir -p dist/dmg-stage
ditto dist/export/WhisperTranscriber.app dist/dmg-stage/WhisperTranscriber.app
ln -s /Applications dist/dmg-stage/Applications

hdiutil create -volname "Whisper Transcriber" \
  -srcfolder dist/dmg-stage \
  -ov -format UDZO dist/WhisperTranscriber-$VERSION.dmg

codesign --force --sign "$SIGN_IDENTITY" --timestamp dist/WhisperTranscriber-$VERSION.dmg
```
That way, when the user opens the dmg they can drag the app onto the `Applications`
shortcut beside it. `create-dmg` is not installed and isn't needed; if a window with a
custom background and positioned icons is ever wanted, it gets added in Phase 6 (see
PLAN.md).

### Notarization
```bash
xcrun notarytool submit dist/WhisperTranscriber-$VERSION.dmg \
  --keychain-profile "WHISPER_NOTARY" --wait

xcrun stapler staple dist/WhisperTranscriber-$VERSION.dmg
xcrun stapler validate dist/WhisperTranscriber-$VERSION.dmg
```
On failure, reading the log is mandatory:
```bash
xcrun notarytool log <submission-id> --keychain-profile "WHISPER_NOTARY"
```

### Gatekeeper verification (the last check before release)
```bash
spctl -a -vvv -t install dist/WhisperTranscriber-$VERSION.dmg
# then, with the dmg mounted:
spctl -a -vvv -t exec /Volumes/Whisper\ Transcriber/WhisperTranscriber.app
```
**Clean-machine test:** mark the dmg as if it had been downloaded and open it —
`xattr -w com.apple.quarantine "0081;0;Safari;" <dmg>` — it must open with no Gatekeeper
warning. This test is run for every release; skip it and the user gets the "app is
damaged and can't be opened" error.

### GitHub Release
```bash
gh release create "v$VERSION" \
  dist/WhisperTranscriber-$VERSION.dmg \
  --title "v$VERSION" --notes-file dist/RELEASE_NOTES.md
```
`make release VERSION=0.1.0` does all of the above in order and stops at the first
failing step (`set -euo pipefail`).

## Versioning

- `MARKETING_VERSION` = `X.Y.Z`, `CURRENT_PROJECT_VERSION` = a monotonically increasing
  build number.
- Both live in `app/Version.xcconfig` rather than in the Xcode project; `make release`
  updates that file, commits it and creates the `vX.Y.Z` tag.
- Release notes are generated into `dist/RELEASE_NOTES.md` from the conventional commits
  since the last tag.

## Known pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| "The application is damaged and can't be opened" | stapling wasn't done, or notarization failed | run `stapler validate`; re-notarize the dmg |
| Notarization: "The binary is not signed with a valid Developer ID" | the embedded `uv` is unsigned | sign `uv` **before** the `.app` |
| Notarization: "not signed with hardened runtime" | `--options runtime` is missing | `ENABLE_HARDENED_RUNTIME=YES` in Xcode, `--options runtime` when signing manually |
| The child process starts and dies immediately | the quarantine xattr on provisioned files | run `xattr -dr com.apple.quarantine <runtime>` after setup (PYTHON_RUNTIME.md, step 5) |
| `xcodebuild` can't find the signature | the keychain is locked (in automation) | `security unlock-keychain`, or run it by hand locally |
| `store-credentials` → **HTTP 403: A required agreement is missing or has expired** | the Apple Developer Program License Agreement hasn't been signed, or has been updated | sign in to developer.apple.com/account as the **Account Holder** and accept it from the "Review Agreement" banner at the top. Propagation can take a few minutes. Nothing to do with the code, the certificate or the password. |
| Notarization suddenly starts returning 403 | the membership has expired, or the agreement was renewed | check the membership date under Membership details |
| The dmg comes out at ~2 GB | the runtime or a model accidentally made it into the bundle | audit the `Copy Bundle Resources` phase; the dmg must not exceed 50 MB |
| A script says "the Hardened Runtime flag is missing" while `codesign -dv` shows the flag | the `codesign … \| grep -q` pattern: `grep` closes the pipe at the first match, `codesign` dies with SIGPIPE, and `set -o pipefail` counts that as a failure | capture the output into a variable (`INFO="$(codesign … 2>&1)"`) and search the variable. `scripts/sign.sh` and `scripts/make_dmg.sh` are written that way |
| `hdiutil attach … is deprecated` warning | macOS 27 recommends `diskutil image attach` | A warning only; `hdiutil` keeps working. It is kept so the project still builds on older macOS |
| `Localizable.xcstrings` doesn't appear in the bundle | the catalog contains only the source language (en) and the keys are already the English text itself, so the compiler finds no translation to absorb and emits no output | Expected behaviour. At runtime the key is used = the correct English text. If another language is added, `<lang>.lproj/Localizable.strings` appears |

Expected `.dmg` size: **~18 MB** (the app plus the embedded `uv`; measured 2026-10-01).
Noticeably larger than that means something is wrong; `make dmg` stops above 50 MB.

## The scripts

| File | Job |
|---|---|
| `scripts/common.sh` | Shared paths, reading `local.env`, `say/warn/die`, reading the version. Not run directly |
| `scripts/archive.sh` | `xcodegen` → `archive` → `exportArchive` → `sign.sh` |
| `scripts/sign.sh` | Signs the embedded `uv`, then the `.app`; verifies Hardened Runtime and that the team identifiers match |
| `scripts/notarize.sh` | Submits the `.app` (zipped with ditto) or the `.dmg`, `--wait`, staples the ticket. Prints the notarization log if the result isn't `Accepted` |
| `scripts/make_dmg.sh` | Builds the dmg from the stamped `.app`, signs it, notarizes it, runs the Gatekeeper + quarantine tests, checks the size limit |
| `scripts/release_notes.sh` | Generates the release notes from the conventional commits since the last tag |
| `scripts/release.sh` | Checks for a clean tree, main, and a `gh` login → test → write the version → archive → notarize → dmg → tag → `gh release create`. The tag is created **last** |
