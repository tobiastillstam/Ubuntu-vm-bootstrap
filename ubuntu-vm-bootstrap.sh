#!/usr/bin/env bash
# =============================================================================
# Post-install housekeeping for a freshly installed Ubuntu VM (XCP-ng guest).
#
# DESCRIPTION
#     Runs inside the guest, post-boot. Detects current state and reports it;
#     only changes anything when --fix is given (still previewable via
#     --dry-run). Core steps always run when in scope: enable universe repo,
#     full apt update/upgrade, timezone, NTP (systemd-timesyncd), guest tools
#     matching the detected hypervisor (XCP-ng/Xen, KVM/Proxmox, VMware,
#     Hyper-V, VirtualBox -- auto-detected via systemd-detect-virt, override
#     with --hypervisor), baseline CLI packages. Optional categories are
#     further opt-in on top of --fix: --harden (SSH key-only + UFW), --swap,
#     --unattended-upgrades, --zabbix (Agent2 + PSK, plus a UFW allow rule
#     for the Zabbix server if UFW is active).
#
#     Interactive by default: with a real terminal attached (a direct SSH
#     session, or `curl | bash` run by hand) it walks through the same
#     choices as a yes/no + confirm-the-default wizard instead of requiring
#     flags. Pass -y/--yes to skip the wizard and use flags/defaults only
#     (this is what happens automatically anyway when there's no terminal
#     attached, e.g. under automation).
#
# USAGE
#     ./ubuntu-vm-bootstrap.sh [-y|--yes] [-n|--dry-run] [--fix] [-v|--verbose]
#                              [-q|--quiet] [--log-file PATH]
#                              [--hypervisor auto|xcpng|kvm|vmware|hyperv|virtualbox|none]
#                              [--harden] [--force-ssh]
#                              [--swap] [--swap-size SIZE]
#                              [--unattended-upgrades]
#                              [--zabbix --zabbix-server ADDRESS]
#                              [--timezone TZ] [--ntp-server HOST] [-h|--help]
#
#     Remote, one-liner (needs an actual controlling terminal for the
#     wizard's prompts -- an interactive SSH session, not a detached/
#     scripted one). Use bash explicitly: this script is not POSIX sh.
#         curl -fsSL https://scripts.tillnet.se/ubuntu-vm-bootstrap.sh | sudo bash
#     Flags still work piped in via `bash -s --`, which also skips the
#     wizard's mutable-state questions for whatever you pass explicitly
#     (the wizard still confirms them, just with your value as the default):
#         curl -fsSL <url> | sudo bash -s -- --yes --fix --harden
#
# EXAMPLES
#     # Interactive wizard (needs a terminal): asks yes/no + confirm-default
#     # for every setting, applies at the end.
#     sudo ./ubuntu-vm-bootstrap.sh
#
#     # Non-interactive, safe preview: report intended actions, change nothing.
#     ./ubuntu-vm-bootstrap.sh --yes --fix --dry-run --verbose
#
#     # Non-interactive, apply core + every optional category.
#     sudo ./ubuntu-vm-bootstrap.sh --yes --fix --harden --swap \
#         --unattended-upgrades --zabbix --zabbix-server zbx.tillnet.local
#
# NOTES
#     Author  : Tobias Tillstam, Tillnet (https://tillnet.se)
#     GitHub  : https://github.com/tobiastillstam
#     License : MIT
#     Version : 1.2.0
#     Requires: bash 4+, coreutils, Ubuntu 22.04/24.04/26.04 with systemd + apt.
#               Guest tools auto-detect the hypervisor (XCP-ng/Xen, KVM/
#               Proxmox, VMware, Hyper-V, VirtualBox); only the XCP-ng and
#               KVM paths have been exercised end-to-end, the rest use
#               documented package names but haven't been tested live --
#               see the NOTE comments on each step_guest_tools_* function.
#               Interactive mode additionally needs a controlling terminal
#               (/dev/tty) -- falls back to flags/defaults with a warning
#               if none is attached.
#
#     Conventions (mirrors the Tillnet PowerShell/Bash template):
#       - Strict mode (set -Eeuo pipefail) is the error-handling backbone.
#       - trap-based cleanup is the try/finally analog.
#       - Opt-in remediation: nothing changes without --fix; --dry-run
#         previews --fix's actions (via run(), the ShouldProcess analog)
#         without executing them. The wizard just sets these interactively
#         instead of via flags -- the underlying opt-in model is unchanged.
#       - Each optional category (--harden/--swap/--unattended-upgrades/
#         --zabbix) is its own opt-in switch on top of --fix, so a VM only
#         gets what was actually asked for.
#       - Per-step failures are caught locally (run ... || return 1) so one
#         category failing doesn't stop the others from being attempted;
#         genuinely unexpected/unguarded failures still hit the ERR trap.
#       - ASCII-only output (no color), safe for journald, files, and pipes.
#       - Script-relative paths (independent of the caller's CWD).
#       - Runs unprivileged by default; root is only required for --fix,
#         checked explicitly (once) rather than assumed.
#       - Deviations from the base template:
#           * print_secret() (see below) -- a generated Zabbix PSK must
#             never land in a log file, and the base template's logging
#             always writes to LOG_FILE.
#           * ask_yesno()/ask_value()/run_wizard() -- an interactive layer
#             on top of the same flag-driven core; reads from /dev/tty
#             specifically (not stdin) so it still works when the script
#             itself arrived via a `curl | bash` pipe.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Metadata
# -----------------------------------------------------------------------------
readonly VERSION="1.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
readonly SCRIPT_NAME
readonly DEFAULT_LOG_DIR="${SCRIPT_DIR}/logs"

# -----------------------------------------------------------------------------
# Defaults (overridable by arguments)
# -----------------------------------------------------------------------------
DRY_RUN=0
DO_FIX=0
VERBOSE=0
QUIET=0
LOG_FILE=""
SKIP_WIZARD=0   # -y/--yes: skip interactive prompts, use flags/defaults only

DO_HARDEN=0
FORCE_SSH=0
DO_SWAP=0
SWAP_SIZE="2G"
DO_UNATTENDED=0
DO_ZABBIX=0
ZABBIX_SERVER=""
TIMEZONE="Europe/Stockholm"
NTP_SERVER="ntp.se"

