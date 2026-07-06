#!/usr/bin/env bash
# opt250-bazzite.sh — one-click BC-250 Steam Machine tune for Bazzite.
#
#   ./opt250-bazzite.sh                       # gaming profile (default)
#   ./opt250-bazzite.sh --profile quiet       # super-quiet mode (capped clocks)
#   ./opt250-bazzite.sh --mv 885              # board with a measured undervolt floor
#
# Run as your NORMAL USER (not root — umr is built in a distrobox); it uses sudo
# for the privileged steps. What it does: installs umr (via a throwaway Fedora
# distrobox — Bazzite is immutable, no reboot needed) + the WinnieLV CU
# live-manager + the cyan-skillfish GPU governor, permanently unlocks every safe
# compute unit (40/40 on a clean die), and applies the tuning profile:
#   gaming — full 2000MHz, undervolted (cooler + quieter at the same speed)
#   quiet  — clocks capped at 1500MHz, 70C throttle: fans stay slow/silent
set -euo pipefail
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/kingjamez/OPT250/main}"
GOV_VER="v0.4.6"
BOX=opt250-umrbox
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="gaming"; MV_ARG=()
while [ $# -gt 0 ]; do case "$1" in
  --profile) PROFILE="$2"; shift 2;;
  --quiet) PROFILE=quiet; shift;;
  --mv) MV_ARG=(--mv "$2"); shift 2;;
  *) echo "unknown arg: $1"; exit 1;;
esac; done
case "$PROFILE" in gaming|quiet) ;; *) echo "Bazzite profiles: gaming | quiet"; exit 1;; esac
[ "$(id -u)" != 0 ] || { echo "run as your normal user (not root/sudo) — it will sudo when needed"; exit 1; }
say(){ echo -e "\n\033[1;36m== $* ==\033[0m"; }
retry(){ local n; for n in 1 2 3; do "$@" && return 0; echo "  retry $n/3: $*"; sleep 3; done; return 1; }
get(){ local f="$1" dst="$2"
  if [ -f "$HERE/$f" ]; then sudo install -m755 "$HERE/$f" "$dst"
  else retry curl -fsSL "$RAW_BASE/$f" -o /tmp/opt250.get && sudo install -m755 /tmp/opt250.get "$dst"; fi; }
# runs if the binary loads and executes (any normal exit code) — catches missing libs (127/126)
runs(){ "$1" -h >/dev/null 2>&1 || [ $? -lt 126 ]; }

say "0. pre-flight checks"
sudo true   # prime sudo (NOT `sudo -v` — it demands a password when the user also matches a non-NOPASSWD wheel rule)
if ! lspci -nn 2>/dev/null | grep -qi "1002:13fe"; then
  echo "ERROR: no BC-250 GPU (1002:13fe) found on this host."; exit 1
fi
for d in /sys/class/drm/card*/device; do
  [ -e "$d/pp_dpm_sclk" ] || continue
  vram=$(( $(cat "$d/mem_info_vram_total" 2>/dev/null || echo 0) / 1048576 ))
  if [ "$vram" -gt 2048 ]; then
    echo "ERROR: VRAM carveout is ${vram}MB — BIOS UMA is not set to 512MB."
    echo "  Fix in BIOS: Integrated Graphics=Forces, UMA Mode=UMA_SPECIFIED, UMA Frame"
    echo "  Buffer Size=512M — then CLEAR CMOS and re-run this installer."
    exit 1
  fi
done
command -v distrobox >/dev/null || { echo "ERROR: distrobox not found (it ships with Bazzite)"; exit 1; }
echo "  BC-250 detected, UMA OK"

say "1. umr (GPU register tool — needed by the CU unlock)"
if command -v umr >/dev/null 2>&1 && runs "$(command -v umr)"; then
  echo "  umr present ($(command -v umr)) — Bazzite 43+ ships it"
