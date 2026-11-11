# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
# common.sh: shared helpers for egpu-on / egpu-off. Source it, don't run it.
#
# Everything here is read-only: detection, session checks, output helpers.
# Changes to the system (PCI remove/rescan, sysfs writes) live in the scripts.

EGPU_TOOLS_VERSION="1.0.0"

# --- Output -------------------------------------------------------------------
c_red=$'\e[31m' c_grn=$'\e[32m' c_yel=$'\e[33m' c_bld=$'\e[1m' c_off=$'\e[0m'
[[ -t 1 ]] || c_red='' c_grn='' c_yel='' c_bld='' c_off=''
info() { echo "${c_bld}==>${c_off} $*"; }
ok()   { echo "${c_grn}OK${c_off}  $*"; }
warn() { echo "${c_yel}WARN${c_off} $*"; }
err()  { echo "${c_red}ERR${c_off}  $*" >&2; }

# Print the comment block at the top of script $1 (line 2 up to the first blank line).
egpu_usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$1"; }

# --- Root -------------------------------------------------------------------------
# Re-run script $1 (with the remaining args) as root via sudo, once.
# Uses the GUI askpass helper when SUDO_ASKPASS is set, otherwise sudo's normal
# terminal prompt.
egpu_need_root() {
  local self=$1; shift
  [[ $EUID -eq 0 ]] && return 0
  local -a sudo_cmd=(sudo)
  [[ -n "${SUDO_ASKPASS:-}" && -x "${SUDO_ASKPASS}" ]] && sudo_cmd=(sudo -A)
  # Pass the config path through: sudo resets the environment.
  exec "${sudo_cmd[@]}" -- env EGPU_CONFIG="${EGPU_CONFIG:-/etc/egpu-tools.conf}" "$self" "$@"
}

# --- Configuration -------------------------------------------------------------
# Defaults; /etc/egpu-tools.conf (or $EGPU_CONFIG) can override them.
EGPU_PCI_ID=""            # vendor:device of the eGPU (e.g. 1002:744c); empty = auto-detect
EGPU_TB_NAME=""           # Thunderbolt device_name of the enclosure (e.g. "Core X V2"); empty = auto
EGPU_WAIT_TB=120          # egpu-on: seconds to wait for the enclosure to appear
EGPU_WAIT_GPU=45          # egpu-on: seconds to wait for the driver to bind after a rescan
EGPU_REMOVE_TIMEOUT=90    # egpu-off: seconds to wait for each PCI function to be removed
EGPU_ALLOW_EXTRA=""       # egpu-off: extra process names (comm) allowed to hold the eGPU

# Parse KEY=VALUE lines instead of sourcing the file, so a config file can't run code.
egpu_load_config() {
  local file=${EGPU_CONFIG:-/etc/egpu-tools.conf} line key val
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%#*}                                   # strip comments
    [[ "$line" =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
    val=${val%"${val##*[![:space:]]}"}                 # trim trailing spaces
    [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]] && val=${BASH_REMATCH[1]}
    case "$key" in
      EGPU_PCI_ID)  [[ -z "$val" || "$val" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]] \
                      || { warn "$file: ignoring invalid EGPU_PCI_ID '$val'"; continue; } ;;
      EGPU_WAIT_TB|EGPU_WAIT_GPU|EGPU_REMOVE_TIMEOUT)
                    [[ "$val" =~ ^[0-9]+$ ]] || { warn "$file: ignoring invalid $key '$val'"; continue; } ;;
      EGPU_TB_NAME|EGPU_ALLOW_EXTRA) ;;
      *) warn "$file: unknown setting $key"; continue ;;
    esac
    printf -v "$key" '%s' "$val"
  done < "$file"
}

# --- Detection -----------------------------------------------------------------
SYS_PCI=/sys/bus/pci/devices
SYS_TB=/sys/bus/thunderbolt/devices

