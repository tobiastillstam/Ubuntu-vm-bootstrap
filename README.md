# Ubuntu-vm-bootstrap

![Bash](https://img.shields.io/badge/Bash-4%2B-4EAA25)
![Platform](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04%20%7C%2026.04-E95420)
![License](https://img.shields.io/badge/License-MIT-green)
![Version](https://img.shields.io/badge/version-1.2.1-blue)

Post-install housekeeping for a freshly installed Ubuntu VM. Detects current
state and reports it; only changes anything when `--fix` is given (always
previewable via `--dry-run`). Interactive by default with a terminal attached
(a yes/no + confirm-the-default wizard); flag-driven and non-interactive
otherwise, e.g. under automation or a `curl | bash` pipe.

---

## What it does

**Core** (always runs when in scope):

- Enables the `universe` apt repo
- Full `apt update && apt full-upgrade && apt autoremove && apt autoclean`
- Timezone and NTP (`systemd-timesyncd`)
- Guest tools matching the detected hypervisor - XCP-ng/Xen, KVM/Proxmox,
  VMware, Hyper-V, VirtualBox (auto-detected via `systemd-detect-virt`,
  override with `--hypervisor`)
- Baseline CLI packages (curl, wget, vim, htop, unzip, net-tools,
  bind9-dnsutils, tmux, git, ca-certificates, gnupg, lsb-release, jq, tree,
  ncdu)

**Optional** (each its own opt-in flag on top of `--fix`):

| Flag | Does |
| --- | --- |
| `--harden` | SSH: disable root login + password auth (key-only). Refuses if no `authorized_keys` is found, unless `--force-ssh`. Also enables UFW (allow OpenSSH, default deny incoming). |
| `--swap` | Creates a swap file (`--swap-size`, default 2G). Skipped if swap already exists or there isn't enough free disk space. |
| `--unattended-upgrades` | Enables unattended security upgrades, with automatic reboot disabled. |
| `--zabbix` | Installs Zabbix Agent2 with PSK encryption (`--zabbix-server` required). Opens a UFW rule for the Zabbix server if UFW is active. |

---

## Requirements

- Ubuntu 22.04 / 24.04 / 26.04, with `systemd` and `apt`.
- Bash 4+ (this is not a POSIX `sh` script - run it with `bash`, not `sh`).
- `sudo`/root only for `--fix`; a plain audit run needs no privilege.
- Interactive mode additionally needs a controlling terminal (`/dev/tty`) -
  falls back to flags/defaults with a warning if none is attached.

Hypervisor guest-tools support: **XCP-ng and KVM/Proxmox are exercised
end-to-end**. VMware, Hyper-V and VirtualBox use documented package names but
haven't been verified live - see the `NOTE` comments on each
`step_guest_tools_*` function in the script.

**Tested**: Ubuntu 26.04.1 LTS on XCP-ng, full run verified live - audit
mode, `--dry-run --fix`, a real `--fix` with every optional category
(`--harden`, `--swap`, `--unattended-upgrades`, `--zabbix`), and a second
full run to confirm idempotency. Key-based SSH access confirmed intact after
`--harden`. 22.04/24.04 use the same code paths but haven't been separately
re-verified live since v1.2.1.

---

## Installation

```bash
git clone https://github.com/tobiastillstam/Ubuntu-vm-bootstrap.git ubuntu-vm-bootstrap
cd ubuntu-vm-bootstrap
chmod +x ubuntu-vm-bootstrap.sh
```

Or as a remote one-liner (needs an actual controlling terminal for the
wizard's prompts - an interactive SSH session, not a detached/scripted one):

```bash
curl -fsSL https://raw.githubusercontent.com/tobiastillstam/Ubuntu-vm-bootstrap/main/ubuntu-vm-bootstrap.sh | sudo bash
```

Flags still work piped in via `bash -s --`, which also skips the wizard's
mutable-state questions for whatever you pass explicitly (the wizard still
confirms them, just with your value as the default):

```bash
curl -fsSL <url> | sudo bash -s -- --yes --fix --harden
```

---

## Quick start

```bash
# Interactive wizard (needs a terminal): asks yes/no + confirm-default for
# every setting, applies at the end.
sudo ./ubuntu-vm-bootstrap.sh

# Non-interactive, safe preview: report intended actions, change nothing.
./ubuntu-vm-bootstrap.sh --yes --fix --dry-run --verbose

# Non-interactive, apply core + every optional category.
sudo ./ubuntu-vm-bootstrap.sh --yes --fix --harden --swap \
    --unattended-upgrades --zabbix --zabbix-server zbx.tillnet.local
```

---

## Usage

```
./ubuntu-vm-bootstrap.sh [-y|--yes] [-n|--dry-run] [--fix] [-v|--verbose]
                         [-q|--quiet] [--log-file PATH]
                         [--hypervisor auto|xcpng|kvm|vmware|hyperv|virtualbox|none]
                         [--harden] [--force-ssh]
                         [--swap] [--swap-size SIZE]
                         [--unattended-upgrades]
                         [--zabbix --zabbix-server ADDRESS]
                         [--timezone TZ] [--ntp-server HOST] [-h|--help]
```

| Option | Description |
| --- | --- |
| `-y, --yes` | Skip the interactive wizard; use flags/defaults only. |
| `-n, --dry-run` | Report intended actions; make no changes. Does **not** require root. |
| `--fix` | Opt-in: perform core housekeeping (still honours `--dry-run`). |
| `-v, --verbose` / `-q, --quiet` | Debug-level output / warnings and errors only. |
| `--log-file PATH` | Also append logs to PATH. |
| `--timezone TZ` | Timezone to set (default: `Europe/Stockholm`). |
| `--ntp-server HOST` | NTP server for timesyncd (default: `ntp.se`). |
| `--hypervisor VALUE` | Override guest-tools auto-detection. |
| `-h, --help` / `--version` | Show help / version and exit. |

Run `./ubuntu-vm-bootstrap.sh --help` for the full reference including every
optional-category flag.

---

## Safety notes

- A plain run (no `--fix`) changes nothing - audit/report only.
- `--dry-run` previews exactly what `--fix` would do, without touching the
  system, and does not require root.
- `--harden` refuses to disable SSH password auth if no `authorized_keys` is
  found anywhere on the system (would lock you out) - override with
  `--force-ssh` only if you are certain another access path exists.
- A generated Zabbix PSK is printed to the terminal once, and only there - it
  is never written to `--log-file` or any log.
- Test in a non-production environment before relying on this against
  production VMs.

---

## License

[MIT](LICENSE) (c) 2026 Tobias Tillstam (Tillnet)

Provided as-is, without warranty. See [CHANGELOG.md](CHANGELOG.md) for version history.
