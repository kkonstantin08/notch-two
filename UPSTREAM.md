# Upstream

Notch Two is based on [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch), pinned at `0477a9be8c8f4c426749f8fd2d5334e04851067a` (`dev`, 2026-11-09).

The fork keeps upstream and third-party copyright notices and GPL-3.0 terms. Notch Two-specific adaptations include its separate app/XPC identity, Shelf batch actions and file ownership lifecycle, Pomodoro and wellness features, and notification presentation and controls. The release is maintained independently and does not use the upstream appcast or Homebrew distribution.

Network HUD design references: [Atoll #827](https://github.com/Ebullioscopic/Atoll/pull/827) and [Boring Notch #1305](https://github.com/TheBoredTeam/boring.notch/pull/1305). Notch Two extends its existing Wi-Fi feature with a fresh path monitor per session and CoreWLAN events. See the [specification](docs/superpowers/specs/2026-11-13-network-hud.md) for constraints.
