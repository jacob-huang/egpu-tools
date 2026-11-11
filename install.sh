#!/usr/bin/env bash
# install.sh: install egpu-tools (egpu-on, egpu-off, udev rules, config, docs).
#
# One-liner (downloads the repository tarball, then installs from it):
#   curl -fsSL https://raw.githubusercontent.com/jacob-huang/egpu-tools/main/install.sh | bash
# With options:
#   curl -fsSL .../install.sh | bash -s -- --no-mutter-ignore
# From a checkout:
#   ./install.sh [options]
#
# Installs (default PREFIX=/usr/local):
#   PREFIX/bin/egpu-on, PREFIX/bin/egpu-off
#   PREFIX/lib/egpu-tools/common.sh
#   PREFIX/share/doc/egpu-tools/{README.md,RUNBOOK.md}
#   /etc/udev/rules.d/80-egpu-no-runpm.rules      (runtime PM off for eGPUs)
#   /etc/udev/rules.d/81-egpu-mutter-ignore.rules (GNOME ignores the eGPU card)
#   /etc/egpu-tools.conf                          (only if it doesn't exist)
# Uses sudo for the steps that need root; asks for your password once per step.
#
# Usage: install.sh [options]
#   --prefix DIR        install scripts under DIR (default /usr/local)
#   --user              same as --prefix ~/.local (udev rules still need sudo)
#   --link              symlink the scripts to this checkout instead of copying
#                       (for development; needs a git checkout, not the one-liner)
#   --no-udev           don't install any udev rules
#   --no-runpm-rule     don't install 80-egpu-no-runpm.rules
#   --no-mutter-ignore  don't install 81-egpu-mutter-ignore.rules (keep this if
#                       you drive monitors from the eGPU's own outputs in GNOME)
#   --install-deps      install missing packages with apt/dnf/pacman/zypper
#   --ref REF           branch or tag to download (one-liner only; default main)
#   --uninstall         remove everything this script installs (keeps
#                       /etc/egpu-tools.conf unless --purge)
#   --purge             with --uninstall, also remove /etc/egpu-tools.conf
#   -n, --dry-run       print what would be done, change nothing
#   -h, --help          show this help and exit
# Environment: EGPU_REPO (owner/name on GitHub), EGPU_TARBALL_URL (download
# this archive instead), DESTDIR (stage into a
# directory for packaging; implies no sudo and no udev reload).
#
# Exit codes: 0 done, 1 usage error, 2 unsupported system / download failed,
#             3 a step failed

set -euo pipefail

REPO=${EGPU_REPO:-jacob-huang/egpu-tools}
REF=main
PREFIX=/usr/local
DESTDIR=${DESTDIR:-}
LINK=0 UDEV=1 RUNPM=1 MUTTER=1 DEPS=0 UNINSTALL=0 PURGE=0 DRY=0

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "${SRC:-.}/install.sh" 2>/dev/null \
            || echo "See https://github.com/$REPO#install"; }

c_red=$'\e[31m' c_grn=$'\e[32m' c_yel=$'\e[33m' c_bld=$'\e[1m' c_off=$'\e[0m'
[[ -t 1 ]] || c_red='' c_grn='' c_yel='' c_bld='' c_off=''
info() { echo "${c_bld}==>${c_off} $*"; }
ok()   { echo "${c_grn}OK${c_off}  $*"; }
warn() { echo "${c_yel}WARN${c_off} $*"; }
die()  { echo "${c_red}ERR${c_off}  $*" >&2; exit "${2:-3}"; }

# Where is the source? A checkout if this file sits next to bin/egpu-on; empty
# when piped into bash (curl | bash).
SRC=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  d=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  [[ -f "$d/bin/egpu-on" && -f "$d/lib/egpu-tools/common.sh" ]] && SRC=$d
fi

ARGS=("$@")
while (( $# )); do
  case "$1" in
    --prefix)  [[ -n "${2:-}" ]] || die "--prefix needs a directory" 1; PREFIX=$2; shift ;;
    --user)    PREFIX=$HOME/.local ;;
    --link)    LINK=1 ;;
    --no-udev) UDEV=0 ;;
    --no-runpm-rule)    RUNPM=0 ;;
    --no-mutter-ignore) MUTTER=0 ;;
    --install-deps) DEPS=1 ;;
    --ref)     [[ -n "${2:-}" ]] || die "--ref needs a branch or tag" 1; REF=$2; shift ;;
    --uninstall) UNINSTALL=1 ;;
    --purge)   PURGE=1 ;;
    -n|--dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done
PREFIX=${PREFIX%/}

[[ "$(uname -s)" == Linux ]] || die "egpu-tools only supports Linux." 2
(( BASH_VERSINFO[0] >= 4 )) || die "bash 4 or newer is required." 2

# --- Privilege helpers ------------------------------------------------------------
# Run a command as root when the target isn't writable by us.
SUDO=()
if [[ $EUID -ne 0 && -z "$DESTDIR" ]]; then
  SUDO=(sudo)
  [[ -n "${SUDO_ASKPASS:-}" && -x "${SUDO_ASKPASS}" ]] && SUDO=(sudo -A)
