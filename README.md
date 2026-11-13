# ScreenHelm

Every display of your Mac, steered from one place. A native macOS menu bar app (Swift, SwiftUI)
for brightness, resolutions, arrangement, virtual screens and picture in picture.

> **Status:** version 1.0.0 is in its last round of testing and not released yet. Until it is,
> build it from source as described below.

## What it does

- **One page for each display.** The sidebar lists every connected display, then
  Arrangement, Virtual Screens, Picture in Picture, Shortcuts, Automation and Settings. The menu
  bar panel has the everyday controls for each display: brightness, volume, resolution, refresh
  rate, input and reference preset, as you choose for each, with Night Shift and True Tone.
- **Brightness on one slider,** whatever is behind it: the backlight of an Apple display, a
  monitor's own setting over DDC, or software dimming for the rest (the color table, or a dark
  overlay). With a switch on, the keyboard's brightness and volume keys and an on-screen display
  work for the monitors macOS ignores. On an XDR display the slider can go past 100%, up to a
  limit you set.
- **Every resolution the display reports,** including the ones System Settings hides, with
  favorites, a slider between larger text and more space, the refresh rate, HiDPI, the area
  beside the camera housing, rotation, HDR, reference presets and the color profile. More sharp
  sizes can be added to a display's own override file.
- **Picture adjustments.** Contrast, gamma, color temperature, gains, inverted colors, the
  number of color steps and dithering. Brightness that follows the built-in display, by
  percentage or by nits, or the light in the room.
- **Arrangement.** Displays dragged into place with guide lines; an arrangement kept for each
  set of displays and put back when macOS changes it; a display switched off without pulling its
  cable; a Shortcut run or a file opened when displays come and go; the Mac kept awake while a
  chosen display is connected; Sidecar.
- **Virtual screens and picture in picture.** A display with nothing plugged in, from a template
  or in the shape of a real one. A live copy of a display or a window in a floating window or
  across another display: turned, mirrored, cropped, filtered, with a `.cube` lookup table.
- **Shortcuts and automation.** Shortcuts you record (none is set until you do), actions for the
  Shortcuts app, and, once you turn them on, the command line, `screenhelm://` links and HTTP on
  your own Mac. Display groups, monitor controls of your own over DDC, export and import of the
  settings, and a diagnostic report without serial numbers.
- **A way back.** A change that could leave a display unusable has to be kept within 15 seconds
  or it is undone, and a new mode is written for good only once kept. Control-Option-Command-
  Escape (⌃⌥⌘⎋) drops everything ScreenHelm has applied. Opened with Shift held, or after a start
  that ended while it applied settings, it applies nothing saved. Software dimming never comes
  back darker than 15% by itself, and nothing is ever written to a display's EDID.

It runs in the menu bar, in English and Vietnamese, light and dark.

## Requirements

macOS 14 Sonoma or later, Apple silicon or Intel. Controlling a monitor over DDC needs Apple
silicon.

Changing displays needs no permission. These are asked for only when you use what needs them:

| Permission | Used for | Without it |
| :--- | :--- | :--- |
| Accessibility | The keyboard's brightness and volume keys for other displays, and finding the display of the window in front | The keys keep doing only what macOS does with them |
| Screen Recording | Picture in picture | No picture in picture; the rest works |
| Automation (System Events) | Switching between light and dark from a shortcut | Asked the first time; the rest works |
| An administrator's password | Adding resolutions to a display (its page › More Resolutions), each time the file is installed or removed | Nothing is installed |

ScreenHelm is not sandboxed: the display calls, DDC and the override file installer don't work
from the sandbox.

## Install

