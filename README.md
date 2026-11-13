# ScreenHelm

Every display of your Mac, steered from one place. A native macOS menu bar app (Swift, SwiftUI)
for brightness, resolutions, arrangement, virtual screens and picture in picture.

> **Status: in development.** There is nothing to download yet. This README lists what the
> first version is meant to do, not what works today.

## Planned for the first version

- **Brightness on one slider.** The backlight of an Apple display, a monitor's own setting over
  DDC, or software dimming for the rest, with the keyboard's brightness keys and an on-screen
  display for the monitors macOS ignores. On an XDR display the slider can go past 100%.
- **Every resolution a display reports.** Including the ones System Settings hides, with
  favorites, the refresh rate, HiDPI, rotation, HDR, reference presets and the color profile,
  and more sharp sizes added for a display on request.
- **Picture adjustments.** Contrast, gamma, color temperature, gains and inverted colors.
- **Arrangement.** Displays dragged into place, an arrangement that is put back when macOS
  changes it, and a display switched off without pulling its cable.
- **Virtual screens and picture in picture.** A display with nothing plugged in, and a live
  copy of a display or a window in a floating window or across another display.
- **Shortcuts and automation.** Shortcuts you record, the Shortcuts app, and a command line.
- **A way back.** A change that could leave a display unusable has to be kept within 15
  seconds or it is undone, and one shortcut drops everything the app has applied.

## Requirements

- macOS 14 Sonoma or later. Controlling a monitor over DDC needs a Mac with Apple silicon.
- Accessibility permission (the keyboard's keys for other displays) and Screen Recording
  permission (picture in picture). The app works without network access.

## License

[MIT](LICENSE)
