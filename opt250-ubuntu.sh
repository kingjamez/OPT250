#!/usr/bin/env bash
# opt250-ubuntu.sh — one-click BC-250 tune for Ubuntu 26.04 LTS.
#
#   sudo ./opt250-ubuntu.sh                      # interactive profile choice
#   sudo ./opt250-ubuntu.sh --profile llm        # non-interactive
#   sudo ./opt250-ubuntu.sh --profile llm --mv 885   # board with a measured floor
#
# What it does: installs umr + the WinnieLV CU live-manager + the
# cyan-skillfish GPU governor, permanently unlocks every safe compute unit
# (40/40 on a clean die), and applies a tuning profile:
#   homeserver  — low heat, always-on (Home Assistant / Pi replacement)
#   llm         — AI box: bursts to full clock for max token speed
#   performance — max GPU performance (gaming/desktop), noise not a concern
set -euo pipefail
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/kingjamez/OPT250/main}"
GOV_VER="v0.4.6"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE=""; MV_ARG=()
while [ $# -gt 0 ]; do case "$1" in
  --profile) PROFILE="$2"; shift 2;;
  --mv) MV_ARG=(--mv "$2"); shift 2;;
  *) echo "unknown arg: $1"; exit 1;;
esac; done
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
say(){ echo -e "\n\033[1;36m== $* ==\033[0m"; }
retry(){ local n; for n in 1 2 3; do "$@" && return 0; echo "  retry $n/3: $*"; sleep 3; done; return 1; }
# fetch a suite file: prefer the local git clone next to this script, else the repo raw URL
get(){ local f="$1" dst="$2"
  if [ -f "$HERE/$f" ]; then install -m755 "$HERE/$f" "$dst"
  else retry curl -fsSL "$RAW_BASE/$f" -o "$dst" && chmod 755 "$dst"; fi; }

say "0. pre-flight checks"
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
echo "  BC-250 detected, UMA OK"

say "1. packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential git cmake llvm-dev clang libdrm-dev python3 pciutils curl \
  pkg-config libpciaccess-dev libncurses-dev libjson-c-dev zlib1g-dev

say "2. umr (GPU register tool — needed by the CU unlock)"
if command -v umr >/dev/null 2>&1; then
  echo "  umr already installed"
else
  T=$(mktemp -d)
  retry git clone --depth 1 https://gitlab.freedesktop.org/tomstdenis/umr "$T/umr"
  ( cd "$T/umr" && cmake -DUMR_NO_GUI=ON -B build -S . \
    && cmake --build build -j"$(nproc)" && cmake --install build ) >/dev/null
  rm -rf "$T"
  command -v umr >/dev/null || { echo "ERROR: umr build failed"; exit 1; }
fi

say "3. CU live-manager + OPT250 tools"
mkdir -p /opt/opt250
retry curl -fsSL https://raw.githubusercontent.com/WinnieLV/bc250-cu-live-manager/main/bc250-cu-live-manager.sh \
  -o /opt/opt250/cu-live-manager.sh
chmod +x /opt/opt250/cu-live-manager.sh
get opt250-unlock.sh /opt/opt250/opt250-unlock.sh
get opt250-profile.py /usr/local/bin/opt250-profile

say "4. GPU governor (binary + service)"
if [ ! -x /etc/cyan-skillfish-governor-smu/cyan-skillfish-governor-smu ]; then
  T=$(mktemp -d); ( cd "$T"
    B="https://github.com/filippor/cyan-skillfish-governor/releases/download/${GOV_VER}"
    retry curl -fsSL -O "$B/cyan-skillfish-governor-smu-${GOV_VER}-x86_64-linux.tar.gz"
    retry curl -fsSL -O "$B/cyan-skillfish-governor-smu-${GOV_VER}-x86_64-linux.tar.gz.sha256"
    sha256sum -c ./*.sha256 && tar -xf ./*.tar.gz && cd cyan-skillfish-governor-smu-*/
    mkdir -p /etc/cyan-skillfish-governor-smu
    install -m755 cyan-skillfish-governor-smu /etc/cyan-skillfish-governor-smu/ )
  rm -rf "$T"
else
  echo "  governor binary already installed"
fi
cat > /etc/systemd/system/cyan-skillfish-governor-smu.service <<'U'
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
cat > /etc/systemd/system/opt250-apply.service <<'U'
[Unit]
Description=OPT250 profile boot re-apply (CPU governor)
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/opt250-profile --reapply
[Install]
WantedBy=multi-user.target
U
systemctl daemon-reload
systemctl enable opt250-apply.service >/dev/null 2>&1

say "5. permanent CU unlock"
bash /opt/opt250/opt250-unlock.sh

say "6. tuning profile"
if [ -z "$PROFILE" ] && [ -e /dev/tty ]; then
  echo "  1) homeserver  — low heat, always-on (Home Assistant / Pi replacement)"
  echo "  2) llm         — AI box: bursts to full clock for max token speed"
  echo "  3) performance — max GPU performance, noise not a concern"
  read -r -p "Choose profile [1-3, default 1]: " ans < /dev/tty || ans=""
  case "${ans:-1}" in 2) PROFILE=llm;; 3) PROFILE=performance;; *) PROFILE=homeserver;; esac
fi
PROFILE="${PROFILE:-homeserver}"
opt250-profile "$PROFILE" "${MV_ARG[@]}"

say "DONE"
opt250-profile status
echo
echo "  Switch any time:  sudo opt250-profile <homeserver|llm|performance> [--mv N]"
