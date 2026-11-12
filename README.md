<p align="center">
  <img src="assets/readme/hero.svg" alt="Notch Two: a music player, file shelf, and focus timer arranged around a MacBook notch" width="100%">
</p>

<p align="center">
  <strong>An independent macOS fork that turns the notch into a small, useful workspace.</strong><br>
  Built on <a href="https://github.com/TheBoredTeam/boring.notch">Boring Notch</a> and released separately as Notch Two.
</p>

<p align="center">
  <a href="https://github.com/kkonstantin08/notch-two/releases/latest"><img alt="Latest preview" src="https://img.shields.io/github/v/release/kkonstantin08/notch-two?include_prereleases&label=preview"></a>
  <img alt="macOS 15.6+" src="https://img.shields.io/badge/macOS-15.6%2B-111111?logo=apple&logoColor=white">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-111111?logo=apple&logoColor=white">
  <a href="LICENSE"><img alt="GPL-3.0 license" src="https://img.shields.io/badge/license-GPL--3.0-blue.svg"></a>
</p>

## What it does

Notch Two keeps everyday controls close to the top edge of your Mac. Hover over the notch to open its panel; music, calendar events, a drag-and-drop shelf, focus timers, wellness reminders, notifications, and system controls live together there.

The upstream Boring Notch project remains separate. Notch Two uses its own app identity and data container, and does not replace or update the official app.

## Get the preview

**Notch Two `v0.1.0-preview.1`** is an arm64 preview built from app version `2.8-beta.0` (build `272`).

1. Download [Notch-Two-2.8-beta.0-build.272-arm64.zip](https://github.com/kkonstantin08/notch-two/releases/latest/download/Notch-Two-2.8-beta.0-build.272-arm64.zip) and expand it.
2. Move **Notch Two.app** to **Applications**.
3. This preview is ad-hoc signed and is not notarized by Apple. To clear the quarantine flag before opening it, run:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Notch Two.app"
   ```

   Then open Notch Two from Applications. macOS may ask you to grant permissions for features you enable.

> This is an early, unsigned-by-Developer-ID preview. It is for testing; macOS may show security prompts. The app is arm64-only and requires macOS 15.6 or later.

## Build from source

Requirements: macOS 15.6 or later and Xcode 26 or later.

```sh
git clone https://github.com/kkonstantin08/notch-two.git
cd notch-two
./scripts/test.sh
./scripts/build.sh
```

The verified Release app is written to `.build/xcode/Build/Products/Release/Notch Two.app`. Open it with:

```sh
open ".build/xcode/Build/Products/Release/Notch Two.app"
```

The local build uses an ad-hoc signature. It has a separate bundle identifier and XPC helper from the official Boring Notch app; keep only one notch app running at a time.

## Upstream and license

Notch Two is based on [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch), pinned at [`0477a9b`](https://github.com/TheBoredTeam/boring.notch/tree/0477a9be8c8f4c426749f8fd2d5334e04851067a). The source and adapted changes are distributed under **GNU GPL-3.0**. See [LICENSE](LICENSE) and [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES) for the complete terms and dependency notices.

Notch Two is an independent community fork and is not affiliated with or endorsed by TheBoredTeam. Upstream attribution, trademarks, and third-party notices remain with their respective owners.
