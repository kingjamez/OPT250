#!/usr/bin/env bash
# opt250-unlock.sh — permanently set every SAFE compute unit on a BC-250.
#
# Reads the die's original (boot-time) CU harvest map via libdrm and computes the
# max-safe WGP set: within each shader array, disabled WGPs ABOVE the highest
# enabled CU are binning locks (good silicon) and get enabled; disabled WGPs
# BELOW an enabled CU are holes (defective silicon) and get force-DISABLED —
# important on Bazzite 43+, whose bundled first-boot unlock enables everything
# blindly, defects included. A clean die lands on 40/40; a defective die lands
# on its max-safe count. Persists across reboots via the cu-live-manager boot
# service.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

# prefer an existing install (Bazzite 43+ bundles it), else the OPT250 copy
if [ -z "${CULIVE:-}" ]; then
  for c in /usr/local/bin/bc250-cu-live-manager /opt/opt250/cu-live-manager.sh; do
    [ -x "$c" ] && CULIVE="$c" && break
  done
fi
[ -n "${CULIVE:-}" ] && [ -x "$CULIVE" ] || { echo "ERROR: cu-live-manager not found — run the OPT250 installer"; exit 1; }

ADD=(); DEL=()
while read -r verb wgp; do
  case "$verb" in
    ADD) ADD+=("$wgp");;
    DEL) DEL+=("$wgp");;
    MAP) echo "  die $wgp";;
  esac
done < <(python3 - <<'PY'
import ctypes, struct, os, glob
libdrm = ctypes.CDLL("libdrm_amdgpu.so.1")
fd = os.open(sorted(glob.glob("/dev/dri/renderD*"))[0], os.O_RDWR)
dev = ctypes.c_void_p(); a = ctypes.c_uint32(); b = ctypes.c_uint32()
libdrm.amdgpu_device_initialize(fd, ctypes.byref(a), ctypes.byref(b), ctypes.byref(dev))
buf = (ctypes.c_uint8 * 1024)()
libdrm.amdgpu_query_info(dev, 0x16, 1024, ctypes.byref(buf))
raw = bytes(buf)
num_se = struct.unpack_from("<I", raw, 20)[0]
num_sh = struct.unpack_from("<I", raw, 24)[0]
for se in range(num_se):
    for sh in range(num_sh):
        bm = struct.unpack_from("<I", raw, 56 + (se*4 + sh)*4)[0] & 0x3ff
        print("MAP SE%d.SH%d:%s" % (se, sh, "".join("#" if (bm>>i)&1 else "." for i in range(10))))
        on = [((bm >> (2*w)) & 0b11) != 0 for w in range(5)]
        hi = max([w for w in range(5) if on[w]], default=-1)
        for w in range(5):
            if not on[w]:
                print(("ADD" if w > hi else "DEL") + f" {se}.{sh}.{w}")
PY
)
if [ "${#DEL[@]}" -gt 0 ]; then
    echo "opt250-unlock: DEFECTIVE die — force-disabling bad WGPs: ${DEL[*]}"
    "$CULIVE" --yes disable-wgp "${DEL[@]}"
fi
if [ "${#ADD[@]}" -gt 0 ]; then
    echo "opt250-unlock: enabling safe WGPs: ${ADD[*]}"
    "$CULIVE" --yes enable-wgp "${ADD[@]}"
else
    echo "opt250-unlock: no locked-good WGPs to enable"
fi
"$CULIVE" --yes write-service-table
# install the boot service only if it isn't already there (Bazzite 43+ ships it;
# re-running install-service from /usr/local/bin would copy the script onto itself)
if [ ! -e /etc/systemd/system/bc250-cu-live-manager.service ] && \
   [ ! -e /usr/lib/systemd/system/bc250-cu-live-manager.service ]; then
    "$CULIVE" --yes install-service
fi
"$CULIVE" status | grep -i "active & routed" || true