# TTY_AVAILABLE: is a real controlling terminal reachable at /dev/tty? This is
# deliberately NOT `[[ -t 0 ]]` -- under `curl | bash`, stdin (fd 0) is the
# pipe from curl, not a terminal, even when a real interactive SSH session
# (and therefore /dev/tty) is right there. The wizard reads prompts from
# /dev/tty specifically for this reason.
#
# It's also deliberately NOT `[[ -r /dev/tty && -w /dev/tty ]]` -- that only
# checks permission bits on the device node and can be true even with no
# controlling terminal actually attached (confirmed: gives a false positive
# in at least one sandboxed/detached environment). Actually attempting to
# open it is the only reliable test.
TTY_AVAILABLE=0
if { : < /dev/tty; } 2>/dev/null; then
    TTY_AVAILABLE=1
fi

# Domain constants
readonly BASELINE_PACKAGES=(curl wget vim htop unzip net-tools dnsutils tmux
    git ca-certificates gnupg lsb-release jq tree ncdu)
readonly ZABBIX_MAJOR_MINOR="7.0"
readonly ZABBIX_PSK_FILE="/etc/zabbix/zabbix_agent2.psk"
readonly ZABBIX_AGENT_PORT="10050"   # Agent2's listen port for passive checks
readonly SSH_DROPIN="/etc/ssh/sshd_config.d/99-tillnet-hardening.conf"
TMP_ZABBIX_DEB=""   # set by step_zabbix_agent2 if it downloads one; cleaned up on exit

# Populated by detect_os(); used by step_zabbix_agent2 for the repo URL
OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""
OS_PRETTY=""

# Hypervisor: "auto" detects via systemd-detect-virt; override with --hypervisor
# to one of xcpng|kvm|vmware|hyperv|virtualbox|none if auto-detection is wrong
# or ambiguous for your environment.
HYPERVISOR_OVERRIDE="auto"
HYPERVISOR=""   # resolved by detect_hypervisor(), called from do_work()

# Filled in as the run progresses, for the end-of-run summary
FAILED_CATEGORIES=()
NOTES=()
SECRETS=()   # printed via print_secret() only -- never written to LOG_FILE

# -----------------------------------------------------------------------------
# Logging  (ASCII, timestamped, stderr + optional file)
# -----------------------------------------------------------------------------
_log() {
    local level="$1"; shift
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="${ts} ${level} $*"
    printf '%s\n' "${line}" >&2
    if [[ -n "${LOG_FILE}" ]]; then
        printf '%s\n' "${line}" >>"${LOG_FILE}"
    fi
}
log_info()  { [[ "${QUIET}"   -eq 1 ]] && return 0; _log "INFO  " "$@"; }
log_warn()  { _log "WARN  " "$@"; }
log_error() { _log "ERROR " "$@"; }
log_debug() { [[ "${VERBOSE}" -eq 1 ]] || return 0; _log "DEBUG " "$@"; }

# print_secret: terminal-only output for anything sensitive (PSKs, passwords).
# Deliberately does NOT go through _log()/LOG_FILE -- see header NOTES.
print_secret() {
    printf '%s\n' "$*"
}

# join_by: safe space-joining of array elements. IFS is set to $'\n\t' above,
# so "${arr[*]}" would join with a newline instead of a space -- this avoids
# that footgun without touching the global IFS.
join_by() {
    local sep="$1"; shift
    local IFS="${sep}"
    echo "$*"
}

# -----------------------------------------------------------------------------
# Cleanup / error trap  (the try/finally analog)
# -----------------------------------------------------------------------------
cleanup() {
    local rc=$?
    log_debug "=== ${SCRIPT_NAME} end (rc=${rc}) ==="
    if [[ -n "${TMP_ZABBIX_DEB}" && -f "${TMP_ZABBIX_DEB}" ]]; then
        rm -f "${TMP_ZABBIX_DEB}"
    fi
    # NOTE: deliberately `return 0`, not `return "${rc}"` -- bash preserves the
    # original `exit N` code independent of what the EXIT-trap handler returns,
    # and returning a non-zero rc here re-triggers the ERR trap on every
    # non-zero exit (confirmed: harmless but noisy "Failed at line 1" spam).
    return 0
}
on_error() {
    log_error "Failed at line ${1} (exit ${2})."
}
trap 'on_error "${LINENO}" "$?"' ERR
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Guards
# -----------------------------------------------------------------------------
require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
}
require_cmd() {
    # Usage: require_cmd curl jq ...
    local missing=0 c
    for c in "$@"; do
        if ! command -v "${c}" >/dev/null 2>&1; then
            log_error "Required command not found: ${c}"
            missing=1
        fi
    done
    [[ "${missing}" -eq 0 ]] || exit 1
}

# -----------------------------------------------------------------------------
# ShouldProcess analog: route every state change through run()
# -----------------------------------------------------------------------------
run() {
    # Usage: run "<description>" command args...
    local desc="$1"; shift
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "WHATIF: would ${desc}"
        return 0
    fi
    log_debug "Performing: ${desc}"
    "$@"
}

# -----------------------------------------------------------------------------
# Interactive wizard (deviation from the base template -- see header NOTES).
# Reads from /dev/tty explicitly, never plain stdin, so this still works when
# the script itself arrived via `curl | bash` (stdin is curl's pipe there).
# -----------------------------------------------------------------------------

# ask_yesno: prompt, default "y" or "n" -> sets REPLY_YESNO to 1 or 0.
# Falls back to the default (with a warning) if no terminal is reachable.
ask_yesno() {
    local question="$1" default="$2" ans suffix
    if [[ "${default}" == "y" ]]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
    if [[ "${TTY_AVAILABLE}" -eq 0 ]]; then
        log_warn "No terminal attached to ask '${question}' -- using default (${default})"
        [[ "${default}" == "y" ]] && REPLY_YESNO=1 || REPLY_YESNO=0
        return 0
    fi
    while true; do
        read -r -p "${question} ${suffix} " ans < /dev/tty || ans=""
        ans="${ans:-${default}}"
        case "${ans}" in
            [Yy]*) REPLY_YESNO=1; return 0 ;;
            [Nn]*) REPLY_YESNO=0; return 0 ;;
            *) printf 'Please answer y or n.\n' > /dev/tty ;;
        esac
    done
}

# ask_value: prompt with a pre-filled default -> sets REPLY_VALUE.
# Enter alone accepts the default. Falls back to the default if no terminal.
ask_value() {
    local question="$1" default="$2" ans
    if [[ "${TTY_AVAILABLE}" -eq 0 ]]; then
        log_warn "No terminal attached to ask '${question}' -- using default (${default})"
        REPLY_VALUE="${default}"
        return 0
    fi
    read -r -p "${question} [${default}]: " ans < /dev/tty || ans=""
    REPLY_VALUE="${ans:-${default}}"
}

