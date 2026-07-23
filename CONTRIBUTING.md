# Contributing

Contributions that improve idempotency, safety, diagnostics, distribution
support, and compatibility with current MasterDnsVPN releases are welcome.

## Before opening a pull request

Run:

```bash
bash -n vps-setup.sh tests/smoke.sh
bash tests/smoke.sh
shellcheck -x --severity=warning vps-setup.sh tests/smoke.sh
```

Do not include generated `.env`, `data/`, client configurations, encryption
keys, real domains, VPS addresses, or unredacted logs.

Changes that delete data, alter firewall policy, change `/etc/resolv.conf`, or
install system packages must:

- be narrowly scoped;
- be idempotent;
- preserve existing user state;
- include rollback or uninstall behavior;
- include a smoke test where practical;
- be documented in README.

Keep the deployment dependent only on the official MasterDnsVPN image. Changes
to the protocol or server belong in the upstream repository.
