#!/usr/bin/env bash
# SC2015: "A && t_ok || t_fail" is safe here, t_ok always succeeds.
# SC2016: single-quoted snippets are run by a child bash on purpose.
# shellcheck disable=SC2015,SC2016,SC2001
#
# tests/run.sh: offline tests for egpu-tools. Needs no eGPU, no root, no sudo.
#
#   tests/run.sh            run everything (ShellCheck is skipped if missing)
#   SHELLCHECK=/path/to/shellcheck tests/run.sh
#
# Covers: syntax, ShellCheck, --help/--version/bad options, the config parser,
# eGPU / enclosure detection against a fake sysfs tree, udev rule syntax, and
# install.sh (staged install, link mode, dry run, uninstall) under DESTDIR.
# It never touches the PCI bus, sysfs, or /etc.

set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/egpu-tools-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0 skip=0
t_ok()   { echo "  ok   $1"; pass=$((pass + 1)); }
t_fail() { echo "  FAIL $1"; [[ -n "${2:-}" ]] && sed 's/^/       /' <<<"$2"; fail=$((fail + 1)); }
t_skip() { echo "  skip $1"; skip=$((skip + 1)); }
check()  { local name=$1; shift; local out; if out=$("$@" 2>&1); then t_ok "$name"; else t_fail "$name" "$out"; fi; }
expect_rc() {  # expect_rc NAME RC CMD...
  local name=$1 want=$2; shift 2; local out rc
  out=$("$@" 2>&1); rc=$?
  if [[ $rc -eq $want ]]; then t_ok "$name"; else t_fail "$name (rc $rc, want $want)" "$out"; fi
}

SCRIPTS=(bin/egpu-on bin/egpu-off install.sh lib/egpu-tools/common.sh tests/run.sh)

echo "Syntax"
for f in "${SCRIPTS[@]}"; do check "bash -n $f" bash -n "$f"; done

echo "ShellCheck"
SC=${SHELLCHECK:-$(command -v shellcheck || true)}
if [[ -n "$SC" ]]; then
  check "shellcheck (style)" "$SC" -x -S style "${SCRIPTS[@]}"
else
  t_skip "shellcheck not installed"
fi

echo "Command line"
for s in egpu-on egpu-off; do
  expect_rc "$s --help"     0 "bin/$s" --help
  expect_rc "$s --version"  0 "bin/$s" --version
  expect_rc "$s bad option" 1 "bin/$s" --bogus
  check "$s --help lists exit codes" grep -q "Exit codes" <(bin/"$s" --help)
done
expect_rc "egpu-on --wait needs a number" 1 bin/egpu-on --wait abc
expect_rc "install.sh --help"  0 ./install.sh --help
expect_rc "install.sh bad option" 1 ./install.sh --bogus