# ask_required_value: like ask_value but with no default -- loops until
# something non-empty is entered. Used for the Zabbix server address.
ask_required_value() {
    local question="$1" ans
    if [[ "${TTY_AVAILABLE}" -eq 0 ]]; then
        log_error "No terminal attached to ask required question '${question}'"
        REPLY_VALUE=""
        return 1
    fi
    while true; do
        read -r -p "${question}: " ans < /dev/tty || ans=""
        if [[ -n "${ans}" ]]; then
            REPLY_VALUE="${ans}"
            return 0
        fi
        printf 'This value is required.\n' > /dev/tty
    done
}

# run_wizard: interactively confirms/overrides every setting. Existing values
# (already set by defaults or by flags) are shown and used as the default for
# each question, so a flag pre-seeds an answer without skipping the question --
# per Tobbe's request, every setting is always confirmable, not just askable.
run_wizard() {
    printf '\n== %s interactive setup ==\n' "${SCRIPT_NAME}" > /dev/tty
    printf 'Press Enter to accept the default shown in [brackets], or type your own answer.\n\n' > /dev/tty

    local apply_default="n"
    [[ "${DO_FIX}" -eq 1 ]] && apply_default="y"
    ask_yesno "Apply changes to this system now? (no = audit/report only)" "${apply_default}"
    DO_FIX="${REPLY_YESNO}"

    if [[ "${DO_FIX}" -eq 1 ]]; then
        # Ask about dry-run BEFORE enforcing root: a preview never touches the
        # system, so a non-root user must be able to reach it. Root is only
        # actually required once they confirm they want to apply for real.
        local dryrun_default="n"
        [[ "${DRY_RUN}" -eq 1 ]] && dryrun_default="y"
        ask_yesno "Preview only (dry-run) instead of actually applying?" "${dryrun_default}"
        DRY_RUN="${REPLY_YESNO}"

        if [[ "${DRY_RUN}" -eq 0 && "${EUID}" -ne 0 ]]; then
            log_error "Applying changes requires root. Re-run with sudo, e.g.:"
            log_error "  sudo ${SCRIPT_NAME}.sh    (or: curl -fsSL <url> | sudo bash)"
            exit 1
        fi
    fi

    ask_value "Timezone" "${TIMEZONE}"
    TIMEZONE="${REPLY_VALUE}"

    ask_value "NTP server" "${NTP_SERVER}"
    NTP_SERVER="${REPLY_VALUE}"

    local harden_default="n"; [[ "${DO_HARDEN}" -eq 1 ]] && harden_default="y"
    ask_yesno "Harden SSH (disable root login + password auth, key-only) and enable UFW?" "${harden_default}"
    DO_HARDEN="${REPLY_YESNO}"

    local swap_default="n"; [[ "${DO_SWAP}" -eq 1 ]] && swap_default="y"
    ask_yesno "Create a swap file?" "${swap_default}"
    DO_SWAP="${REPLY_YESNO}"
    if [[ "${DO_SWAP}" -eq 1 ]]; then
        ask_value "Swap size" "${SWAP_SIZE}"
        SWAP_SIZE="${REPLY_VALUE}"
    fi

    local unattended_default="n"; [[ "${DO_UNATTENDED}" -eq 1 ]] && unattended_default="y"
    ask_yesno "Enable unattended security upgrades (no auto-reboot)?" "${unattended_default}"
    DO_UNATTENDED="${REPLY_YESNO}"

    local zabbix_default="n"; [[ "${DO_ZABBIX}" -eq 1 ]] && zabbix_default="y"
    ask_yesno "Install Zabbix Agent2 with PSK encryption?" "${zabbix_default}"
    DO_ZABBIX="${REPLY_YESNO}"
    if [[ "${DO_ZABBIX}" -eq 1 ]]; then
        if [[ -n "${ZABBIX_SERVER}" ]]; then
            ask_value "Zabbix server/proxy address (Server, ServerActive, and the UFW allow rule)" "${ZABBIX_SERVER}"
            ZABBIX_SERVER="${REPLY_VALUE}"
        else
            ask_required_value "Zabbix server/proxy address (Server, ServerActive, and the UFW allow rule)"
            ZABBIX_SERVER="${REPLY_VALUE}"
        fi
    fi

    printf '\n' > /dev/tty
    log_info "Setup: fix=${DO_FIX} dry_run=${DRY_RUN} timezone=${TIMEZONE} ntp=${NTP_SERVER}" \
              "harden=${DO_HARDEN} swap=${DO_SWAP}(${SWAP_SIZE}) unattended=${DO_UNATTENDED}" \
              "zabbix=${DO_ZABBIX}(${ZABBIX_SERVER:-n/a})"
}

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
${SCRIPT_NAME} ${VERSION} - Tillnet (https://tillnet.se)

Usage: ${SCRIPT_NAME}.sh [options]

Interactive by default with a terminal attached (asks yes/no + confirms
every default). Pass -y/--yes to skip straight to flags/defaults.

Core options:
  -y, --yes            Skip the interactive wizard; use flags/defaults only.
  -n, --dry-run        Report intended actions; make no changes.
      --fix            Opt-in: perform core housekeeping (still honours --dry-run).
  -v, --verbose        Debug-level output.
  -q, --quiet          Warnings and errors only.
      --log-file PATH  Also append logs to PATH.
                       Suggested: ${DEFAULT_LOG_DIR}/${SCRIPT_NAME}.log
  -h, --help           Show this help and exit.
      --version        Show version and exit.

Core settings:
      --timezone TZ            Timezone to set (default: ${TIMEZONE}).
      --ntp-server HOST        NTP server for timesyncd (default: ${NTP_SERVER}).
      --hypervisor VALUE       auto (default) | xcpng | kvm | vmware | hyperv |
                                virtualbox | none. Overrides guest-tools
                                auto-detection (systemd-detect-virt); "kvm"
                                also covers Proxmox VE.

Optional categories (require --fix to take effect):
      --harden                 SSH: disable root login + password auth (key-only).
                                Refuses if no authorized_keys is found (see --force-ssh);
                                interactively asks for confirmation instead, if a
                                terminal is attached.
                                Also enables UFW (allow OpenSSH, default deny incoming).
      --force-ssh               Skip the authorized_keys safety check for --harden.
      --swap                    Create a swap file (skipped if swap already exists).
      --swap-size SIZE          Swap file size (default: ${SWAP_SIZE}).
      --unattended-upgrades     Enable unattended security upgrades (no auto-reboot).
      --zabbix                  Install Zabbix Agent2 with PSK encryption. Also opens
                                 UFW to the Zabbix server on tcp/${ZABBIX_AGENT_PORT} if UFW is active.
      --zabbix-server ADDRESS   Zabbix server/proxy address (required for --zabbix).
EOF
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)     SKIP_WIZARD=1 ;;
            -n|--dry-run) DRY_RUN=1 ;;
            --fix)        DO_FIX=1 ;;
            -v|--verbose) VERBOSE=1 ;;
            -q|--quiet)   QUIET=1 ;;
            --log-file)
                [[ $# -ge 2 ]] || { log_error "--log-file needs an argument."; exit 2; }
                LOG_FILE="$2"; shift ;;
            --log-file=*) LOG_FILE="${1#*=}" ;;

            --harden)     DO_HARDEN=1 ;;
            --force-ssh)  FORCE_SSH=1 ;;
            --swap)       DO_SWAP=1 ;;
            --swap-size)
                [[ $# -ge 2 ]] || { log_error "--swap-size needs an argument."; exit 2; }
                SWAP_SIZE="$2"; shift ;;
            --swap-size=*) SWAP_SIZE="${1#*=}" ;;
            --unattended-upgrades) DO_UNATTENDED=1 ;;
            --zabbix)     DO_ZABBIX=1 ;;
            --zabbix-server)
                [[ $# -ge 2 ]] || { log_error "--zabbix-server needs an argument."; exit 2; }
                ZABBIX_SERVER="$2"; shift ;;
            --zabbix-server=*) ZABBIX_SERVER="${1#*=}" ;;
            --timezone)
                [[ $# -ge 2 ]] || { log_error "--timezone needs an argument."; exit 2; }
                TIMEZONE="$2"; shift ;;
            --timezone=*) TIMEZONE="${1#*=}" ;;
            --ntp-server)
                [[ $# -ge 2 ]] || { log_error "--ntp-server needs an argument."; exit 2; }
                NTP_SERVER="$2"; shift ;;
            --ntp-server=*) NTP_SERVER="${1#*=}" ;;
            --hypervisor)
                [[ $# -ge 2 ]] || { log_error "--hypervisor needs an argument."; exit 2; }
                HYPERVISOR_OVERRIDE="$2"; shift ;;
            --hypervisor=*) HYPERVISOR_OVERRIDE="${1#*=}" ;;

            -h|--help)    usage; exit 0 ;;
            --version)    printf '%s %s\n' "${SCRIPT_NAME}" "${VERSION}"; exit 0 ;;
            --)           shift; break ;;
            -*)           log_error "Unknown option: $1"; usage; exit 2 ;;
            *)            break ;;
        esac
        shift
    done
    if [[ "${VERBOSE}" -eq 1 && "${QUIET}" -eq 1 ]]; then
        log_error "--verbose and --quiet are mutually exclusive."
        exit 2
    fi
    if [[ "${DO_ZABBIX}" -eq 1 && -z "${ZABBIX_SERVER}" ]]; then
        log_error "--zabbix requires --zabbix-server ADDRESS."
        exit 2
    fi
    case "${HYPERVISOR_OVERRIDE}" in
        auto|xcpng|kvm|vmware|hyperv|virtualbox|none) ;;
        *)
            log_error "--hypervisor must be one of: auto, xcpng, kvm, vmware, hyperv, virtualbox, none."
            exit 2
            ;;
    esac
}

