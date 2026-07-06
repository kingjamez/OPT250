# OPT250 — one-click AMD BC-250 tuning

Turns a stock AMD BC-250 board into a properly tuned machine in one command:

1. **Permanently unlocks every safe compute unit** — clean dies go from 24/40 to
   **40/40 CUs** (~1.5× GPU compute); dies with defective units are auto-detected
   and stop at their max-safe count (defects are never enabled).
2. **Installs and configures the GPU governor** with a soak-validated
   voltage/frequency curve — undervolted vs stock, so the board runs **cooler and
   quieter at the same clocks** (typically ~40-50 W less at full load).
3. **Applies a tuning profile** matched to what the machine is for, persisted
   across reboots.

Everything survives reboots and OS updates (all state lives in `/etc`,
`/usr/local`, and `/opt`; works on immutable Bazzite).

## Requirements

- AMD BC-250 with the community BIOS already flashed, and BIOS set to:
  Integrated Graphics = **Forces**, UMA Mode = **UMA_SPECIFIED**, UMA Frame
  Buffer = **512 MB** (clear CMOS after setting). The installer checks this and
  refuses to run otherwise.
- Real cooling (the stock passive heatsink alone is not enough at full tilt).
- Bazzite **or** Ubuntu 26.04 LTS, network access, sudo rights.

## Bazzite (Steam Machine)

If the BC-250 tools are already on the box (e.g. layered via rpm-ostree/COPR or
set up by an earlier guide), OPT250 detects and reuses them — no downloads, no
reboot. On a bare Bazzite it installs everything itself (governor release
binary + umr built in a throwaway distrobox), also without an rpm-ostree
layering reboot. Either way it then adds what the common guides skip:
**defective-die safety** (the usual "enable all" unlock turns on every WGP
blindly, including broken ones on a harvested die; OPT250 reads the fuse map
and force-disables defects) and a **sane clock/voltage envelope** (the COPR
governor's sample config allows 2200 MHz @ 1000 mV, which we've measured at
100 °C+; OPT250 caps at 2000 MHz undervolted — within ~3% of the performance at
~50 W less).

Run as your normal user (not root):

```bash
git clone https://github.com/kingjamez/OPT250.git && cd OPT250
./opt250-bazzite.sh                    # gaming profile
./opt250-bazzite.sh --profile quiet    # super-quiet mode
```

| profile | GPU | throttle | for |
|---|---|---|---|
| `gaming` (default) | full 2000 MHz, undervolted | 88 °C | max performance, decent fans |
| `quiet` | capped 1500 MHz | 70 °C | loud stock fans stay slow/near-silent |

## Ubuntu 26.04 LTS

```bash
git clone https://github.com/kingjamez/OPT250.git && cd OPT250
sudo ./opt250-ubuntu.sh                       # asks which profile
sudo ./opt250-ubuntu.sh --profile llm         # non-interactive
```

| profile | GPU | throttle | for |
|---|---|---|---|
| `homeserver` | capped 1000 MHz | 75 °C | always-on server / Home Assistant / Pi replacement — minimum heat |
| `llm` | full 2000 MHz burst | 90 °C | local LLM host — max token speed |
| `performance` | full 2000 MHz | 88 °C | gaming/desktop, noise not a concern |

## After install

```bash
opt250-profile status                  # current profile + live clocks/temp/voltage
sudo opt250-profile quiet              # switch profile any time (persists)
sudo opt250-profile llm --mv 885       # expert: per-board voltage (see below)
```

## Voltage: the `--mv` flag

The curve is anchored at one number: the voltage at 2000 MHz (default
**950 mV** — a mild undervolt that is safe on every board we've measured).
Individual boards go lower: measured crash floors across a 17-board fleet ranged
**850–910 mV**, and validated daily-driver values run ~885 mV on good silicon —
worth another few °C and watts. Only pass `--mv` below the default if the
specific board's floor was measured (e.g. with the
[bc250-llm fleet floor-hunt](https://github.com/kingjamez/bc250-llm)); the tool
refuses values below 850 mV.

## Credits

- [WinnieLV/bc250-cu-live-manager](https://github.com/WinnieLV/bc250-cu-live-manager) — runtime CU unlock + boot persistence
- [filippor/cyan-skillfish-governor](https://github.com/filippor/cyan-skillfish-governor) — the GPU governor
- [umr](https://gitlab.freedesktop.org/tomstdenis/umr) — AMD GPU register access
