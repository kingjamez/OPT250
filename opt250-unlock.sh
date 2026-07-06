#!/usr/bin/env bash
# opt250-unlock.sh — permanently unlock every SAFE compute unit on a BC-250.
#
# Reads the die's CU harvest map via libdrm and enables only WGPs that are
# provably safe: within each shader array, disabled WGPs ABOVE the highest
# enabled CU are binning locks (good silicon) and get enabled; disabled WGPs
# BELOW an enabled CU are holes (defective silicon) and stay off. A clean die
# goes to 40/40; a defective die goes to its max-safe count. Persists across
# reboots via the cu-live-manager boot service.
set -euo pipefail
CULIVE="${CULIVE:-/opt/opt250/cu-live-manager.sh}"
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -x "$CULIVE" ] || { echo "ERROR: $CULIVE missing — run the OPT250 installer"; exit 1; }

mapfile -t ADD < <(python3 - <<'PY'
import ctypes, struct, os, glob
libdrm = ctypes.CDLL("libdrm_amdgpu.so.1")
node = sorted(glob.glob("/dev/dri/renderD*"))[0]
fd = os.open(node, os.O_RDWR)
dev = ctypes.c_void_p(); a = ctypes.c_uint32(); b = ctypes.c_uint32()
libdrm.amdgpu_device_initialize(fd, ctypes.byref(a), ctypes.byref(b), ctypes.byref(dev))
buf = (ctypes.c_uint8 * 1024)()
libdrm.amdgpu_query_info(dev, 0x16, 1024, ctypes.byref(buf))
raw = bytes(buf)
num_se = struct.unpack_from("<I", raw, 20)[0]
num_sh = struct.unpack_from("<I", raw, 24)[0]
for se in range(num_se):
    for sh in range(num_sh):
        bm = struct.unpack_from("<I", raw, 56 + (se*4 + sh)*4)[0]
        on = [((bm >> (2*w)) & 0b11) != 0 for w in range(5)]
        hi = max([w for w in range(5) if on[w]], default=-1)
        for w in range(5):
            if not on[w] and w > hi:
                print(f"{se}.{sh}.{w}")
PY
)
if [ "${#ADD[@]}" -gt 0 ]; then
    echo "opt250-unlock: enabling safe WGPs: ${ADD[*]}"
    "$CULIVE" --yes enable-wgp "${ADD[@]}"
else
    echo "opt250-unlock: die already at max-safe CU count"
fi
"$CULIVE" --yes write-service-table
"$CULIVE" --yes install-service
"$CULIVE" status | grep -i "active & routed" || true
