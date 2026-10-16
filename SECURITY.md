# Security

VPuNinst runs a helper as root, changes your Mac’s routes and DNS, and keeps
passwords in your keychain, so a security problem in it matters. Thank you for
reporting one.

## Supported versions

Only the [latest release](https://github.com/H4lBarAd11/VPuNinst/releases/latest)
gets fixes. VPuNinst brings its own openconnect and OpenSSL, so their security
fixes reach you through a new VPuNinst release. Install new versions as they
come.

## Reporting a vulnerability

Please don’t open an issue. Report it privately instead, from the repository’s
**Security** tab ▸ **Report a vulnerability**, or directly
[here](https://github.com/H4lBarAd11/VPuNinst/security/advisories/new). Only
you and the maintainer can see the report.

Please include:

- what an attacker can do, and what they need first: a program running as
  you, a place on the same network, a gateway or a sign-in page of their own;
- the VPuNinst version and macOS version;
- the steps to reproduce it, or a proof of concept.

You’ll get an answer to every report. A problem that holds is fixed in a new
release before its details are made public. Say whether you’d like to be
credited in the advisory.

## What is worth reporting

Anything that gives someone more than VPuNinst means to give, for example:

- running anything as root through the helper or the sudoers rule beyond
  connecting, disconnecting and repairing, or changing the list of
  institutions without the administrator password;
- making root’s openconnect connect to a server that isn’t on the list, or
  trust a certificate macOS doesn’t;
- a gateway getting a command of its own into `route`, `ifconfig` or `scutil`,
  or one tunnel taking another tunnel’s traffic or names, or your network’s;
- a saved password filled into, or read by, a page on another host;
- the package installing or changing anything its first page doesn’t list.

## Known limits

These are documented in the README and aren’t vulnerabilities on their own:

- Touch ID is a check in the app, not a lock enforced by macOS. Any program
  running as you can call the helper’s connect, disconnect and repair, though
  only for institutions already on its list
  ([The root setup](README.md#the-root-setup)).
- OpenSSL can’t apply macOS’s partial restrictions on a few certificate
  authorities, so root’s openconnect trusts every authority macOS lists.

A vulnerability in openconnect or OpenSSL themselves belongs with those
projects. If a VPuNinst release ships an affected version, report that here
too.
