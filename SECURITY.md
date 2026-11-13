# Security policy

## Reporting a vulnerability

Please report security issues privately, not in a public issue:

- **GitHub:** Security tab → **Report a vulnerability** on this repository, or
- **Contact form** on [dangkhoabach.vn](https://dangkhoabach.vn), asking for a private channel.

Include the app version (Settings), your macOS version and the steps to reproduce. You will get
a reply within a week. Please give a fix the chance to ship before you disclose the issue
publicly.

## Supported versions

Only the latest release gets security fixes. It reaches you through **Check for Updates…**, or
download it from [apps.dangkhoabach.vn/screenhelm](https://apps.dangkhoabach.vn/screenhelm).

## Scope

ScreenHelm changes how displays work, can take the Accessibility and Screen Recording
permissions, and takes display commands from outside the app once they are turned on, so these
are in scope:

- **Display commands:** a command accepted from the command line, a `screenhelm://` link or HTTP
  while that way in is turned off; an HTTP command accepted without the token, or from another
  machine; the command socket open to another user.
- **Permissions:** another app using ScreenHelm to act through its Accessibility or Screen
  Recording permission.
- **Picture in picture:** a captured frame written to disk or sent anywhere.
- **Administrator rights:** the override file installer writing anything but the display's
  override file and its backup.
- **Updates:** installing an update that is not signed with the release key.

Out of scope:

- A Mac that is already compromised, or someone using it while it is unlocked.
- A display left unusable by a setting the user kept: the 15-second countdown, Control-Option-
  Command-Escape and a start with Shift held are the safety net, and a failure of those is in
  scope.