init_logging() {
    if [[ -n "${LOG_FILE}" ]]; then
        mkdir -p "$(dirname "${LOG_FILE}")"
    fi
}

# -----------------------------------------------------------------------------
# OS detection (fatal precondition -- aborts outright, not caught/continued)
# -----------------------------------------------------------------------------
detect_os() {
    if [[ ! -r /etc/os-release ]]; then
        log_error "/etc/os-release not found -- cannot confirm this is Ubuntu."
        exit 1
    fi
    # Parse specific fields rather than sourcing the file -- os-release defines
    # its own VERSION=, which would clobber this script's readonly VERSION.
    OS_ID="$(grep -E '^ID=' /etc/os-release | head -n1 | cut -d= -f2 | tr -d '"')"
    OS_VERSION_ID="$(grep -E '^VERSION_ID=' /etc/os-release | head -n1 | cut -d= -f2 | tr -d '"')"
    OS_CODENAME="$(grep -E '^VERSION_CODENAME=' /etc/os-release | head -n1 | cut -d= -f2 | tr -d '"')"
    OS_PRETTY="$(grep -E '^PRETTY_NAME=' /etc/os-release | head -n1 | cut -d= -f2 | tr -d '"')"
    OS_PRETTY="${OS_PRETTY:-Ubuntu}"
    if [[ "${OS_ID}" != "ubuntu" ]]; then
        log_error "This script targets Ubuntu; detected ID='${OS_ID:-unknown}'."
        exit 1
    fi
    log_info "Detected: ${OS_PRETTY} (codename: ${OS_CODENAME:-unknown})"
}

# detect_hypervisor: maps systemd-detect-virt's output to the guest-tools
# category step_guest_tools() knows how to handle. --hypervisor overrides
# this outright (skips detection entirely) for cases auto-detection gets
# wrong or can't disambiguate.
#
# Confirmed identifiers (systemd-detect-virt(1)): xen, kvm, qemu, amazon,
# vmware, microsoft (Hyper-V), oracle (VirtualBox), none (bare metal), and
# others we don't have a guest-tools package for (bochs, uml, parallels,
# bhyve, powervm, zvm, ...) -- those fall through to "none" (skip, don't
# guess). Proxmox VE runs on KVM and has no distinct fingerprint of its own,
# so it's covered by the "kvm" case, same as any other QEMU/KVM host.
detect_hypervisor() {
    if [[ "${HYPERVISOR_OVERRIDE}" != "auto" ]]; then
        HYPERVISOR="${HYPERVISOR_OVERRIDE}"
        log_info "Hypervisor: ${HYPERVISOR} (forced via --hypervisor)"
        return 0
    fi
    local virt="none"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt="$(systemd-detect-virt 2>/dev/null || echo none)"
    fi
    case "${virt}" in
        xen)              HYPERVISOR="xcpng" ;;
        kvm|qemu|amazon)  HYPERVISOR="kvm" ;;
        vmware)           HYPERVISOR="vmware" ;;
        microsoft)        HYPERVISOR="hyperv" ;;
        oracle)           HYPERVISOR="virtualbox" ;;
        none)             HYPERVISOR="none" ;;
        *)                HYPERVISOR="none"
                           log_warn "systemd-detect-virt reported '${virt}', which has no guest-tools mapping here -- skipping. Use --hypervisor to force one." ;;
    esac
    log_info "Hypervisor: ${HYPERVISOR} (auto-detected as '${virt}')"
}

package_installed() {
    dpkg -s "$1" >/dev/null 2>&1
}

