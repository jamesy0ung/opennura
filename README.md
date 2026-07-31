# OpenNura (macOS key-recovery fork)

Control your Nuraphone from macOS, and recover its device key on the Mac with
no iOS or Windows device required.

> ## ⚠️ Safety and disclaimer
>
> This is unofficial, experimental software that talks directly to headphone
> hardware by reverse-engineering an undocumented protocol. It is not affiliated
> with, endorsed by, or supported by Nura. **Use it entirely at your own risk.**
>
> - **Hearing safety.** Sending commands to headphones can, in bad states,
>   cause sudden loud or high-pitched sound. The Nuraphone disconnects when it's
>   not being worn, so keep it **on your head but with the in-ear tips out of
>   your ears** while connecting or changing settings, and only seat the tips
>   once things look stable. If you ever hear a loud or unexpected noise, take
>   the tips out immediately and power the headphones down.
> - **Connecting needs the audio link dropped first.** The Nuraphone serves the
>   wrong Bluetooth channel while it is streaming audio, so the app connects from
>   the paired-but-not-connected state. By default it disconnects the
>   headphones' audio for you when you press Connect (a toggle sits next to the
>   button); turn that off if you would rather disconnect it yourself in
>   Bluetooth settings. Either way you can resume audio once connected, and
>   changing settings while audio plays is fine.
> - As per the GPLv3, this software comes with **no warranty** of any kind. The
>   authors are not liable for any damage to your hearing or your hardware.
> - The device controls (immersion, noise modes, buttons, dials) are recovered
>   by reverse engineering and are not all verified across firmware versions.

