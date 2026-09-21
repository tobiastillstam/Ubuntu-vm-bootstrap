# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Verified
- `--harden`'s lockout-safety refusal (no `authorized_keys` anywhere, no
  `--force-ssh`): tested live over a password-only session with no key
  present on the system anywhere. Correctly logs an error, fails just that
  one category, and leaves `sshd_config`/`PasswordAuthentication`
  untouched; password login still worked immediately afterward. Every
  prior `--harden` test had a key pre-added, so this was the first time
  the actual anti-lockout mechanism - not just "key still works after
  hardening" - was exercised.

## [1.2.3] - 2026-09-21

### Fixed
- NTP: Ubuntu replaced `systemd-timesyncd` with `chrony` as the default
  time-sync daemon starting with 25.10 (carries into 26.04) - see
  [Ubuntu's time synchronization docs](https://ubuntu.com/server/docs/explanation/networking/about-time-synchronisation/).
  The script was still force-installing `systemd-timesyncd` on 26.04,
  displacing the OS's actual default. `step_ntp()` now dispatches on
  `OS_VERSION_ID` (`dpkg --compare-versions ... ge 25.10`): 22.04/24.04 keep
  the existing `systemd-timesyncd`/`timesyncd.conf` path unchanged; 25.10+
  uses a new `step_ntp_chrony()` that writes a dedicated
  `/etc/chrony/sources.d/00-tillnet-ntp.sources` drop-in and comments out
  Ubuntu's default 4-server NTS pool file, so `--ntp-server` keeps its
  existing "hard override" meaning on both backends. `timedatectl`'s
  `NTPSynchronized` check (used to confirm sync after `--fix`) needed no
  change - it reports correctly for either backend.

### Verified
- Live on Ubuntu 26.04.1 LTS/XCP-ng: audit mode, `--dry-run --fix`, a real
  `--fix` with the default server, `--ntp-server` pointed at a different
  server (change detection + resync), idempotency after each, and the
  chrony-not-installed install path (apt correctly swaps out `ntpsec`, the
  competing time-daemon alternative, for `chrony`).

## [1.2.2] - 2026-09-19

### Fixed
- The documented `curl | bash` one-liner crashed immediately with
  `BASH_SOURCE[0]: unbound variable`. Piping the script into `bash -s --`
  leaves `BASH_SOURCE` empty (no source file), and `set -u` turns
  dereferencing `BASH_SOURCE[0]` into a hard error before the script gets
  anywhere near the wizard/TTY logic that was supposed to handle the pipe
  case. `SCRIPT_DIR`/`SCRIPT_NAME` now fall back to the CWD and the
  project's own name when there's no `BASH_SOURCE[0]` to read. Found by
  actually running the documented one-liner end-to-end against the test VM
  after making the repo public, rather than just `scp`-ing the file over.

## [1.2.1] - 2026-09-19

### Fixed
- Baseline packages: `dnsutils` is a fully retired transitional name on
  Ubuntu 24.04+/26.04 (no dpkg entry, no apt candidate - `bind9-dnsutils` is
  the real package). Audit mode permanently reported it "missing" and every
  `--fix` run reinstalled it. Now checks/installs `bind9-dnsutils` directly.
- `--harden`: the SSH drop-in was named `99-tillnet-hardening.conf`, but
  sshd applies the *first* value it sees per keyword across all `Include`d
  files, not the last. On any cloud-init-provisioned VM (`50-cloud-init.conf`
  sets `PasswordAuthentication yes` and sorts first), the script silently
  failed to disable password auth while still logging success. Renamed the
  drop-in to `00-tillnet-hardening.conf` so it sorts first and wins, and
  added a post-restart check via `sshd -T` that fails loudly instead of
  claiming success if some other drop-in still overrides it.

### Verified
- Full live run against Ubuntu 26.04.1 LTS on XCP-ng: audit mode,
  `--dry-run --fix`, a real `--fix` with every optional category (`--harden`,
  `--swap`, `--unattended-upgrades`, `--zabbix`), and a second full run to
  confirm idempotency. Key-based SSH access confirmed intact after
  `--harden` (no lockout).

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
