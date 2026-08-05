# Security Policy

## Supported versions

| Version | Supported |
| ------- | --------- |
| 2.3.x   | ✅ Yes |
| < 2.3   | ❌ Please update |

Only the latest release receives fixes. Updates are announced in the app and
published on the [Releases](https://github.com/MrRockySL/Unduck-Pro/releases)
page.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Use GitHub's private reporting instead:
[**Report a vulnerability**](https://github.com/MrRockySL/Unduck-Pro/security/advisories/new)

If that is unavailable, open a normal issue asking to be contacted privately —
without any details of the problem — and a private channel will be arranged.

Unduck Pro is maintained by one person in their spare time, so please expect a
first reply within about **7 days**, and a fix or a clear explanation of why
something will not be fixed within **30 days** for confirmed issues. Credit will
be given in the release notes unless you prefer otherwise.

## What this app can and cannot do

Unduck Pro is a menu-bar utility that controls audio volume. This section
documents its actual access, because "a volume app that asks for the microphone"
deserves an explanation.

### Microphone permission

The app requests microphone permission on first launch. This is required by
Apple, not chosen by us: the **Core Audio process-tap API** (`AudioHardwareCreateProcessTap`,
macOS 14.2+) is gated behind the audio-input permission even when an app only
reads and re-emits *output* audio. There is no narrower permission available.

**The app never records, stores, buffers to disk, or transmits any audio.**
Captured audio exists only inside a real-time render callback, where it is
scaled by your chosen volume and written straight back out to your speakers.

The only entitlement requested is `com.apple.security.device.audio-input`
(see [`script/DuckAudio.entitlements`](script/DuckAudio.entitlements)).

### Network access

The app makes exactly one kind of network request: an unauthenticated `GET` to
`https://api.github.com/repos/MrRockySL/Unduck-Pro/releases/latest` to check
whether a newer version exists. It sends no identifying information, and there
is no analytics, telemetry, crash reporting, or third-party SDK of any kind.

### Data stored

Per-app volume levels and favourites, in `UserDefaults` under
`dev.mrrockysl.duckaudio`. Mute states are held in memory only and are not
saved. Nothing leaves your Mac.

While running, the app also writes a plain-text diagnostic log to
`/tmp/duckaudio.log`, rewritten from scratch on every launch. It records which
processes are producing audio — bundle identifiers and process IDs, for example
`com.google.Chrome.helper` — so that audio-routing problems can be diagnosed. It
contains **no audio and no personal content**, and it is never uploaded
anywhere. Delete it any time.

### Dependencies

None. The app uses only Apple system frameworks — no third-party packages, no
kernel extensions, no virtual audio drivers.

## Verifying what you install

Because the app is distributed as a self-signed DMG, verifying it is reasonable
and encouraged.

**Check the download** against the SHA-256 published in the release notes:

```bash
shasum -a 256 ~/Downloads/Unduck-Pro-2.3.dmg
```

**Or build it yourself** — it takes two commands and no configuration:

```bash
git clone https://github.com/MrRockySL/Unduck-Pro.git
cd Unduck-Pro
./script/make_cert.sh     # one-time: creates a local signing certificate
./script/build_app.sh
```

## Known security-relevant limitations

- **The app is self-signed, not notarized by Apple.** Apple notarization
  requires a paid Developer Program membership; this app is free, so releases
  are signed with a self-signed certificate. macOS will therefore warn on first
  launch and require an explicit approval in **System Settings → Privacy &
  Security → Open Anyway**. Anyone uncomfortable with that should build from
  source instead.
- **Releases are built and uploaded manually**, not by a reproducible CI
  pipeline. Verify the checksum or build from source if that matters to you.
