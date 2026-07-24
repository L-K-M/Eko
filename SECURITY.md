# Security Policy

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private
[security advisory form](https://github.com/L-K-M/Eko/security/advisories/new)
or contact the maintainer through the address on their GitHub profile.

Include the affected commit or version, reproducible steps, expected impact,
and only sanitized diagnostics. Do not attach real notification contents,
one-time codes, pairing QR data, private keys, certificates containing private
material, tokens, or unredacted device logs.

## Scope

Security-sensitive areas include:

- Android notification capture, local outbox storage, backup boundaries, and
  foreground/background lifecycle handling.
- Pairing, certificate identity, mutual TLS, discovery input parsing, replay
  protection, protocol negotiation, and unpairing.
- macOS notification storage, OTP extraction, clipboard handling, diagnostics,
  Keychain use, sandboxing, signing, and updates.
- Release workflows, dependency integrity, signing keys, and published
  artifacts.

## Security and privacy baseline

- Notification contents and OTPs remain on paired devices and travel only over
  mutually authenticated, encrypted connections.
- Discovery data never establishes identity or trust.
- Secrets and signing material are never committed, logged, included in
  diagnostics, or stored in normal backups.
- Release artifacts must be signed, signature-verified, and accompanied by a
  checksum. Unsigned APKs are not release artifacts.
- The project has no analytics or cloud data service unless that posture is
  explicitly redesigned and documented before implementation.

The detailed threat model and protocol requirements are maintained in
[PLAN.md](PLAN.md).
