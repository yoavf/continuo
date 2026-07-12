# Releasing

CI runs on every push/PR (`swift test`, an unsigned package, and a launch
smoke test — `Scripts/smoke-test.sh` hides `.build` and launches the packaged
app to prove it's self-contained, catching resource-bundle regressions that a
signature check alone misses). Pushing a
`vX.Y.Z` tag triggers `.github/workflows/release.yml`, which signs the app with
your Developer ID, notarizes it with Apple, staples the ticket, signs a Sparkle
update feed, and publishes `Continuo.dmg` plus `appcast.xml` to a GitHub release.
Installed copies read the latest release's appcast and update in place. Locally: `./Scripts/package-app.sh` then
`./Scripts/sign-and-notarize.sh` (needs the same env vars as the CI secrets).

Developer ID distribution needs no App ID registration or provisioning profile —
only a certificate and a notarization key. Add these repository secrets
(Settings → Secrets and variables → Actions):

| Secret | What it is | How to get it |
| --- | --- | --- |
| `DEVELOPER_ID_CERT_P12_BASE64` | Your "Developer ID Application" cert + key | Create it in Xcode → Settings → Accounts → Manage Certificates → **+ Developer ID Application**, then export from Keychain Access as a `.p12` with a password. Encode: `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_CERT_PASSWORD` | The `.p12` export password | You chose it during export |
| `AC_API_KEY_ID` | App Store Connect API **Key ID** | App Store Connect → Users and Access → Integrations → App Store Connect API → generate a key (Developer access) |
| `AC_API_ISSUER_ID` | The **Issuer ID** on that same page | — |
| `AC_API_KEY_P8_BASE64` | The `AuthKey_XXXX.p8` (downloadable once) | `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `SPARKLE_ED_PRIVATE_KEY` | Private Ed25519 key used only to sign update archives | Run Sparkle's `generate_keys --account continuo`, export it with `generate_keys --account continuo -x private-key`, then store the file contents as this secret. Keep an offline backup. |

The signing identity and team are read from the imported certificate — no team
ID needs to be configured separately.

## Cutting a release

```sh
git tag vX.Y.Z && git push origin vX.Y.Z
```

The workflow stamps the version from the tag into the app bundle, then signs,
notarizes, staples, generates the signed appcast, and publishes both files with
auto-generated notes. The feed is served without extra infrastructure through
`https://github.com/yoavf/continuo/releases/latest/download/appcast.xml`. A manual
`workflow_dispatch` run on `main` exercises the whole pipeline (and uploads the
DMG as an artifact) without publishing a release — useful for validation.
