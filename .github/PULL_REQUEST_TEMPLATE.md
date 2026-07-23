## Summary

Describe the problem and the proposed change.

## Safety

- [ ] Existing user data and unrelated firewall/system settings are preserved.
- [ ] Destructive targets are explicitly validated.
- [ ] Rollback/uninstall behavior is documented where applicable.
- [ ] No keys, generated client configs, real domains, IPs, or credentials are included.

## Verification

- [ ] `bash -n vps-setup.sh tests/smoke.sh`
- [ ] `bash tests/smoke.sh`
- [ ] `shellcheck -x --severity=warning vps-setup.sh tests/smoke.sh`
- [ ] README was updated if behavior changed.
