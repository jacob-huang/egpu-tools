# CLAUDE.md

Bash tooling to hot-plug a Thunderbolt/USB4 eGPU on Linux: `bin/egpu-on`, `bin/egpu-off`, two udev rules, and an installer. The user-facing docs are `README.md` (install, usage) and `docs/RUNBOOK.md` (operations for the reference setup: Razer Core X V2 + RX 7900 XTX, Ubuntu, GNOME).

## Safety rules (hardware and root)

- **Never run a real attach or detach** (`egpu-on`, `egpu-off` without `--dry-run`, PCI `remove`/`rescan`, `boltctl authorize`) **without the user's explicit approval in this conversation.** A hot-remove while GNOME holds the card can crash the user's session minutes later (runbook "Known risk"). Re-attaching while logged in carries a similar risk.
- `egpu-off --dry-run` and `egpu-on` on an already-healthy eGPU only read state, but they still re-run themselves with sudo. Say what you're about to run before you run it.
- **Never write to `/etc`, `/sys` or `/usr/local` as a side effect of something else.** Install udev rules or run `install.sh` for real only when asked. To test the installer, stage it with `DESTDIR=<tmpdir> ./install.sh` (no sudo).
- **Don't nest heredocs in edit commands.** A payload line equal to the outer delimiter (for example `EOF` inside a documented `sudo tee … <<'EOF'` snippet) ends the heredoc early and runs the rest as shell. This once rewrote `/etc/udev/rules.d/80-egpu-no-runpm.rules` by accident. Write edit scripts to a file with the Write tool, or use the Edit tool.
- Keep personal data (hostnames, usernames, home paths, serial numbers) out of the repo. It's meant to be published.

## Layout

| Path | Role |
|---|---|
| `bin/egpu-on`, `bin/egpu-off` | The two commands. Each sources `../lib/egpu-tools/common.sh` relative to its real path (`readlink -f`), so symlinked and installed copies both work |
| `lib/egpu-tools/common.sh` | Read-only helpers: output, sudo re-exec, config parsing, eGPU and enclosure detection, GNOME session checks, Vulkan lookup |
| `udev/*.rules` | Generic rules matching any *removable* display-class PCI device. Each must keep the `Installed by egpu-tools` marker, which uninstall relies on |
| `etc/egpu-tools.conf` | Default config, installed to `/etc/egpu-tools.conf` only if that file doesn't exist |
| `install.sh` | Installer and uninstaller. When piped (`curl … \| bash`), it downloads the GitHub tarball and re-runs the copy inside it |
| `tests/run.sh` | Offline test suite. Detection is tested against a fake sysfs tree via `SYS_PCI` / `SYS_TB` |

## Conventions

- Bash 4+, `set -euo pipefail` in the commands, ShellCheck-clean at `-S style` (`.shellcheckrc` sets `source-path=SCRIPTDIR`).
- **`--help` is the comment block at the top of each script** (line 2 to the first blank line). Edit the header to change the help text.
- The config file is parsed with a whitelist of keys (`egpu_load_config`), never `source`d. Add new keys to both `common.sh` and `etc/egpu-tools.conf`.
- Messages use `info` / `ok` / `warn` / `err` from `common.sh`. Errors that need action name the runbook section (for example "runbook T5").
- **Exit codes are an interface.** When you change one, update the script header, the runbook §2 exit-code table, and the §3/§4 shortcut boxes. `tests/run.sh` checks that every code in `--help` appears in the runbook table.
- The same goes for options and the desktop-app tips: they're described in the script header, README, runbook §2 (options table plus the behavior descriptions), and the §3/§4 shortcut boxes. Keep them in sync.
- Add a dated row to the runbook change log (§9) for user-visible changes, and keep it short; merge entries from the same change.

## Testing

```bash
tests/run.sh                                     # must pass before you finish
SHELLCHECK=/path/to/shellcheck tests/run.sh      # if shellcheck isn't on PATH
udevadm test -D <dir-with-rule-copies> --action=add /sys/class/drm/cardN   # check rule matching, no root
```

Hardware behavior (real attach, detach, hang recovery) can only be checked on a machine with the eGPU, and only with the user's approval (see Safety rules).
