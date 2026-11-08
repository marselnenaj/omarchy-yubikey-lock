# Security policy

The current release series is **0.5.x**. Fixes are made on `main` and included
in subsequent releases. Report issues against the latest available version.
Hardware authentication and session locking also need validation on the target
environment; see the documented validation scope and security model.

Please use the repository's **Security → Report a vulnerability** feature when
available. If it is not available, open an issue asking for a private reporting
channel without posting exploit details, personal data or credentials. A
response deadline is not guaranteed for this community project.

Include affected versions, expected versus observed behavior and a minimal
reproduction with synthetic data. Never include enrolled credential mappings,
encrypted password stores, real secrets or unredacted logs.

For the current assumptions and limitations, read
[the security model](https://github.com/marselnenaj/omarchy-yubikey/blob/v0.6.0/docs/security-model.md).

## Dependency maintenance

Dependabot checks Cargo dependencies (including transitive dependencies) and
GitHub Actions weekly. GitHub security-update pull requests should be enabled in
repository settings; they are separate from this version-update schedule. Update
pull requests require review and passing checks; they are not auto-merged.
Routine minor/patch version updates are grouped to reduce review noise;
cryptographic/hardware-authentication dependencies and major updates stay
separate. Security updates are not included in those routine version groups.

The Dependency audit workflow runs on pushes, pull requests, a daily schedule and
manual dispatch. It checks the lockfile against the current RustSec database,
fails on vulnerabilities, unsoundness and yanked crates, and reports informational
maintenance notices. Actions use immutable commit references. The audit binary
and source secret scanner use fixed versions and verified SHA-256 downloads;
their versions/checksums need deliberate maintenance as well.

Version 0.6.0 migrates the helper to zbus 6 and removes the retired zbus 5
serialization/name dependencies behind RUSTSEC-2026-0370, -0371 and -0372.
HKDF and SHA-2 are updated together to compatible digest APIs, with legacy
store decryption and key zeroization checked. No advisory is suppressed.
These checks detect known issues and do not replace code review, hardware
validation or prompt handling of new reports.
