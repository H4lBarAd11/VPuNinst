# Contributing

Thank you for wanting to help. The most useful thing you can do right now is
to try VPuNinst with a VPN it hasn’t met yet. Only Palo Alto Networks has been
tried against a real gateway. Cisco, Fortinet, Juniper, Ivanti (Pulse) and F5
are written but untested, so a report from any of them helps, whether it
worked or not.

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## Reporting how a VPN went

Open an issue with the **VPN report** form. Say which kind of VPN it was, and
how far VPuNinst got: the sign-in page, MFA, the tunnel coming up, the
institution’s addresses and names answering. A short report is still useful.
If you’d rather not paste any logs, the kind of VPN and the step where it
stopped already help.

The logs say where it stopped:

- `~/Library/Logs/VPuNinst.log`, the app’s own. It never holds a cookie or a
  password.
- `/var/log/vpuninst-<id>.log`, that institution’s openconnect, with the
  session before it in `/var/log/vpuninst-<id>.log.1`.

openconnect’s log names the server, the gateways, the addresses the tunnel
was given and its routes. Before you paste a log, replace the institution’s
host names with `vpn.example.edu`, your username with `user`, and addresses
with something like `10.x.x.x`. Keep the error messages as they are.

## Reporting a bug

Use the **Bug** form, with your macOS version, whether the Mac has Apple
silicon or Intel, VPuNinst’s version (in About VPuNinst, in the snowflake’s
menu), what you did and what happened. The same care with logs applies.

A security problem goes in a private report, never an issue. See
[SECURITY.md](SECURITY.md).

## Changing the code

For anything larger than a small fix, open an issue first, so that the idea
can be talked over before you spend time on it.

To build and run your change, follow [Run from source](README.md#run-from-source)
in the README. After changing the helper or the tunnel script, install them
again as step 1 there says, or you’ll be testing the old ones.

**What VPuNinst is made of.** The app is SwiftUI, for macOS 14 and later. The
helper and the tunnel script are POSIX `sh`. Everything is built with Apple’s
developer tools alone, with no package manager and no third-party code
besides the openconnect and OpenSSL that `tools/build-openconnect.sh` builds
from pinned sources. Please keep it that way.

**What runs as root** gets the closest reading: `helper/`, the sudoers rule
and `packaging/postinstall`. A change there keeps the helper’s verbs fixed,
checks every argument and everything a gateway sends before it reaches a
command, and runs nothing a user could change. In the pull request, say what
root can do after your change that it couldn’t before, even if the answer is
nothing.

**How things are written:**

- A comment says what the code does and why, in its own terms, not where an
  idea came from.
- No real institution is named anywhere: not in code, comments, examples or
  commit messages. Examples use `vpn.example.edu`, `idp.example.ac.uk`,
  “University”, “Research institute”, “Hospital”.
- VPN vendors are named by company (“Palo Alto Networks”, “Cisco”), not by
  their products’ names. Protocol names such as `gp` and `anyconnect` are fine.
- What the user reads (the window, the README, the installer) is plain, short
  and in British English.

**Testing.** Say how you tested the change: against a real gateway, and which
kind, or with stand-ins for `route`, `scutil` and the rest. Untested is
fine if you say so; the README’s table of VPNs exists to tell people what has
and hasn’t been tried.

## Licence

VPuNinst is under the [GNU General Public License](LICENSE), version 3 or any
later version. By contributing, you agree that your contribution is under the
same licence.