wait_for_apt_lock() {
    local timeout=180 waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
        || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if (( waited >= timeout )); then
            log_warn "apt lock still held after ${timeout}s, proceeding anyway"
            return 0
        fi
        log_info "apt is locked by another process, waiting... (${waited}s)"
        sleep 5
        waited=$(( waited + 5 ))
    done
}

# -----------------------------------------------------------------------------
# Core steps
# -----------------------------------------------------------------------------
step_universe_repo() {
    if apt-cache policy 2>/dev/null | grep -q "universe"; then
        log_info "universe repo already enabled"
        return 0
    fi
    if [[ "${DO_FIX}" -eq 1 ]]; then
        run "enable universe repo" add-apt-repository -y universe || return 1
    else
        log_warn "universe repo not enabled. Re-run with --fix to enable it."
    fi
    return 0
}

step_system_update() {
    if [[ "${DO_FIX}" -eq 1 ]]; then
        wait_for_apt_lock
        run "apt-get update" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
            apt-get update -y || return 1
        wait_for_apt_lock
        run "apt-get full-upgrade" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
            apt-get full-upgrade -y || return 1
        run "apt-get autoremove" env DEBIAN_FRONTEND=noninteractive \
            apt-get autoremove -y --purge || return 1
        run "apt-get autoclean" env DEBIAN_FRONTEND=noninteractive \
            apt-get autoclean -y || return 1
    else
        log_warn "System update/upgrade not run. Re-run with --fix to update."
    fi
    if [[ -f /var/run/reboot-required ]]; then
        log_warn "Reboot required (kernel or core library update). Not rebooting automatically."
        local reboot_pkgs=()
        if [[ -r /var/run/reboot-required.pkgs ]]; then
            mapfile -t reboot_pkgs < /var/run/reboot-required.pkgs
        fi
        NOTES+=("Reboot required: $(join_by ' ' "${reboot_pkgs[@]:-}")")
    fi
    return 0
}

step_timezone() {
    local current
    current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    if [[ "${current}" == "${TIMEZONE}" ]]; then
        log_info "Timezone already set to ${TIMEZONE}"
        return 0
    fi
    if [[ "${DO_FIX}" -eq 1 ]]; then
        run "set timezone to ${TIMEZONE} (currently ${current:-unknown})" \
            timedatectl set-timezone "${TIMEZONE}" || return 1
    else
        log_warn "Timezone is '${current:-unknown}', expected '${TIMEZONE}'. Re-run with --fix to change."
    fi
    return 0
}

step_ntp() {
    local conf="/etc/systemd/timesyncd.conf"
    if [[ ! -f "${conf}" ]]; then
        log_error "systemd-timesyncd config not found at ${conf} -- is timesyncd installed?"
        return 1
    fi
    local current
    current="$(grep -E '^\s*NTP=' "${conf}" 2>/dev/null | tail -n1 | cut -d= -f2 | xargs || true)"
    if [[ "${current}" == "${NTP_SERVER}" ]]; then
        log_info "NTP server already set to ${NTP_SERVER}"
    elif [[ "${DO_FIX}" -eq 1 ]]; then
        run "set NTP=${NTP_SERVER} in ${conf} (currently '${current:-unset}')" \
            bash -c "if grep -qE '^\s*#?\s*NTP=' '${conf}'; then
                         sed -i -E 's|^\s*#?\s*NTP=.*|NTP=${NTP_SERVER}|' '${conf}'
                     else
                         printf 'NTP=%s\n' '${NTP_SERVER}' >> '${conf}'
                     fi" || return 1
        run "restart systemd-timesyncd" systemctl restart systemd-timesyncd || return 1
    else
        log_warn "NTP is '${current:-unset}', expected '${NTP_SERVER}'. Re-run with --fix to change."
    fi

    if [[ "${DO_FIX}" -eq 1 && "${DRY_RUN}" -eq 0 ]]; then
        systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
        sleep 2
        local synced
        synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)"
        if [[ "${synced}" == "yes" ]]; then
            log_info "Time is synchronized"
        else
            log_warn "Time not yet reported as synchronized (can take a bit after first boot/network)"
        fi
    fi
    return 0
}

step_guest_tools() {
    case "${HYPERVISOR}" in
        xcpng)     step_guest_tools_xcpng ;;
        kvm)       step_guest_tools_kvm ;;
        vmware)    step_guest_tools_vmware ;;
        hyperv)    step_guest_tools_hyperv ;;
        virtualbox) step_guest_tools_virtualbox ;;
        none|*)
            log_info "No supported hypervisor detected -- skipping guest tools"
            return 0
            ;;
    esac
}

# Well-tested: this is Tobbe's primary environment (XCP-ng).
step_guest_tools_xcpng() {
    if package_installed xe-guest-utilities && systemctl is-active --quiet xe-daemon; then
        log_info "xe-guest-utilities already installed and xe-daemon running"
        return 0
    fi
    if [[ "${DO_FIX}" -eq 1 ]]; then
        wait_for_apt_lock
        run "install xe-guest-utilities" env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y xe-guest-utilities || return 1
        run "enable xe-daemon" systemctl enable --now xe-daemon || return 1
        if [[ "${DRY_RUN}" -eq 0 ]]; then
            sleep 1
            if ! systemctl is-active --quiet xe-daemon; then
                log_error "xe-daemon did not start -- check 'systemctl status xe-daemon'"
                return 1
            fi
        fi
    else
        log_warn "xe-guest-utilities/xe-daemon not set up. Re-run with --fix to install."
    fi
    return 0
}

# Covers Proxmox VE and any other plain QEMU/KVM host -- Proxmox has no
# distinct fingerprint of its own, it's just KVM underneath.
step_guest_tools_kvm() {
    if package_installed qemu-guest-agent && systemctl is-active --quiet qemu-guest-agent; then
        log_info "qemu-guest-agent already installed and running"
        return 0
    fi
    if [[ "${DO_FIX}" -eq 1 ]]; then
        wait_for_apt_lock
        run "install qemu-guest-agent" env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y qemu-guest-agent || return 1
        run "enable qemu-guest-agent" systemctl enable --now qemu-guest-agent || return 1
        if [[ "${DRY_RUN}" -eq 0 ]]; then
            sleep 1
            if ! systemctl is-active --quiet qemu-guest-agent; then
                log_error "qemu-guest-agent did not start -- check 'systemctl status qemu-guest-agent'"
                return 1
            fi
        fi
    else
        log_warn "qemu-guest-agent not set up. Re-run with --fix to install."
    fi
    return 0
}