Download the latest version from
[apps.dangkhoabach.vn/screenhelm](https://apps.dangkhoabach.vn/screenhelm) or from
[Releases](https://github.com/dangkhoabach/ScreenHelm/releases), and drag ScreenHelm to
Applications.

- The app is signed with an Apple Development certificate, not a Developer ID, and is not
  notarized, so macOS blocks the first launch. Open it once from
  **System Settings → Privacy & Security → Open Anyway**.
- Updates arrive through **Check for Updates…** (in the menu bar panel, or right-click the menu
  bar icon), signed with the release key.
- Quitting ScreenHelm switches back on every display it switched off and drops its dimming and
  picture adjustments; virtual screens go with it.
- Two apps changing the same display undo each other. If BetterDisplay, MonitorControl or Lunar
  is running, ScreenHelm says so at the top of every page: use one at a time.

## Privacy

- No account, no telemetry, no analytics. The only network request is the update check
  (Sparkle) to `updates.dangkhoabach.vn`, which can be turned off in Settings.
- A display's serial number is hidden until you ask to see it, stays out of the logs and the
  diagnostic report, and is in an EDID file only when you export one. A picture-in-picture is
  drawn straight from the screen and never written to disk.
- Display commands from the command line and from `screenhelm://` links are off until you turn
  them on, since a link can come from anywhere. The HTTP server is off too; turned on, it
  listens on `127.0.0.1` only and every request needs a token kept in your login Keychain.
  Neither can start a program: the actions for displays coming and going run a Shortcut or open
  a file you chose in the app.

## Undocumented macOS calls

Many display features have no public API. Every such call is in
[`DisplayPrivateAPIs.swift`](ScreenHelmApp/Platform/DisplayPrivateAPIs.swift), looked up by name
when the app runs: if a future macOS removes one, the feature that needs it turns itself off
instead of crashing.

| Call | Why |
| :--- | :--- |
| `SLSGetNumberOfDisplayModes`, `SLSGetCurrentDisplayMode`, `SLSGetDisplayModeDescriptionOfLength`, `SLSConfigureDisplayMode`, `SLSIsDisplayModeVRR`, `SLSIsDisplayModeProMotion` | List every mode of a display, the hidden ones and those of a virtual screen included, and switch to one |
| `SLSConfigureDisplayEnabled` | Switch a display off without unplugging it, and back on |
| `DisplayServicesGetBrightness`, `DisplayServicesSetBrightness`, `DisplayServicesGetLinearBrightness`, `DisplayServicesCanChangeBrightness`, `DisplayServicesRegisterForBrightnessChangeNotifications` | The backlight of the built-in display and of Apple's monitors, and hearing when it changes |
| `CoreDisplay_DisplayCreateInfoDictionary` | What a display is: virtual, AirPlay, where it is plugged in |
| `MPDisplayMgr`, `MPDisplay`, `MPDisplayPreset` (MonitorPanel) | Rotation, HDR and the reference presets, the way System Settings sets them |
| `CBBlueLightClient`, `CBTrueToneClient` (CoreBrightness) | Night Shift and True Tone |
| `IOAVServiceCreateWithService`, `IOAVServiceReadI2C`, `IOAVServiceWriteI2C`, `IOAVServiceCopyEDID` | DDC to a monitor on Apple silicon, and reading its EDID |
| `ALCALSCopyALSServiceClient`, `IOHIDServiceClientCopyEvent`, `IOHIDEventGetFloatValue` | The light sensor, for brightness that follows the room |
| `SidecarDisplayManager` (SidecarCore) | Connecting an iPad as a display |
| `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplayMode`, `CGVirtualDisplaySettings` | Virtual screens |

ScreenHelm also reads two properties of the display's entry in the I/O Registry that have no
documentation: `IOMFBBrightnessLevel`, for the built-in display's brightness in nits, and
`enableDither`, which it sets to switch dithering off.

A display ScreenHelm switched off is a setting that outlives the app: it comes back when
ScreenHelm quits, when it next starts, and, should the app be killed, through a small watcher
(the same executable, run a second time).

## Limitations

- ScreenHelm was built and tried on a MacBook Pro's own XDR display and on virtual screens. What
  needs other hardware is written from how MonitorControl, m1ddc, AppleSiliconDDC and
  displayplacer do it and is marked **Experimental** in the app until it has run on the real
  thing: DDC (a monitor's brightness, contrast, volume, input, power and gains), HDR and
  rotation of an external display, switching an external display off, Sidecar, HDR virtual
  screens, and installing the file for More Resolutions. DDC is for Apple silicon; docks,
  adapters and TVs often don't pass it on, and DisplayLink never does.
- XDR brightness works through the display's color table, or through a layer over the screen
  where that can't be used. HDR video loses its highlights while it is on, and it turns itself
  off on a low battery or a hot Mac. It is never on by itself after a restart.
- Software dimming and the picture adjustments last while ScreenHelm runs and don't show in
  screenshots; dimming with an overlay does. On Macs with an M5 Pro or M5 Max the color table
  has no visible effect (a macOS bug), so those dim with the overlay. Another app that changes
  the same table (f.lux, BetterDisplay, MonitorControl, Lunar) and ScreenHelm undo each other:
  use one at a time.
- More Resolutions adds sharp sizes up to the panel's own, not beyond, and no wider than the
  chip draws (7680 pixels on Pro, Max and Ultra chips, fewer on others). It needs an
  administrator's password, and a restart for a built-in display.
- A virtual screen lasts while ScreenHelm runs and plays no protected video. Picture in picture
  needs Screen Recording, which macOS asks about again roughly every month.
- A connected display keeps the Mac awake only while the Mac is plugged in or its battery is
  above 20%.
- Not there yet: the connection's color mode (RGB or YCbCr, bit depth), HDMI-CEC, TVs over the
  network, EDID overrides, brightness boost for other makers' HDR monitors, and software volume
  for speakers that have none. Switching the built-in display off, and rotating it, are behind a
  switch for risky settings: on some Macs they need a restart to undo.

## How it works

- **`ScreenHelmCore`** (Swift package: Foundation and GRDB): settings, telling displays apart
  across restarts, the modes and their pairs, the brightness curve, DDC packets, the color
  table, EDID, arrangements as rules, virtual screens, the entries of a display's override
  file, a stream's geometry and the one grammar of display commands. It is tested headless.
- **`ScreenHelmApp`** (SwiftUI and AppKit): the menu bar panel, the main window, the event tap
  for the keys, ScreenCaptureKit, power assertions and the display calls. One owner for each
  display's color table, a queue for each monitor's DDC, and nothing on a timer except the light
  sensor while brightness follows the room.
- GRDB and Sparkle are pinned in `Package.resolved`. Their licenses are in Settings › Third-Party
  Software and in [`ThirdPartyNotices.txt`](ScreenHelmApp/Resources/ThirdPartyNotices.txt).
- ScreenHelm includes no one else's code. How to reach a monitor over DDC on Apple silicon was
  learned from [AppleSiliconDDC](https://github.com/waydabber/AppleSiliconDDC),
  [m1ddc](https://github.com/waydabber/m1ddc) and
  [MonitorControl](https://github.com/MonitorControl/MonitorControl); modes, rotation and
  switching a display off from [displayplacer](https://github.com/jakehilborn/displayplacer);
  presets, Night Shift and the light sensor from [Lunar](https://github.com/alin23/Lunar)'s
  public sources; dithering from [Stillcolor](https://github.com/aiaf/Stillcolor). Thank you to
  their authors.

## Build from source

Requirements: Xcode 26 or later.

```zsh
cp Local.xcconfig.example Local.xcconfig   # then pick a signing identity in it
open ScreenHelm.xcodeproj
```

`Local.xcconfig` (gitignored) is the project's base configuration, so the build fails until it
exists rather than silently picking an identity. The example explains the three choices:
ad-hoc signing builds but makes macOS ask for the permissions again after every build,
`./scripts/create-signing-cert.sh` makes a self-signed identity that keeps them, and an Apple
Development certificate also keeps the Keychain from asking for the HTTP token again.

Tests:

```zsh
cd ScreenHelmCore && swift test   # 108 tests
xcodebuild test -project ScreenHelm.xcodeproj -scheme ScreenHelmApp -destination 'platform=macOS'   # 66 tests
```

The tests that change real displays (they make virtual screens, move the brightness and put it
back) run only with `TEST_RUNNER_SCREENHELM_CHANGE_DISPLAYS=1` in the environment; the picture in
picture ones also need the Screen Recording permission.

The app icon is drawn by code: `swift scripts/generate-app-icon.swift`. Releases are built,
verified and packaged locally: see [docs/release.md](docs/release.md).

## Forking

Change these before you ship your own build, so it doesn't share data or updates with the
official app:

- `PRODUCT_BUNDLE_IDENTIFIER` in the Xcode project.
- `SUFeedURL` and `SUPublicEDKey` in `ScreenHelmApp/Info.plist`, with your own Sparkle key.
- The Keychain service in `ScreenHelmApp/Displays/AutomationServer.swift`, and the `screenhelm`
  URL scheme in `Info.plist`.

## Security

Please report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md).

## Contributing

Issues are welcome. This is a personal project, so pull requests are read but may not be
merged.

## License

[MIT](LICENSE) for the source code. The ScreenHelm name and app icon are not covered by the
license; use your own for a fork.
