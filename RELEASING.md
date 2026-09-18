# Releasing RePaste

RePaste is an independent fork of imeelinew/Paste. Do not reuse the upstream update feed, signing key, or Apple team. No RePaste update channel is currently enabled.

## Local Xcode runs

Open `Paste.xcodeproj` and use the existing `Paste` scheme. Its product is `RePaste.app`, with bundle ID `com.aaron.RePaste`. The embedded tool is `repaste-cli`.

Debug and Release retain ad-hoc signing and `Paste/Paste.local.entitlements`. These local builds may require Accessibility permission again after rebuilding. Configure your own stable signing certificate in Xcode for durable identity; no certificate or developer account is configured by this fork.

## Configure your own distribution

1. Configure your Apple signing identity and set `REPASTE_TEAM_ID` for the release script. Certificate-signed archives use `PASTE_APP_ENTITLEMENTS=Paste/Paste.entitlements`.
2. Generate a new Sparkle EdDSA key pair. Keep the private key outside the repository and configure the repository's `SPARKLE_PRIVATE_KEY` Actions secret.
3. Host this fork's `docs/appcast.xml` via your own GitHub Pages setup. The current feed is intentionally empty.
4. Add your HTTPS `SUFeedURL` and matching `SUPublicEDKey` to `Paste/Info.plist`, then set `RePasteUpdatesEnabled` to true.
5. Set the repository Actions variable `REPASTE_UPDATES_ENABLED` to `true` to enable appcast publishing.

Keep the original AGPL-3.0 license and upstream attribution with distributed versions. Apple signing/notarization and Sparkle update signing serve different purposes; configure the distribution path appropriate to your release.

## Publish

From a clean `main` branch, run `REPASTE_TEAM_ID=YOUR_TEAM ./scripts/release.sh <version> <build>`.

The script defaults to `Aaron48615/Paste` (override with `REPASTE_GITHUB_REPOSITORY`), updates versions, archives `RePaste.app`, pushes `main`, and publishes `RePaste-<version>.zip`. The release description is empty. Once explicitly enabled, the appcast workflow signs the update and publishes the fork's feed.