fi
needs_root() {   # $1 = target path; true if we can't write its nearest existing parent
  local p=$1
  [[ -n "$DESTDIR" || $EUID -eq 0 ]] && return 1
  while [[ ! -e "$p" ]]; do p=$(dirname "$p"); done
  [[ ! -w "$p" ]]
}
run() {          # run [--root] CMD...: print, then execute (unless dry run)
  local root=0; [[ "$1" == --root ]] && { root=1; shift; }
  if (( root )) && (( ${#SUDO[@]} )); then set -- "${SUDO[@]}" "$@"; fi
  echo "     \$ $*"
  (( DRY )) || "$@"
}
as_needed() {    # as_needed TARGET CMD...: run CMD as root only if TARGET needs it
  local t=$1; shift
  if needs_root "$t"; then run --root "$@"; else run "$@"; fi
}

BIN=$DESTDIR$PREFIX/bin
LIBDIR=$DESTDIR$PREFIX/lib/egpu-tools
DOCDIR=$DESTDIR$PREFIX/share/doc/egpu-tools
RULESDIR=$DESTDIR/etc/udev/rules.d
CONF=$DESTDIR/etc/egpu-tools.conf
RULES=(80-egpu-no-runpm.rules 81-egpu-mutter-ignore.rules)
MARKER="Installed by egpu-tools"

reload_udev() {
  [[ -z "$DESTDIR" ]] && command -v udevadm >/dev/null || return 0
  run --root udevadm control --reload
}

# --- Uninstall --------------------------------------------------------------------
if (( UNINSTALL )); then
  info "Uninstalling egpu-tools from $DESTDIR$PREFIX"
  for f in "$BIN/egpu-on" "$BIN/egpu-off"; do
    [[ -e "$f" || -L "$f" ]] && as_needed "$f" rm -f "$f"
  done
  [[ -d "$LIBDIR" ]] && as_needed "$LIBDIR" rm -rf "$LIBDIR"
  [[ -d "$DOCDIR" ]] && as_needed "$DOCDIR" rm -rf "$DOCDIR"
  removed_rule=0
  for r in "${RULES[@]}"; do
    f=$RULESDIR/$r
    [[ -f "$f" ]] || continue
    if grep -q "$MARKER" "$f"; then
      as_needed "$f" rm -f "$f"; removed_rule=1
    else
      warn "Leaving $f: not installed by egpu-tools (no '$MARKER' line). Remove it by hand if you want."
    fi
  done
  (( removed_rule )) && reload_udev
  if (( PURGE )) && [[ -f "$CONF" ]]; then as_needed "$CONF" rm -f "$CONF"
  elif [[ -f "$CONF" ]]; then info "Kept $CONF (use --purge to remove it)."; fi
  ok "Uninstalled. Rules already applied to a connected eGPU stay in effect until it is reconnected."
  exit 0
fi

# --- Fetch the source when run as a one-liner -----------------------------------
if [[ -z "$SRC" ]]; then
  (( LINK )) && die "--link needs a git checkout; clone the repository and run ./install.sh --link" 1
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/egpu-tools.XXXXXX")
  trap 'rm -rf "$TMP"' EXIT     # covers download failures; the re-run cleans up otherwise
  url=${EGPU_TARBALL_URL:-https://github.com/$REPO/archive/$REF.tar.gz}
  info "Downloading $url"
  if command -v curl >/dev/null; then
    curl -fsSL "$url" | tar -xz -C "$TMP" --strip-components=1 || die "Download failed: $url" 2
  elif command -v wget >/dev/null; then
    wget -qO- "$url" | tar -xz -C "$TMP" --strip-components=1 || die "Download failed: $url" 2
  else
    die "Need curl or wget to download $url" 2
  fi
  [[ -f "$TMP/install.sh" ]] || die "Downloaded archive has no install.sh" 2
  # Re-run the downloaded installer so it installs files matching its own version.
  trap - EXIT
  EGPU_TOOLS_CLEANUP=$TMP exec bash "$TMP/install.sh" "${ARGS[@]}"
fi
# Started by the one-liner above: remove the downloaded copy when done.
if [[ -n "${EGPU_TOOLS_CLEANUP:-}" && "$SRC" == "$EGPU_TOOLS_CLEANUP" ]]; then
  trap 'rm -rf "$EGPU_TOOLS_CLEANUP"' EXIT
fi

# --- Dependencies -----------------------------------------------------------------
# command -> package (Debian/Ubuntu, Fedora, Arch, openSUSE names agree for these)
declare -A PKG=([lspci]=pciutils [fuser]=psmisc [boltctl]=bolt [vulkaninfo]=vulkan-tools
                [udevadm]=systemd [loginctl]=systemd [journalctl]=systemd)
REQUIRED=(lspci fuser udevadm loginctl journalctl)
OPTIONAL=(boltctl vulkaninfo)
missing_req=() missing_opt=()
for c in "${REQUIRED[@]}"; do command -v "$c" >/dev/null || missing_req+=("$c"); done
for c in "${OPTIONAL[@]}"; do command -v "$c" >/dev/null || missing_opt+=("$c"); done

pkg_cmd() {
  if   command -v apt-get >/dev/null; then echo "apt-get install -y"
  elif command -v dnf     >/dev/null; then echo "dnf install -y"
  elif command -v pacman  >/dev/null; then echo "pacman -S --needed --noconfirm"
  elif command -v zypper  >/dev/null; then echo "zypper install -y"
  fi
}
if (( ${#missing_req[@]} + ${#missing_opt[@]} )); then
  pkgs=$(for c in "${missing_req[@]}" "${missing_opt[@]}"; do echo "${PKG[$c]}"; done | sort -u | xargs)
  pm=$(pkg_cmd)
  if (( DEPS )) && [[ -n "$pm" ]]; then
    info "Installing missing packages: $pkgs"
    # shellcheck disable=SC2086  # $pm and $pkgs are intentionally split into words
    run --root $pm $pkgs || die "Package installation failed."
  else
    (( ${#missing_req[@]} )) && warn "Missing required commands: ${missing_req[*]}"
    (( ${#missing_opt[@]} )) && warn "Missing optional commands: ${missing_opt[*]} (enclosure authorization / Vulkan check)"
    warn "Install them with: sudo ${pm:-<your package manager> install} $pkgs   (or re-run with --install-deps)"
  fi
fi
[[ -d /sys/bus/thunderbolt ]] || warn "No /sys/bus/thunderbolt: this machine may lack Thunderbolt/USB4 support."

# --- Install ----------------------------------------------------------------------
mode=copy; (( LINK )) && mode="symlink to $SRC"
info "Installing egpu-tools to $DESTDIR$PREFIX ($mode)"
as_needed "$BIN"    install -d -m 755 "$BIN"
as_needed "$LIBDIR" install -d -m 755 "$LIBDIR"
as_needed "$DOCDIR" install -d -m 755 "$DOCDIR"
if (( LINK )); then
  for s in egpu-on egpu-off; do as_needed "$BIN/$s" ln -sfn "$SRC/bin/$s" "$BIN/$s"; done
  as_needed "$LIBDIR" ln -sfn "$SRC/lib/egpu-tools/common.sh" "$LIBDIR/common.sh"
else
  for s in egpu-on egpu-off; do as_needed "$BIN/$s" install -m 755 "$SRC/bin/$s" "$BIN/$s"; done
  as_needed "$LIBDIR" install -m 644 "$SRC/lib/egpu-tools/common.sh" "$LIBDIR/common.sh"
fi
as_needed "$DOCDIR" install -m 644 "$SRC/README.md" "$SRC/docs/RUNBOOK.md" "$DOCDIR/"

if [[ -e "$CONF" ]]; then
  info "Keeping existing $CONF"
else
  as_needed "$CONF" install -D -m 644 "$SRC/etc/egpu-tools.conf" "$CONF"
fi

if (( UDEV )); then
  want=()
  (( RUNPM ))  && want+=(80-egpu-no-runpm.rules)
  (( MUTTER )) && want+=(81-egpu-mutter-ignore.rules)
  changed=0
  for r in "${want[@]}"; do
    f=$RULESDIR/$r
    if [[ -f "$f" ]] && cmp -s "$SRC/udev/$r" "$f"; then
      info "$f is up to date"; continue
    fi
    if [[ -f "$f" ]] && ! grep -q "$MARKER" "$f"; then
      bak="$f.bak-$(date +%Y%m%d%H%M%S)"     # udev only reads *.rules, so this is inert
      warn "Replacing your own $f; saving it as $bak"
      as_needed "$f" cp -p "$f" "$bak"
    fi
    as_needed "$f" install -D -m 644 "$SRC/udev/$r" "$f"
    changed=1
  done
  (( changed )) && reload_udev
fi

# Warn about other egpu-on/egpu-off copies earlier in PATH (e.g. old symlinks).
if [[ -z "$DESTDIR" ]]; then
  for s in egpu-on egpu-off; do
    found=$(command -v "$s" 2>/dev/null || true)
    if [[ -n "$found" && "$(readlink -f "$found")" != "$(readlink -f "$BIN/$s")" ]]; then
      warn "'$s' on your PATH is $found, not $BIN/$s. Remove it, or put $BIN first in PATH."
    fi
  done
  case ":$PATH:" in *":$PREFIX/bin:"*) ;; *) warn "$PREFIX/bin is not in your PATH." ;; esac
fi

# --- Summary ----------------------------------------------------------------------
echo
(( DRY )) && { ok "Dry run finished; nothing was changed."; exit 0; }
ok "${c_bld}egpu-tools installed.${c_off}"
echo "     Commands : egpu-on, egpu-off   (try: egpu-off --dry-run)"
echo "     Config   : $CONF"
echo "     Runbook  : $DOCDIR/RUNBOOK.md"
if (( UDEV )) && (( ${#want[@]} )); then
  echo "     udev     : $RULESDIR/{$(IFS=,; echo "${want[*]}")}"
  echo "     The rules take effect the next time the eGPU is connected. For GNOME, connect"
  echo "     it once while logged out (text console, Ctrl+Alt+F3) so GNOME never opens it."
fi
