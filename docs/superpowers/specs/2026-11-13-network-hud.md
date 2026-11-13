# Network HUD

Use the existing `wifi` feature flag, activity queue and closed-notch pill.
Old opt-ins retain connection alerts and inherit the common duration until
a network-specific duration is set. Route loss/recovery and SSID display
require separate opt-ins. Only the explicit Location button can prompt.
No location fixes or external requests are made.

One utility queue owns the path monitor and CoreWLAN subscriptions. Every
start creates a new path monitor. Stop clears its callback, cancels pending
settling work and deregisters CoreWLAN. The coordinator invalidates the
session before stop, drops its cards and ignores old callbacks. Sleep resets
the source, and wake establishes a silent initial snapshot.

Settle Wi-Fi and route updates together after 750 ms. Track Wi-Fi association
separately from the default route. Report both dimensions when enabled.
A satisfied route is a system routing signal. It does not verify public
internet connectivity. Use CoreWLAN names only when opted in and available.
Use a generic Wi-Fi label for unidentified Personal Hotspots. Network cards
appear only in the closed activity stack.

## Focus investigation

On macOS 27.0.1 (26A434), Control Center visibly changed DND off and on.
The Atoll distributed notification names and three candidate Darwin names
did not deliver events during those transitions. The closed menu-bar item
provided the same generic accessibility label in both states. Reading
`Assertions.json` and `ModeConfigurations.json` returned Operation not
permitted. Filesystem notifications cannot supply their content.

Apple's [communication notification API](https://developer.apple.com/documentation/usernotifications/handling-communication-notifications-and-focus-status-updates)
exposes an app-relative Boolean with authorization and user sharing. It
does not identify the active mode or its name and cannot distinguish Off
from a mode that allows this app's notifications. Focus HUD is deferred on
this basis. No log tail, polling, new helper or OSDUIHelper manipulation
is part of the candidate.

## Release evidence

Run `./scripts/test.sh --run-app-tests` and `./scripts/build.sh`. Compare
same-length idle samples on AC, inspect Settings and restore the original
bundle through the existing rollback script before re-installing. Leave
network preferences as they were before live testing. Exercise hardware
changes only without disrupting the user's connectivity.

Apple's [Focus filters](https://developer.apple.com/documentation/appintents/defining-your-app-s-focus-filter)
deliver an app configuration that the user attaches to each individual
mode. They are a possible separate manual integration, with no automatic
discovery of unconfigured modes.