echo "Exit codes documented consistently"
# Each code in a script's header must also appear in the runbook's exit-code table.
for s in egpu-on egpu-off; do
  codes=$(bin/"$s" --help | sed -n '/^Exit codes/,$p' | grep -oE '(^|[ ,])[0-9] ' | tr -dc '0-9\n' | sort -u | xargs)
  [[ -n "$codes" ]] || { t_fail "$s: no exit codes found in --help"; continue; }
  missing=()
  for c in $codes; do grep -qE "^\| \`$c\` \|" docs/RUNBOOK.md || missing+=("$c"); done
  if (( ${#missing[@]} )); then t_fail "$s exit codes $codes in runbook table" "missing: ${missing[*]}"
  else t_ok "$s exit codes ($codes) in runbook table"; fi
done

echo "Config parser"
cat > "$TMP/conf" <<'EOF'
# comment
EGPU_PCI_ID=10de:2684      # trailing comment
EGPU_TB_NAME="Core X V2"
EGPU_WAIT_TB = 30
EGPU_REMOVE_TIMEOUT=abc
EGPU_ALLOW_EXTRA='nvidia-persist foo'
EVIL=$(touch /tmp/should-not-exist)
EGPU_PCI_ID_BAD=zz
EOF
out=$(EGPU_CONFIG=$TMP/conf bash -c '. lib/egpu-tools/common.sh; egpu_load_config
  echo "$EGPU_PCI_ID|$EGPU_TB_NAME|$EGPU_WAIT_TB|$EGPU_REMOVE_TIMEOUT|$EGPU_ALLOW_EXTRA"' 2>&1)
want="10de:2684|Core X V2|30|90|nvidia-persist foo"
if [[ "$(tail -1 <<<"$out")" == "$want" ]]; then t_ok "values parsed, invalid number ignored"
else t_fail "values parsed" "$out"; fi
grep -q "invalid EGPU_REMOVE_TIMEOUT" <<<"$out" && t_ok "warns on invalid value" || t_fail "warns on invalid value" "$out"
grep -q "unknown setting EVIL" <<<"$out" && t_ok "warns on unknown key" || t_fail "warns on unknown key" "$out"
check "shipped etc/egpu-tools.conf parses cleanly" \
  bash -c '. lib/egpu-tools/common.sh; out=$(EGPU_CONFIG=etc/egpu-tools.conf egpu_load_config 2>&1); [[ -z "$out" ]] || { echo "$out"; exit 1; }'

echo "Detection (fake sysfs)"
F=$TMP/sys
mkpci() {  # mkpci ADDR CLASS VENDOR DEVICE [removable]
  local d=$F/pci/$1; mkdir -p "$d/power"
  echo "$2" > "$d/class"; echo "$3" > "$d/vendor"; echo "$4" > "$d/device"
  echo active > "$d/power/runtime_status"
  [[ -n "${5:-}" ]] && echo removable > "$d/removable"
  return 0
}
mktb() {   # mktb NAME VENDOR DEVICE
  local d=$F/tb/$1; mkdir -p "$d"; echo "$2" > "$d/vendor_name"; echo "$3" > "$d/device_name"
}
mkpci 0000:64:00.0 0x030000 0x1002 0x1900               # iGPU (not removable)
mkpci 0000:08:00.0 0x030000 0x1002 0x744c removable     # eGPU
mkpci 0000:08:00.1 0x040300 0x1002 0xab30 removable     # eGPU HDMI audio
mkpci 0000:07:00.0 0x060400 0x8086 0x5786 removable     # Thunderbolt bridge
mkdir -p "$F/tb/0-0" "$F/tb/0-0:2.1" "$F/tb/domain0"; echo "" > "$F/tb/0-0/device_name"
mktb 0-1 "CalDigit" "TS4"
mktb 0-2 "Razer" "Core X V2"
det() { bash -c ". lib/egpu-tools/common.sh; SYS_PCI=$F/pci SYS_TB=$F/tb; $1"; }
[[ "$(det egpu_gpu_addr)" == 0000:08:00.0 ]] && t_ok "finds the removable display device" \
  || t_fail "finds the removable display device" "$(det egpu_gpu_addr)"
[[ "$(det 'egpu_pci_id 0000:08:00.0')" == 1002:744c ]] && t_ok "egpu_pci_id" || t_fail "egpu_pci_id"
[[ "$(det egpu_tb_dev)" == "$F/tb/0-1" ]] && t_ok "first Thunderbolt device, skipping host router and ports" \
  || t_fail "first Thunderbolt device" "$(det egpu_tb_dev)"
[[ "$(det 'EGPU_TB_NAME="Core X V2"; egpu_tb_dev')" == "$F/tb/0-2" ]] && t_ok "EGPU_TB_NAME selects the enclosure" \
  || t_fail "EGPU_TB_NAME selects the enclosure"
[[ -z "$(det 'EGPU_TB_NAME=nope; egpu_tb_dev')" ]] && t_ok "unknown EGPU_TB_NAME finds nothing" || t_fail "unknown EGPU_TB_NAME"
[[ "$(det egpu_tb_list | wc -l)" -eq 2 ]] && t_ok "egpu_tb_list" || t_fail "egpu_tb_list" "$(det egpu_tb_list)"
rm "$F/pci/0000:08:00.0/removable"
[[ -z "$(det egpu_gpu_addr)" ]] && t_ok "no removable GPU -> nothing detected" || t_fail "no removable GPU" "$(det egpu_gpu_addr)"
[[ "$(det 'egpu_rpm 0000:08:00.0')" == active ]] && t_ok "egpu_rpm" || t_fail "egpu_rpm"
[[ "$(det 'egpu_rpm 0000:99:00.0')" == '?' ]] && t_ok "egpu_rpm on missing device" || t_fail "egpu_rpm on missing device"
[[ "$(det 'egpu_offload_hint nvidia 10de:2684')" == __NV_PRIME* ]] && t_ok "NVIDIA offload hint" || t_fail "NVIDIA offload hint"

echo "udev rules"
for r in udev/*.rules; do
  grep -q "Installed by egpu-tools" "$r" && t_ok "$r has the install marker" || t_fail "$r has the install marker"
done
if command -v udevadm >/dev/null && udevadm verify --help >/dev/null 2>&1; then
  check "udevadm verify" udevadm verify --no-style udev/*.rules
else
  t_skip "udevadm verify not available"
fi

echo "install.sh (DESTDIR)"
D=$TMP/stage
expect_rc "dry run" 0 env DESTDIR="$D" ./install.sh --dry-run
[[ ! -e "$D/usr" ]] && t_ok "dry run changes nothing" || t_fail "dry run changes nothing"
expect_rc "staged install" 0 env DESTDIR="$D" ./install.sh
for f in usr/local/bin/egpu-on usr/local/bin/egpu-off usr/local/lib/egpu-tools/common.sh \
         usr/local/share/doc/egpu-tools/README.md usr/local/share/doc/egpu-tools/RUNBOOK.md \
         etc/udev/rules.d/80-egpu-no-runpm.rules etc/udev/rules.d/81-egpu-mutter-ignore.rules etc/egpu-tools.conf; do
  [[ -e "$D/$f" ]] && t_ok "installed $f" || t_fail "installed $f"
done
expect_rc "installed egpu-on finds its library" 0 "$D/usr/local/bin/egpu-on" --version
echo "EGPU_WAIT_TB=7" > "$D/etc/egpu-tools.conf"
expect_rc "re-install" 0 env DESTDIR="$D" ./install.sh
grep -q "EGPU_WAIT_TB=7" "$D/etc/egpu-tools.conf" && t_ok "re-install keeps the config" || t_fail "re-install keeps the config"
echo "# my own rule" > "$D/etc/udev/rules.d/81-egpu-mutter-ignore.rules"
env DESTDIR="$D" ./install.sh >/dev/null 2>&1
compgen -G "$D/etc/udev/rules.d/81-egpu-mutter-ignore.rules.bak-*" >/dev/null \
  && t_ok "a foreign rule is backed up before being replaced" || t_fail "foreign rule backup"
expect_rc "install --no-mutter-ignore" 0 env DESTDIR="$TMP/stage2" ./install.sh --no-mutter-ignore
[[ ! -e "$TMP/stage2/etc/udev/rules.d/81-egpu-mutter-ignore.rules" ]] && t_ok "--no-mutter-ignore skips rule 81" \
  || t_fail "--no-mutter-ignore skips rule 81"
expect_rc "uninstall" 0 env DESTDIR="$D" ./install.sh --uninstall
left=$(cd "$D" && find . -type f | grep -v '\.bak-' | sort | xargs)
[[ "$left" == "./etc/egpu-tools.conf" ]] && t_ok "uninstall removes everything but the config" \
  || t_fail "uninstall leftovers" "$left"
expect_rc "uninstall --purge" 0 env DESTDIR="$D" ./install.sh --uninstall --purge
[[ ! -e "$D/etc/egpu-tools.conf" ]] && t_ok "--purge removes the config" || t_fail "--purge removes the config"
echo "# not ours" > "$D/etc/udev/rules.d/80-egpu-no-runpm.rules"
env DESTDIR="$D" ./install.sh --uninstall >/dev/null 2>&1
[[ -e "$D/etc/udev/rules.d/80-egpu-no-runpm.rules" ]] && t_ok "uninstall leaves rules without the marker" \
  || t_fail "uninstall leaves foreign rules"
expect_rc "link install" 0 env DESTDIR="$TMP/stage3" ./install.sh --link --prefix /opt/egpu
[[ "$(readlink "$TMP/stage3/opt/egpu/bin/egpu-on")" == "$ROOT/bin/egpu-on" ]] && t_ok "--link symlinks to the checkout" \
  || t_fail "--link symlinks to the checkout"
expect_rc "linked egpu-off runs" 0 "$TMP/stage3/opt/egpu/bin/egpu-off" --version

echo "install.sh one-liner (curl | bash, local tarball)"
# Same layout as a GitHub archive: everything under one top-level directory.
mkdir -p "$TMP/src/egpu-tools-main"
tar -C "$ROOT" --exclude=.git -cf - . | tar -C "$TMP/src/egpu-tools-main" -xf -
tar -C "$TMP/src" -czf "$TMP/main.tar.gz" egpu-tools-main
if command -v curl >/dev/null; then
  mkdir -p "$TMP/dl"
  out=$(cd "$TMP" && env DESTDIR="$TMP/stage4" EGPU_TARBALL_URL="file://$TMP/main.tar.gz" TMPDIR="$TMP/dl" \
        bash < "$ROOT/install.sh" 2>&1); rc=$?
  if [[ $rc -eq 0 && -x "$TMP/stage4/usr/local/bin/egpu-on" ]]; then t_ok "piped install from a tarball"
  else t_fail "piped install from a tarball (rc $rc)" "$out"; fi
  [[ -z "$(ls -A "$TMP/dl" 2>/dev/null)" ]] && t_ok "downloaded copy is cleaned up" \
    || t_fail "downloaded copy is cleaned up" "$(ls -A "$TMP/dl")"
  expect_rc "piped --link is refused" 1 env DESTDIR="$TMP/stage6" bash -c "bash -s -- --link < '$ROOT/install.sh'"
  expect_rc "bad download URL fails with 2" 2 \
    env DESTDIR="$TMP/stage5" EGPU_TARBALL_URL="file://$TMP/missing.tar.gz" bash -c "bash < '$ROOT/install.sh'"
else
  t_skip "curl not installed"
fi

echo
echo "passed $pass, failed $fail, skipped $skip"
(( fail == 0 ))