# PCI address of the eGPU (first match), or empty. With EGPU_PCI_ID set, match
# that ID; otherwise take the first display-class device (class 0x03xxxx) that
# the kernel marks "removable", i.e. it sits behind a Thunderbolt/USB4 port.
egpu_gpu_addr() {
  local d
  if [[ -n "$EGPU_PCI_ID" ]]; then
    lspci -D -d "$EGPU_PCI_ID" 2>/dev/null | awk 'NR==1{print $1}'
    return 0
  fi
  for d in "$SYS_PCI"/*; do
    [[ "$(cat "$d/class" 2>/dev/null)" == 0x03* ]] || continue
    [[ "$(cat "$d/removable" 2>/dev/null)" == removable ]] || continue
    basename "$d"; return 0
  done
}

egpu_pci_id()  { local d=$SYS_PCI/$1; echo "$(sed 's/^0x//' "$d/vendor"):$(sed 's/^0x//' "$d/device")"; }
egpu_driver()  { local l; l=$(readlink -f "$SYS_PCI/$1/driver" 2>/dev/null) && basename "$l"; return 0; }
egpu_rpm()     { cat "$SYS_PCI/$1/power/runtime_status" 2>/dev/null || echo '?'; }
egpu_name()    { lspci -s "$1" 2>/dev/null | cut -d: -f3- | sed 's/^ //'; }

# Healthy = a driver is bound, runtime PM is not in error, and the DRM render node exists.
egpu_healthy() {
  [[ -n "$(egpu_driver "$1")" ]] || return 1
  [[ "$(egpu_rpm "$1")" != error ]] || return 1
  [[ -e /dev/dri/by-path/pci-$1-render ]] || return 1
}

# Thunderbolt/USB4 device directory of the enclosure, or empty. Skips the host
# routers (N-0) and ports/retimers (names containing ':'). With EGPU_TB_NAME set,
# match its device_name.
egpu_tb_dev() {
  local d n
  for d in "$SYS_TB"/*; do
    n=$(basename "$d")
    [[ "$n" =~ ^[0-9]+-[0-9]+$ && "$n" != *-0 ]] || continue
    [[ -f "$d/device_name" ]] || continue
    if [[ -n "$EGPU_TB_NAME" ]]; then
      [[ "$(cat "$d/device_name")" == "$EGPU_TB_NAME" ]] || continue
    fi
    echo "$d"; return 0
  done
}

# All Thunderbolt/USB4 devices as "name (vendor device)" lines, for messages.
egpu_tb_list() {
  local d n
  for d in "$SYS_TB"/*; do
    n=$(basename "$d")
    [[ "$n" =~ ^[0-9]+-[0-9]+$ && "$n" != *-0 ]] || continue
    echo "$n ($(cat "$d/vendor_name" 2>/dev/null) $(cat "$d/device_name" 2>/dev/null))"
  done
}

# --- GNOME / graphical sessions ---------------------------------------------------
# GNOME Shell (mutter) opens every DRM card that appears unless it carries the
# udev tag mutter-device-ignore. After a hot-remove of a card it manages, mutter
# keeps stale KMS state and can abort at the next monitor change (mutter#4705).

# Fill GUI_ACTIVE / GUI_BACKGROUND with graphical (Wayland/X11) user sessions:
# active on a seat vs. running in the background.
egpu_gui_sessions() {
  GUI_ACTIVE=() GUI_BACKGROUND=()
  local sid props stype sstate sclass sseat sname desc
  while read -r sid; do
    [[ -n "$sid" ]] || continue
    props=$(loginctl show-session "$sid" -p Name -p Type -p State -p Class -p Seat 2>/dev/null) || continue
    stype=$(sed -n 's/^Type=//p' <<<"$props");  sstate=$(sed -n 's/^State=//p' <<<"$props")
    sclass=$(sed -n 's/^Class=//p' <<<"$props"); sseat=$(sed -n 's/^Seat=//p' <<<"$props")
    sname=$(sed -n 's/^Name=//p' <<<"$props")
    [[ "$sclass" == user && ( "$stype" == wayland || "$stype" == x11 ) ]] || continue
    desc="session $sid ($sname, $stype${sseat:+, $sseat})"
    if [[ "$sstate" == active && -n "$sseat" ]]; then GUI_ACTIVE+=("$desc")
    else GUI_BACKGROUND+=("$desc, state $sstate"); fi
  done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
}

egpu_card_node() { readlink -f "/dev/dri/by-path/pci-$1-card" 2>/dev/null || true; }

# True if DRM card node $1 carries the mutter-device-ignore udev tag.
egpu_has_ignore_tag() {
  [[ -n "$1" ]] && udevadm info -q property -n "$1" 2>/dev/null \
    | grep -E '^(CURRENT_TAGS|TAGS)=' | grep -q ':mutter-device-ignore:'
}

# gnome-shell PIDs holding card node $1, space-separated.
egpu_mutter_pids() {
  local pid out=()
  [[ -n "$1" ]] || return 0
  for pid in $(fuser "$1" 2>/dev/null); do
    [[ "$(cat /proc/"$pid"/comm 2>/dev/null)" == gnome-shell ]] && out+=("$pid")
  done
  echo "${out[*]}"
}

# --- Vulkan -----------------------------------------------------------------------
# deviceName of the Vulkan device matching PCI address $1, run as user $2.
# Prints nothing if Vulkan can't see it; returns 2 if vulkaninfo isn't installed.
egpu_vulkan_name() {
  local addr=$1 user=${2:-root} vid did
  command -v vulkaninfo >/dev/null || return 2
  vid=$(cat "$SYS_PCI/$addr/vendor") did=$(cat "$SYS_PCI/$addr/device")
  local -a as_user=()
  [[ $EUID -eq 0 && "$user" != root ]] && as_user=(runuser -u "$user" --)
  # No display variables: --summary otherwise tries to open a window surface.
  "${as_user[@]}" env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY \
      vulkaninfo --summary 2>/dev/null \
    | awk -v vid="$vid" -v did="$did" '
        /^GPU[0-9]+:/            { v = ""; d = "" }
        $1 == "vendorID"         { v = $3 }
        $1 == "deviceID"         { d = $3 }
        $1 == "deviceName" && v == vid && d == did { sub(/^[^=]*= */, ""); print; exit }'
}

# "how to run an app on it" hint for driver $1, PCI ID $2.
egpu_offload_hint() {
  case "$1" in
    nvidia) echo "__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <app>" ;;
    *)      echo "DRI_PRIME=1 <app>   |   MESA_VK_DEVICE_SELECT=$2! <app>" ;;
  esac
}
