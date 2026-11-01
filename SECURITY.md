# Security Policy

## Supported Versions
Security updates are actively provided for the latest minor release branch of TTZip.

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a Vulnerability
If you discover a security vulnerability within TTZip, please report it via private disclosure:
- **Email**: `witt.w.kung@gmail.com`
- **GPG Key**: Available upon request.

Please do not open public issues for security vulnerabilities. We will respond within 48 hours and coordinate a coordinated disclosure timeline.

## Security Architecture Principles
1. **Ed25519 Cryptographic Verification**: Client-side license verification uses Apple CryptoKit and only embeds the 32-byte public key. Private keys are never embedded.
2. **Secure Zeroization**: Sensitive archive passwords and vault credentials use `SecureBytes` with `mlock` and explicit memory scrubbing.
3. **Hardened Runtime & Gatekeeper**: Official release packages are signed with Apple Developer certificates and notarized.
