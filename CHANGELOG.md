# Changelog

All notable changes to this project are documented here.

## [0.1.1] - 2026-07-26

### Changed

- Changed the default encryption method from ChaCha20 to XOR for NexaTunnel
  compatibility. Stronger methods remain available through `--encryption`.

## [0.1.0] - 2026-07-23

### Added

- Docker Compose deployment using the official MasterDnsVPN GHCR image.
- Interactive and non-interactive installation for Debian/Ubuntu VPS hosts.
- Safe port 53 diagnostics and reversible `systemd-resolved` handling.
- UFW/firewalld integration without replacing existing firewall policy.
- ChaCha20 default, protected key files, and generated client configuration.
- Update, status, logs, doctor, DNS check, key rotation, and uninstall commands.
- Offline dry-run and smoke-test suite.