# NOTE: less exercised than the XCP-ng/KVM paths above -- package name is
# solid (open-vm-tools is the standard, long-stable Debian/Ubuntu package),
# but I haven't verified this end-to-end against a real VMware guest.
step_guest_tools_vmware() {
    if package_installed open-vm-tools; then
        log_info "open-vm-tools already installed"
        return 0
    fi
    if [[ "${DO_FIX}" -eq 1 ]]; then
        wait_for_apt_lock
        run "install open-vm-tools" env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y open-vm-tools || return 1
        run "enable open-vm-tools" systemctl enable --now open-vm-tools 2>/dev/null || true
    else
        log_warn "open-vm-tools not set up. Re-run with --fix to install."
    fi
    return 0
}

# NOTE: lower confidence than the paths above -- package/service naming for
# Hyper-V integration services has shifted across Ubuntu releases historically
# (linux-cloud-tools-common providing hv_kvp_daemon etc.), and I have no way
# to verify the exact service unit name in this environment. Installs the
# packages either way; only enables the service if that unit actually exists,
# and says so plainly if it doesn't rather than guessing.
step_guest_tools_hyperv() {
    if package_installed linux-tools-virtual && package_installed linux-cloud-tools-virtual; then
        log_info "Hyper-V guest tools packages already installed"
        return 0
    fi
    if [[ "${DO_FIX}" -eq 1 ]]; then
        wait_for_apt_lock
        run "install Hyper-V guest tools packages" env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y linux-tools-virtual linux-cloud-tools-virtual || return 1
        if [[ "${DRY_RUN}" -eq 0 ]]; then
            if systemctl list-unit-files 2>/dev/null | grep -q '^hv-kvp-daemon\.service'; then
                run "enable hv-kvp-daemon" systemctl enable --now hv-kvp-daemon.service || return 1
            else
                log_warn "Installed the Hyper-V packages but couldn't find an hv-kvp-daemon service unit to enable -- check manually (kernel already has the hv_* modules built in on most recent Ubuntu releases, so this may be a non-issue)."
            fi
        fi
    else
        log_warn "Hyper-V guest tools not set up. Re-run with --fix to install."
    fi
    return 0
}

# NOTE: less exercised than the XCP-ng/KVM paths -- package name is standard
# (virtualbox-guest-utils), service enablement is defensive for the same
# reason as the Hyper-V path above.
step_guest_tools_virtualbox() {
    if package_installed virtualbox-guest-utils; then
        log_info "virtualbox-guest-utils already installed"
        return 0
    fi
    if [[ "${DO_FIX}" -eq 1 ]]; then
        wait_for_apt_lock
        run "install virtualbox-guest-utils" env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y virtualbox-guest-utils || return 1
        if [[ "${DRY_RUN}" -eq 0 ]]; then
            if systemctl list-unit-files 2>/dev/null | grep -q '^vboxadd-service\.service'; then
                run "enable vboxadd-service" systemctl enable --now vboxadd-service.service || return 1
            else
                log_warn "Installed virtualbox-guest-utils but couldn't find a vboxadd-service unit to enable -- check manually."
            fi
        fi
    else
        log_warn "virtualbox-guest-utils not set up. Re-run with --fix to install."
    fi
    return 0
}

step_baseline_packages() {
    local missing=()
    for pkg in "${BASELINE_PACKAGES[@]}"; do
        package_installed "${pkg}" || missing+=("${pkg}")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        log_info "All baseline packages already installed"
        return 0
    fi
    if [[ "${DO_FIX}" -eq 1 ]]; then
        wait_for_apt_lock
        run "install baseline packages: $(join_by ' ' "${missing[@]}")" \
            env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" || return 1
    else
        log_warn "Missing baseline packages: $(join_by ' ' "${missing[@]}"). Re-run with --fix to install."
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Optional categories (each also gated by its own --flag in do_work)
# -----------------------------------------------------------------------------
step_ssh_hardening() {
    local found_key=0
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
        [[ -s "${f}" ]] && found_key=1
    done
    if [[ "${found_key}" -eq 0 && "${FORCE_SSH}" -eq 0 && "${TTY_AVAILABLE}" -eq 1 ]]; then
        log_warn "No authorized_keys found anywhere on this system."
        ask_yesno "Disabling password auth without a key could lock you out. Continue anyway?" "n"
        [[ "${REPLY_YESNO}" -eq 1 ]] && FORCE_SSH=1
    fi
    if [[ "${found_key}" -eq 0 && "${FORCE_SSH}" -eq 0 ]]; then
        log_error "No authorized_keys found anywhere -- refusing to disable password auth"
        log_error "(this would lock you out). Add a key first, or pass --force-ssh if you're sure."
        return 1
    fi
    if [[ "${found_key}" -eq 1 ]]; then
        log_info "authorized_keys found -- safe to disable password auth"
    else
        log_warn "No authorized_keys found, proceeding anyway due to --force-ssh"
    fi

    if [[ "${DO_FIX}" -eq 1 ]]; then
        run "write ${SSH_DROPIN} (disable root login + password auth)" bash -c "
            cat > '${SSH_DROPIN}' <<'INNER'
# Managed by ${SCRIPT_NAME} -- do not edit by hand
PermitRootLogin no
PasswordAuthentication no
INNER
        " || return 1
        if [[ "${DRY_RUN}" -eq 0 ]]; then
            if sshd -t; then
                run "restart ssh" bash -c "systemctl restart ssh || systemctl restart sshd" || return 1
                log_info "SSH hardened: root login and password auth disabled"
            else
                log_error "sshd -t reported invalid config -- reverting, NOT restarting ssh"
                rm -f "${SSH_DROPIN}"
                return 1
            fi
        fi
    else
        log_warn "SSH not hardened. Re-run with --fix --harden to disable root login + password auth."
    fi
    return 0
}

step_ufw() {
    if ! package_installed ufw; then
        if [[ "${DO_FIX}" -eq 1 ]]; then
            wait_for_apt_lock
            run "install ufw" env DEBIAN_FRONTEND=noninteractive apt-get install -y ufw || return 1
        else
            log_warn "ufw not installed. Re-run with --fix --harden to install and enable it."
            return 0
        fi
    fi
    if [[ "${DO_FIX}" -eq 1 ]]; then
        run "ufw allow OpenSSH" ufw allow OpenSSH || return 1
        run "ufw default deny incoming" ufw default deny incoming || return 1
        run "ufw default allow outgoing" ufw default allow outgoing || return 1
        run "ufw enable" ufw --force enable || return 1
    else
        log_warn "ufw not enabled. Re-run with --fix --harden to enable it."
    fi
    return 0
}

step_swap() {
    if swapon --show | grep -q .; then
        log_info "Swap already active, skipping"
        return 0
    fi
    local swapfile="/swapfile"
    local avail_bytes size_bytes
    avail_bytes="$(df --output=avail -B1 / | tail -n1 | xargs)"
    size_bytes="$(numfmt --from=iec "${SWAP_SIZE}" 2>/dev/null || echo 0)"
    if [[ "${size_bytes}" -eq 0 ]]; then
        log_error "Could not parse --swap-size '${SWAP_SIZE}'"
        return 1
    fi
    if (( avail_bytes < size_bytes + size_bytes / 10 )); then
        log_warn "Not enough free disk space for a ${SWAP_SIZE} swapfile (avail: $(numfmt --to=iec "${avail_bytes}")). Skipping."
        return 1
    fi
    if [[ "${DO_FIX}" -eq 1 ]]; then
        run "create ${SWAP_SIZE} swapfile at ${swapfile}" bash -c "
            fallocate -l '${SWAP_SIZE}' '${swapfile}' || dd if=/dev/zero of='${swapfile}' bs=1M count=$(( size_bytes / 1024 / 1024 ))
            chmod 600 '${swapfile}'
            mkswap '${swapfile}'
        " || return 1
        if [[ "${DRY_RUN}" -eq 0 ]]; then
            run "swapon ${swapfile}" swapon "${swapfile}" || return 1
            if ! grep -q "^${swapfile} " /etc/fstab; then
                printf '%s none swap sw 0 0\n' "${swapfile}" >> /etc/fstab
            fi
        fi
    else
        log_warn "No swap configured. Re-run with --fix --swap to create a ${SWAP_SIZE} swapfile."
    fi
    return 0
}

step_unattended_upgrades() {
    if ! package_installed unattended-upgrades; then
        if [[ "${DO_FIX}" -eq 1 ]]; then
            wait_for_apt_lock
            run "install unattended-upgrades" env DEBIAN_FRONTEND=noninteractive \
                apt-get install -y unattended-upgrades apt-listchanges || return 1
        else
            log_warn "unattended-upgrades not installed. Re-run with --fix --unattended-upgrades."
            return 0
        fi
    fi
    if [[ "${DO_FIX}" -eq 1 ]]; then
        run "configure 20auto-upgrades (security only, no auto-reboot)" bash -c "
            cat > /etc/apt/apt.conf.d/20auto-upgrades <<'INNER'
APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Unattended-Upgrade \"1\";
APT::Periodic::AutocleanInterval \"7\";
INNER
            if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]]; then
                sed -i -E 's|^\s*//?\s*Unattended-Upgrade::Automatic-Reboot\s+\".*\";|Unattended-Upgrade::Automatic-Reboot \"false\";|' \
                    /etc/apt/apt.conf.d/50unattended-upgrades
            fi
        " || return 1
        run "enable unattended-upgrades" systemctl enable --now unattended-upgrades || return 1
    else
        log_warn "unattended-upgrades not configured. Re-run with --fix --unattended-upgrades."
    fi
    return 0
}

