# Security policy

## Reporting a vulnerability

Do not open a public issue containing:

- `encrypt_key.txt`;
- a generated `client_config.toml`;
- unredacted container logs;
- VPS credentials, SSH keys, tokens, or private IP/network details.

Report vulnerabilities in this installer through GitHub private vulnerability
reporting when it is enabled for the repository. If it is unavailable, contact
the repository owner privately and include a minimal reproduction with all
secrets replaced.

Issues in the MasterDnsVPN protocol, client, server, or official image should
be reported to the [upstream project](https://github.com/masterking32/MasterDnsVPN/security).

## Supported versions

Security fixes are made on the default branch. Pinning an old MasterDnsVPN image
tag is useful for rollback, but the operator is responsible for monitoring
upstream fixes and updating the deployment.

## Secret handling

The shared encryption key grants access to the tunnel. If it was exposed:

```bash
sudo /opt/masterdns-vps-setup/vps-setup.sh rotate-key
```

Replace the generated client files on every authorized device and remove old
copies and logs containing the key.