else
  FEDORA_VER="$(. /etc/os-release; echo "${VERSION_ID:-43}")"
  echo "  building in a Fedora-$FEDORA_VER distrobox (one-time, a few minutes)..."
  distrobox create -Y -n "$BOX" -i "registry.fedoraproject.org/fedora-toolbox:${FEDORA_VER}" >/dev/null || true
  # try the packaged umr first; heredoc-free + </dev/null (distrobox eats stdin)
  if distrobox enter "$BOX" -- bash -lc \
      'sudo dnf install -y umr && cp /usr/bin/umr ~/.opt250-umr-bin && rm -rf ~/.opt250-umr-share && cp -r /usr/share/umr ~/.opt250-umr-share' \
      </dev/null; then
    echo "  (used the Fedora umr package)"
  else
    echo "  no umr package — building from source in the box..."
    distrobox enter "$BOX" -- bash -lc \
      'sudo dnf install -y llvm-devel clang-devel libdrm-devel libpciaccess-devel ncurses-devel json-c-devel zlib-devel cmake gcc gcc-c++ git make \
       && rm -rf ~/.opt250-umr-src ~/.opt250-umr-stage && git clone --depth 1 https://gitlab.freedesktop.org/tomstdenis/umr ~/.opt250-umr-src \
       && cd ~/.opt250-umr-src && cmake -DUMR_NO_GUI=ON -B build -S . && cmake --build build -j"$(nproc)" \
       && DESTDIR=$HOME/.opt250-umr-stage cmake --install build \
       && cp "$(find ~/.opt250-umr-stage -type f -name umr -path "*/bin/*" | head -1)" ~/.opt250-umr-bin \
       && rm -rf ~/.opt250-umr-share && cp -r "$(find ~/.opt250-umr-stage -type d -name umr -path "*/share/*" | head -1)" ~/.opt250-umr-share' \
      </dev/null
  fi
  [ -f "$HOME/.opt250-umr-bin" ] || { echo "ERROR: umr build produced no binary"; exit 1; }
  sudo install -m755 "$HOME/.opt250-umr-bin" /usr/local/bin/umr
  sudo rm -rf /usr/local/share/umr
  sudo mkdir -p /usr/local/share
  sudo cp -r "$HOME/.opt250-umr-share" /usr/local/share/umr   # pci.did database — umr fails without it
  rm -rf "$HOME/.opt250-umr-bin" "$HOME/.opt250-umr-share"
  runs /usr/local/bin/umr || { echo "ERROR: umr binary doesn't run on the host"; exit 1; }
  distrobox rm -f "$BOX" >/dev/null 2>&1 || true
  echo "  umr installed to /usr/local/bin/umr"
fi

say "2. CU live-manager + OPT250 tools"
sudo mkdir -p /opt/opt250
if command -v bc250-cu-live-manager >/dev/null 2>&1; then
  echo "  using Bazzite's bundled CU live-manager ($(command -v bc250-cu-live-manager))"
else
  retry curl -fsSL https://raw.githubusercontent.com/WinnieLV/bc250-cu-live-manager/main/bc250-cu-live-manager.sh \
    -o /tmp/opt250-culive.sh
  sudo install -m755 /tmp/opt250-culive.sh /opt/opt250/cu-live-manager.sh
fi
get opt250-unlock.sh /opt/opt250/opt250-unlock.sh
get opt250-profile.py /usr/local/bin/opt250-profile

say "3. GPU governor"
if command -v cyan-skillfish-governor-smu >/dev/null 2>&1; then
  echo "  using Bazzite's packaged governor ($(rpm -q cyan-skillfish-governor-smu 2>/dev/null || echo present)) — config only"
else
  # older Bazzite: install the release binary + our own service unit
  if [ ! -x /etc/cyan-skillfish-governor-smu/cyan-skillfish-governor-smu ]; then
    T=$(mktemp -d); ( cd "$T"
      B="https://github.com/filippor/cyan-skillfish-governor/releases/download/${GOV_VER}"
      retry curl -fsSL -O "$B/cyan-skillfish-governor-smu-${GOV_VER}-x86_64-linux.tar.gz"
      retry curl -fsSL -O "$B/cyan-skillfish-governor-smu-${GOV_VER}-x86_64-linux.tar.gz.sha256"
      sha256sum -c ./*.sha256 && tar -xf ./*.tar.gz && cd cyan-skillfish-governor-smu-*/
      sudo mkdir -p /etc/cyan-skillfish-governor-smu
      sudo install -m755 cyan-skillfish-governor-smu /etc/cyan-skillfish-governor-smu/ )
    rm -rf "$T"
  else
    echo "  governor binary already installed"
  fi
  sudo tee /etc/systemd/system/cyan-skillfish-governor-smu.service >/dev/null <<'U'
[Unit]
Description=Cyan Skillfish GPU Governor
After=multi-user.target
[Service]
Type=simple
ExecStart=/etc/cyan-skillfish-governor-smu/cyan-skillfish-governor-smu /etc/cyan-skillfish-governor-smu/config.toml
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
U
  sudo systemctl daemon-reload
fi

say "4. permanent CU unlock"
sudo bash /opt/opt250/opt250-unlock.sh

say "5. tuning profile: $PROFILE"
sudo /usr/local/bin/opt250-profile "$PROFILE" "${MV_ARG[@]}"

say "DONE"
/usr/local/bin/opt250-profile status
echo
echo "  Switch any time:  sudo opt250-profile <gaming|quiet> [--mv N]"
