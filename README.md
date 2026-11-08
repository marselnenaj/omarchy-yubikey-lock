# YubiKey Lock Screen

A theme-aware session lock with separate FIDO2, password and optional fingerprint PAM flows.
Select one method at a time; PIN responses belong only to the key flow.

**Version 0.3.1.** This standalone plugin comes from
[Omarchy YubiKey](https://github.com/marselnenaj/omarchy-yubikey), which also provides guided key enrollment and PAM
configuration. Includes all 50 Omarchy languages and follows Setup > Language
live, with English fallback. See the suite release notes for validation and compatibility.

## Requirements

Omarchy 4 with its Quickshell plugin host, `qs.Commons`, `qs.Ui`, the PAM/Polkit
modules and authentication-clone support. The source environment used Omarchy
4.0.6. Other shell versions are unqualified. This is trusted authentication
code that runs inside the shell; review it before enabling it.

The lock needs the shell's existing `omarchy-lock-password` PAM service. For key
unlock it also needs `omarchy-lock-fido2` and a central enrollment mapping.
Polkit needs the matching key authentication rule in `/etc/pam.d/polkit-1`.
[Guided setup and recovery](https://github.com/marselnenaj/omarchy-yubikey/blob/v0.6.0/docs/install.md) configures those
pieces with backups. Installing this plugin alone does not alter PAM or enroll
a key, and it does not install the optional Keyring helper.

## Install

Use the suite's guided installer if you want the full setup. To install just
this shell plugin after configuring PAM:

```sh
omarchy plugin add https://github.com/marselnenaj/omarchy-yubikey-lock.git
omarchy plugin enable yubikey.lock
```

Enable it while the desktop is unlocked. Disable any other custom replacement
for `omarchy.lock` first; keep a recovery terminal available. The host uses
`omarchy.clonedFrom` to replace the stock service. Do not mix a Git-managed copy
with a directory already copied by the suite installer under the same ID.
Test key and password authentication before relying on it. Plugin commands
follow the repository's default branch; use the suite release for a fixed source
snapshot. [PAM instructions](https://github.com/marselnenaj/omarchy-yubikey/blob/v0.6.0/docs/pam-setup.md) and
[security model](https://github.com/marselnenaj/omarchy-yubikey/blob/v0.6.0/docs/security-model.md) describe PIN mode,
explicit password fallback and limitations. Updating plugin files alone does not
update PAM policy. Re-run reviewed suite setup to enable PIN/explicit fallback.

## Update and remove

While unlocked:

```sh
omarchy plugin update yubikey.lock
```

To remove it:

```sh
omarchy plugin disable yubikey.lock
omarchy plugin remove yubikey.lock
```

On the supported host, disabling the clone restores the stock service. If you
previously used another custom clone, re-enable it yourself. Removal does not
change PAM or delete enrollment data. Follow the suite's rollback instructions
if you also want to undo that setup.

## Source and license

This is a distribution repository. Its maintained source is
[`plugins/yubikey.lock`](https://github.com/marselnenaj/omarchy-yubikey/tree/v0.6.0/plugins/yubikey.lock) in the suite.
`SOURCE.json` records the source ref and hashes of the exported files. Report
bugs and send changes to [the suite](https://github.com/marselnenaj/omarchy-yubikey/issues).

MIT; QML derives from the Omarchy shell. See `THIRD_PARTY_NOTICES.md`.
Independent community software, unaffiliated with Yubico, GNOME or Omarchy.
