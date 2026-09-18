# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-09-18

First release. Post-install housekeeping for a freshly installed Ubuntu VM, opt-in
and dry-run-previewable throughout, with an interactive wizard on top of the same
flag-driven core.

### Added
- Core housekeeping: universe repo, full apt update/upgrade, timezone, NTP
  (systemd-timesyncd), hypervisor-matched guest tools (XCP-ng/Xen, KVM/Proxmox,
  VMware, Hyper-V, VirtualBox - auto-detected via `systemd-detect-virt`, override
  with `--hypervisor`), baseline CLI packages.
- Optional categories, each opt-in on top of `--fix`: `--harden` (SSH key-only +
  UFW, with an authorized_keys safety check), `--swap`, `--unattended-upgrades`,
  `--zabbix` (Agent2 + PSK, with a UFW allow rule for the Zabbix server).
- Interactive wizard (default with a terminal attached): confirms every setting,
  reading prompts from `/dev/tty` so it still works when piped in via `curl | bash`.
  `-y`/`--yes` skips straight to flags/defaults.
- `print_secret()`: a generated Zabbix PSK is shown once, terminal-only, and never
  written to the log file.