step_zabbix_agent2() {
    local deb_url="https://repo.zabbix.com/zabbix/${ZABBIX_MAJOR_MINOR}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_MAJOR_MINOR}+ubuntu${OS_VERSION_ID}_all.deb"
    TMP_ZABBIX_DEB="/tmp/zabbix-release_${ZABBIX_MAJOR_MINOR}.deb"

    if ! package_installed zabbix-release; then
        if [[ "${DO_FIX}" -eq 1 ]]; then
            run "download zabbix-release from ${deb_url}" wget -q -O "${TMP_ZABBIX_DEB}" "${deb_url}" || {
                log_error "Failed to download ${deb_url} -- check repo.zabbix.com for the current filename for this Ubuntu release/Zabbix version"
                return 1
            }
            if [[ "${DRY_RUN}" -eq 0 ]]; then
                run "install zabbix-release package" dpkg -i "${TMP_ZABBIX_DEB}" || return 1
                wait_for_apt_lock
                run "apt-get update (post zabbix-release)" env DEBIAN_FRONTEND=noninteractive \
                    apt-get update -y || return 1
            fi
        else
            log_warn "zabbix-release repo not installed. Re-run with --fix --zabbix."
            return 0
        fi
    fi

    if ! package_installed zabbix-agent2; then
        if [[ "${DO_FIX}" -eq 1 ]]; then
            wait_for_apt_lock
            run "install zabbix-agent2" env DEBIAN_FRONTEND=noninteractive \
                apt-get install -y zabbix-agent2 || return 1
        else
            log_warn "zabbix-agent2 not installed. Re-run with --fix --zabbix."
            return 0
        fi
    fi

    local psk_identity
    psk_identity="PSK-$(hostname)"
    local conf="/etc/zabbix/zabbix_agent2.conf"

    if [[ -f "${ZABBIX_PSK_FILE}" ]]; then
        log_info "PSK file already exists at ${ZABBIX_PSK_FILE}, leaving it in place"
    elif [[ "${DO_FIX}" -eq 1 ]]; then
        run "generate PSK at ${ZABBIX_PSK_FILE}" bash -c "
            mkdir -p '$(dirname "${ZABBIX_PSK_FILE}")'
            openssl rand -hex 32 > '${ZABBIX_PSK_FILE}'
            chown zabbix:zabbix '${ZABBIX_PSK_FILE}' 2>/dev/null || true
            chmod 600 '${ZABBIX_PSK_FILE}'
        " || return 1
        if [[ "${DRY_RUN}" -eq 0 && -f "${ZABBIX_PSK_FILE}" ]]; then
            SECRETS+=("Zabbix host enrollment -- add manually on the server: Identity='${psk_identity}'  PSK='$(cat "${ZABBIX_PSK_FILE}")'")
            NOTES+=("A Zabbix PSK was generated at ${ZABBIX_PSK_FILE} -- see the PSK printed separately below (not written to the log file)")
        fi
    else
        log_warn "No Zabbix PSK yet. Re-run with --fix --zabbix to generate one."
    fi

    if [[ "${DO_FIX}" -eq 1 ]]; then
        run "configure ${conf} (Server/Hostname/TLS-PSK)" bash -c "
            cp -n '${conf}' '${conf}.orig' 2>/dev/null || true
            set_conf_value() {
                local key=\"\$1\" value=\"\$2\"
                if grep -qE \"^\s*#?\s*\${key}=\" '${conf}'; then
                    sed -i -E \"s|^\s*#?\s*\${key}=.*|\${key}=\${value}|\" '${conf}'
                else
                    printf '%s=%s\n' \"\${key}\" \"\${value}\" >> '${conf}'
                fi
            }
            set_conf_value 'Server' '${ZABBIX_SERVER}'
            set_conf_value 'ServerActive' '${ZABBIX_SERVER}'
            set_conf_value 'Hostname' '$(hostname)'
            set_conf_value 'TLSConnect' 'psk'
            set_conf_value 'TLSAccept' 'psk'
            set_conf_value 'TLSPSKIdentity' '${psk_identity}'
            set_conf_value 'TLSPSKFile' '${ZABBIX_PSK_FILE}'
        " || return 1
        if [[ "${DRY_RUN}" -eq 0 ]]; then
            run "enable+restart zabbix-agent2" bash -c "systemctl enable --now zabbix-agent2 && systemctl restart zabbix-agent2" || return 1
            sleep 1
            if ! systemctl is-active --quiet zabbix-agent2; then
                log_error "zabbix-agent2 did not stay active -- check 'systemctl status zabbix-agent2'"
                return 1
            fi
            log_info "Zabbix Agent2 configured and running (PSK identity: ${psk_identity})"
        fi
    else
        log_warn "Zabbix Agent2 config not applied. Re-run with --fix --zabbix --zabbix-server ${ZABBIX_SERVER:-ADDRESS}."
    fi

    # Passive checks mean the Zabbix SERVER connects INTO this agent on
    # ZABBIX_AGENT_PORT -- if UFW's default-deny-incoming is active, that
    # inbound connection needs an explicit allow. Active checks (agent ->
    # server) aren't affected, since outbound is allowed by default.
    # `ufw status` needs root, so this only runs anything under --fix; in
    # audit mode we just note it without erroring on the permission check.
    if command -v ufw >/dev/null 2>&1; then
        if [[ "${EUID}" -eq 0 ]] && ufw status 2>/dev/null | head -n1 | grep -q "^Status: active"; then
            if ufw status | grep -qE "${ZABBIX_AGENT_PORT}/tcp.*ALLOW.*${ZABBIX_SERVER}"; then
                log_info "UFW already allows ${ZABBIX_SERVER} on tcp/${ZABBIX_AGENT_PORT}"
            elif [[ "${DO_FIX}" -eq 1 ]]; then
                run "ufw allow ${ZABBIX_SERVER} -> tcp/${ZABBIX_AGENT_PORT} (Zabbix passive checks)" \
                    ufw allow from "${ZABBIX_SERVER}" to any port "${ZABBIX_AGENT_PORT}" proto tcp \
                    comment 'Zabbix Agent2 passive checks' || return 1
            else
                log_warn "UFW is active but does not yet allow ${ZABBIX_SERVER} on tcp/${ZABBIX_AGENT_PORT}. Re-run with --fix."
            fi
        else
            log_debug "UFW not active (or not checkable without root) -- no firewall rule needed/added"
        fi
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Work
# -----------------------------------------------------------------------------
do_work() {
    log_info "Starting ${SCRIPT_NAME} v${VERSION}"
    require_cmd apt-get systemctl dpkg awk grep sed timedatectl hostname

    detect_os
    detect_hypervisor

    if [[ "${SKIP_WIZARD}" -eq 0 && "${TTY_AVAILABLE}" -eq 1 ]]; then
        run_wizard
    else
        log_info "Non-interactive (no terminal attached, or -y/--yes given): using flags/defaults."
    fi

    if [[ "${DO_FIX}" -eq 1 && "${DRY_RUN}" -eq 0 ]]; then
        require_root
    elif [[ "${DO_FIX}" -eq 1 ]]; then
        log_info "Dry-run mode: no changes will be made (root not required for preview)."
    else
        log_info "Audit mode: no changes will be made."
    fi

    local overall_rc=0

    if ! step_universe_repo;    then FAILED_CATEGORIES+=("universe repo");    overall_rc=1; fi
    if ! step_system_update;    then FAILED_CATEGORIES+=("system update");    overall_rc=1; fi
    if ! step_timezone;         then FAILED_CATEGORIES+=("timezone");         overall_rc=1; fi
    if ! step_ntp;              then FAILED_CATEGORIES+=("NTP");              overall_rc=1; fi
    if ! step_guest_tools;      then FAILED_CATEGORIES+=("guest tools");      overall_rc=1; fi
    if ! step_baseline_packages; then FAILED_CATEGORIES+=("baseline packages"); overall_rc=1; fi

    if [[ "${DO_HARDEN}" -eq 1 ]]; then
        if ! step_ssh_hardening; then FAILED_CATEGORIES+=("SSH hardening"); overall_rc=1; fi
        if ! step_ufw;           then FAILED_CATEGORIES+=("UFW");           overall_rc=1; fi
    fi
    if [[ "${DO_SWAP}" -eq 1 ]]; then
        if ! step_swap; then FAILED_CATEGORIES+=("swap"); overall_rc=1; fi
    fi
    if [[ "${DO_UNATTENDED}" -eq 1 ]]; then
        if ! step_unattended_upgrades; then FAILED_CATEGORIES+=("unattended-upgrades"); overall_rc=1; fi
    fi
    if [[ "${DO_ZABBIX}" -eq 1 ]]; then
        if ! step_zabbix_agent2; then FAILED_CATEGORIES+=("Zabbix Agent2"); overall_rc=1; fi
    fi

    log_info "------------------------------------------------------------"
    log_info "Summary: mode=$([[ "${DO_FIX}" -eq 1 ]] && echo FIX || echo AUDIT)" \
              "dry_run=${DRY_RUN} failed_categories=${#FAILED_CATEGORIES[@]}"
    if [[ ${#FAILED_CATEGORIES[@]} -gt 0 ]]; then
        log_error "Failed: $(join_by ', ' "${FAILED_CATEGORIES[@]}")"
    fi
    for n in "${NOTES[@]:-}"; do
        [[ -n "${n}" ]] && log_info "Note: ${n}"
    done
    if [[ -n "${LOG_FILE}" ]]; then
        log_info "Full log: ${LOG_FILE}"
    fi

    if [[ ${#SECRETS[@]} -gt 0 ]]; then
        print_secret ""
        print_secret "============================================================"
        print_secret "SENSITIVE -- terminal only, NOT written to any log file."
        print_secret "Copy this now; it will not be shown again by this script."
        print_secret "============================================================"
        for s in "${SECRETS[@]}"; do
            print_secret "  ${s}"
        done
        print_secret "============================================================"
    fi

    return "${overall_rc}"
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    init_logging
    log_debug "=== ${SCRIPT_NAME} start ==="
    local rc=0
    do_work || rc=$?
    exit "${rc}"
}

main "$@"
