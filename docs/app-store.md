# Mac App Store build

SaySo ships two ways from the same code:

- **Direct download** (DMG and Homebrew): notarized, updates itself with Sparkle.
- **Mac App Store**: built with `SAYSO_APPSTORE=1`. It runs in the App Sandbox, has no Sparkle, and
  leaves out what the sandbox forbids: Apple Notes tools, resetting macOS permissions, «Erase
  everything» and Accessibility. Combo shortcuts use a system hotkey instead of an event tap that
  swallows keys.

## Try it locally

```bash
scripts/make-appstore.sh
```

This builds `build/SaySo Store.app` with its own bundle ID (`com.pepebits.sayso.store`), so its
data (in its sandbox container), keychain items and macOS permissions stay apart from the regular
app. Both can run at once.

## Package it for App Store Connect

Once, in the Apple Developer account:

1. **Certificates** (Certificates, Identifiers & Profiles → Certificates): create an
   *Apple Distribution* and a *Mac Installer Distribution* certificate and install both in the
   login keychain.
2. **App ID**: register the bundle ID with the capabilities it uses (none beyond the defaults).
3. **Provisioning profile**: create a *Mac App Store Connect* distribution profile for that App ID
   and download it.
4. **App Store Connect**: create the macOS app record with the same bundle ID.

Then, for each upload (raise `CFBundleVersion` in `scripts/Info.plist` first):

```bash
SAYSO_PROFILE=/path/to/SaySo_AppStore.provisionprofile scripts/package-appstore.sh
```

The script builds a release, embeds the profile, signs with the distribution certificate, checks
the sandbox entitlement and the absence of Sparkle, and writes
`build/appstore/SaySo-<version>-<build>.pkg`. Upload it with the Transporter app.
`SAYSO_STORE_BUNDLE_ID` overrides the bundle ID (default `com.pepebits.sayso`).

## Moving from the direct download

The store app uses the same bundle ID as the direct download, `com.pepebits.sayso`: it is the same
app. On its first launch macOS moves `~/Library/Application Support/SaySo` (database, Telegram
session, Linux machine, Whisper models) into the sandbox container, following
`Resources/appstore/container-migration.plist`. Only the real bundle ID gets that file; the local
test build never does, or it would take the regular app's data.

- After the move, the direct-download app starts empty if opened again: use one or the other.
- Keys stay in the keychain under the same service, but they were saved by the Developer ID build.
  The first time the store build reads each one, macOS may ask to allow it («Always Allow»).
- macOS permissions (microphone, input monitoring, calendars) are asked again, since the
  signature changes.

## Open questions before submitting

- **Export compliance**: HTTPS is exempt, but the Telegram account feature bundles TDLib, which
  implements its own encrypted protocol (MTProto). Decide the answer to the encryption question
  (and whether to add `ITSAppUsesNonExemptEncryption` to the Info.plist) before the first upload.
- **Privacy label**: the app has no servers and the privacy manifest declares no collected data.
  Requests go to the AI provider and Telegram account the user connects; declare that in App Store
  Connect as you see fit.
- **App Review**: the reviewer needs a working setup. Provide an AI key with a low spending limit
  and, ideally, a test Telegram bot, plus notes explaining the Linux virtual machine (it is an
  isolated workspace for the agent, downloaded on request, not code that changes the app).
- **Screenshots** for the listing.

## Public pages

The privacy policy and support page live in `site/` and are published to GitHub Pages by
`.github/workflows/pages.yml` (Settings → Pages → Source: GitHub Actions):

- Privacy policy URL: `https://pepebits.github.io/sayso/privacy/` (Spanish: `/privacidad/`)
- Support URL: `https://pepebits.github.io/sayso/support/` (Spanish: `/soporte/`)

Edit the text in `site/pages/` and preview it with `python3 site/build.py`.