This is a fork of [jamesy0ung/opennura](https://github.com/jamesy0ung/opennura)
that adds two things which make the app usable end-to-end on a Mac alone:

- **Classic Bluetooth (RFCOMM/SPP) transport** — the Nuraphone exposes its GAIA
  control channel over classic Bluetooth, not Bluetooth LE, so on macOS this is
  what actually reaches the headphones.
- **Backend key recovery** — sign in with your own Nura account and the app
  recovers your headphone's long-lived device key straight from Nura's servers,
  then stores it locally so you can control the device offline afterwards.

<p align="center">
  <img src="docs/screenshots/main-screen.png" width="70%" alt="The main control screen: battery, noise control, sound mode, immersion, hearing profiles" />
</p>

## Credits

This is a macOS-focused fork of James Young's
[opennura](https://github.com/jamesy0ung/opennura), which provides the app
shell, the GAIA protocol layer, and the crypto.

The backend key-recovery flow is a Swift port of the reverse engineering in
**Callum Carmicheal's [Nura-Windows](https://github.com/CallumCarmicheal/Nura-Windows)**,
which is licensed under the **Apache License 2.0**. Those portions are included
here under GPLv3 with attribution retained, as Apache 2.0 requires. Without that
project's work mapping the provisioning sequence, on-Mac key recovery would not
exist.

See [ATTRIBUTION.md](ATTRIBUTION.md) for the full provenance and
[NOTICE](NOTICE) / [LICENSE](LICENSE) / [LICENSE-APACHE](LICENSE-APACHE) for
licensing.

## Features

- **Noise control** — Off / ANC / Passthrough (Social), per profile.
- **Sound mode** — Personalised or Neutral.
- **Immersion** — the full −2…+4 range, applied to the selected profile.
- **Profiles** — switch between them, rename them (app-side), and see empty
  slots. On newer firmware you can also view each profile's hearing "signature"
  and overlay the profiles to compare them.
- **Touch buttons** — remap single- and double-tap to the functions the
  Nuraphone actually supports.
- **Global hotkeys (macOS)** — system-wide keys for immersion up/down, ANC ↔
  Passthrough, and profile switching, all configurable in the Shortcuts tab.
- **Menu bar app (macOS)** — a compact popover for quick tweaks without opening
  the main window.
- **Key recovery** — recover and store your headphone's device key on the Mac
  alone, with no iOS or Windows device.

<p align="center">
  <img src="docs/screenshots/profile-view.png" width="49%" alt="A hearing profile's signature curve" />
  <img src="docs/screenshots/profile-comparison.png" width="42%" alt="Comparing the signatures of all profiles" />
</p>
<p align="center">
  <img src="docs/screenshots/touch-buttons.png" width="45%" alt="Remapping the touch buttons" />
  <img src="docs/screenshots/menu-bar.png" width="40%" alt="The menu bar popover" />
</p>

## What is the "device key"?

Every Nuraphone has a unique 16-byte AES key. All control commands (noise
cancellation, immersion, profiles, and so on) are encrypted with it, so without
the key the app can connect but not command the device. The official app
obtained this key from Nura's servers during setup. This app can do the same on
macOS, or you can enter a key you already have by hand.

## Requirements

- A Mac running a recent macOS with Xcode installed.
- An Apple ID for local code signing (a free personal team is fine).
- Your headphones paired in Bluetooth settings.
- For key recovery: the Nura account (email) your headphones were registered to,
  and the Nura backend still being online.

## Build

1. Open `opennura.xcodeproj` in Xcode.
2. Select the `opennura` target → Signing & Capabilities, and choose your team.
3. Set the run destination to **My Mac** and Run.
4. Grant Bluetooth permission when prompted.

To build a signed, notarised `.app` you can keep in /Applications (so macOS
stops re-prompting for Keychain access on each rebuild), see
[docs/BUILD-AND-NOTARIZE.md](docs/BUILD-AND-NOTARIZE.md).

## Recovering your device key

The Nuraphone serves the wrong Bluetooth channel while it is actively connected
for audio, so recovery is most reliable when the headphones are **paired but not
connected**. The steps:

1. In Bluetooth settings, make sure the Nuraphone is paired. Leave "Disconnect
   audio automatically" on (next to the Connect button) and the app will drop
   the audio link for you; otherwise disconnect it yourself (leave it paired).
2. Launch the app, go to the **Devices** tab, and open **Recover key from
   Nura**.
3. Sign in with your Nura account email and the code it sends you.
4. Tap **Recover key from connected nuraphone** and wait (up to a minute). The
   app talks to both the headphones and Nura's servers and saves the key.

Once recovered, the app connects locally with the saved key. No account or
internet is needed after that.

### Back up your key

Nura's servers may not stay online forever. In the **Devices** tab you can
reveal and copy your key. Keep a copy somewhere safe; with it, the headphones
remain controllable even if the backend disappears.

## How it works

The control protocol is Qualcomm GAIA carried over Bluetooth. Key recovery
replays the official app's backend handshake (`app/session` → email login →
`end_to_end/session/start` and its follow-ups), relaying the GAIA packets the
server returns to the headphones and sending their replies back, until the
server releases the persistent key. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
and [docs/KEY-RECOVERY.md](docs/KEY-RECOVERY.md) for detail, and
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) if something stalls.

## Privacy and scope

Key recovery signs in with **your own** Nura account and fetches **your own**
device's key. Nothing uses a shared or bundled account, and no key is hardcoded
in the source. This is interoperability with hardware you own, of a product line
that has been discontinued.

## Tests

Pure-logic units (msgpack, GAIA framing, backend response parsing) have a small
test package:

```
swift test
```

This does not build the UI or Bluetooth layers; the full app is built with
Xcode.

## Status and limitations

- Targets the classic **Nuraphone** (over-ears). Other Nura devices are not
  supported.
- Key recovery depends on Nura's backend still responding.
- Several controls from the official app are not implemented.
- macOS is the supported platform for key recovery; classic-Bluetooth RFCOMM is
  not available to third-party apps on iOS.

## Licence

GNU General Public License v3 (see [LICENSE](LICENSE)). The provisioning code is
derived from the Apache-2.0 [Nura-Windows](https://github.com/CallumCarmicheal/Nura-Windows)
project and is included under GPLv3 with attribution; see [NOTICE](NOTICE),
[LICENSE-APACHE](LICENSE-APACHE), and [ATTRIBUTION.md](ATTRIBUTION.md).

## Trademarks

"Nura" and "Nuraphone" are trademarks of their respective owners. This project
is not affiliated with, endorsed by, or sponsored by Nura or its successors.
The names are used solely to identify the hardware this software interoperates
with.
