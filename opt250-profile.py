#!/usr/bin/env python3
"""opt250-profile — BC-250 tuning profile manager (installed as /usr/local/bin/opt250-profile).

Writes a cyan-skillfish-governor-smu config for the chosen profile and (re)starts the
governor. Profiles differ in max GPU clock and thermal-throttle envelope; the voltage
curve is a validated V/F shape anchored at a single 2000MHz voltage (default 950mV,
conservative enough for any BC-250; boards with a measured undervolt floor can go
lower via --mv).

Profiles
  gaming       Bazzite Steam Machine: full 2000MHz, undervolted, 88C throttle.
  quiet        Super-quiet: GPU capped at 1500MHz + 70C throttle -> fans stay slow.
  homeserver   Always-on server (Home Assistant / Pi replacement): 1000MHz cap, low heat.
  llm          LLM host: bursts to full 2000MHz, tolerates heat/noise (90C throttle).
  performance  Max performance, noise not a concern (Ubuntu gaming/desktop).

Usage
  sudo opt250-profile <profile> [--mv N]   apply a profile (persists across reboots)
  opt250-profile status                    show current tune + live GPU state
  opt250-profile list                     show profile table
  sudo opt250-profile --reapply           re-apply saved CPU governor (boot hook)
"""
import argparse, glob, json, os, re, subprocess, sys, datetime

GOVCFG = "/etc/cyan-skillfish-governor-smu/config.toml"
GOVSVC = "cyan-skillfish-governor-smu"
STATE = "/etc/opt250/profile.json"
CULIVE = "/opt/opt250/cu-live-manager.sh"

# V/F curve shape validated under sustained soak on real hardware (anchor = the
# 2000MHz point; every other point is a fixed offset below it).
OFFSETS = [(2000, 0), (1850, -15), (1700, -25), (1600, -35),
           (1500, -45), (1175, -85), (1000, -125), (500, -185)]
VMIN = 600
DEFAULT_MV = 950   # safe on every board measured (fleet floors 850-910mV)
MV_MIN = 850       # lowest floor ever observed -- refuse below this
MV_MAX = 1000

PROFILES = {
    "gaming":      dict(maxf=2000, minf=1000, throttle=88, recovery=80, cpu=None,
                        blurb="Bazzite gaming: full clock, undervolted, cool"),
    "quiet":       dict(maxf=1500, minf=500,  throttle=70, recovery=62, cpu=None,
                        blurb="super-quiet: 1500MHz cap, fans stay slow"),
    "homeserver":  dict(maxf=1000, minf=500,  throttle=75, recovery=67, cpu="schedutil",
                        blurb="always-on server: minimum heat, ample perf"),
    "llm":         dict(maxf=2000, minf=1000, throttle=90, recovery=82, cpu=None,
                        blurb="LLM host: max token speed, heat/noise OK"),
    "performance": dict(maxf=2000, minf=1000, throttle=88, recovery=80, cpu=None,
                        blurb="max performance, noise not a concern"),
}


def sh(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        return r.returncode, r.stdout.strip() + r.stderr.strip()
    except Exception as e:
        return 1, str(e)


def find_gpu():
    for c in glob.glob("/sys/class/drm/card*/device"):
        try:
            if open(c + "/vendor").read().strip() == "0x1002" and \
               os.path.exists(c + "/pp_dpm_sclk"):
                return c
        except OSError:
            pass
    return None


def build_config(p, mv):
    pts = sorted((f, max(VMIN, mv + off)) for f, off in OFFSETS)
    body = ('[timing.intervals]\nsample = 250\nadjust = 100_000\n'
            '[gpu-usage]\nfix-metrics = true\nmethod = "busy-flag"\nflush-every = 10\n'
            '[gpu]\nset-method = "smu"\n[dbus]\nenabled = false\n'
            '[frequency-range]\nmin = %d\nmax = %d\n'
            '[timing.ramp-rates]\nnormal = 1\nburst = 50\n'
            '[timing]\nburst-samples = 60\ndown-events = 5\n'
            '[frequency-thresholds]\nadjust = 10\n'
            '[load-target]\nupper = 0.65\nlower = 0.50\n'
            '[temperature]\nthrottling = %d\nthrottling_recovery = %d\n'
            % (p["minf"], p["maxf"], p["throttle"], p["recovery"]))
    for f, v in pts:
        body += "[[safe-points]]\nfrequency = %d\nvoltage = %d\n" % (f, v)
    return body


def set_cpufreq(gov):
    """Best-effort CPU scaling governor (only if cpufreq is exposed on this board)."""
    if not gov:
        return
    pols = glob.glob("/sys/devices/system/cpu/cpufreq/policy*/scaling_governor")
    done = 0
    for pol in pols:
        try:
            avail = open(os.path.dirname(pol) + "/scaling_available_governors").read()
            if gov in avail.split():
                open(pol, "w").write(gov)
                done += 1
        except OSError:
            pass
    if pols:
        print("  cpufreq: %s on %d/%d policies" % (gov, done, len(pols)))


def save_state(name, mv):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    json.dump({"profile": name, "mv": mv,
               "ts": datetime.datetime.now().isoformat(timespec="seconds")},
              open(STATE, "w"), indent=2)


def load_state():
    try:
        return json.load(open(STATE))
    except (OSError, ValueError):
        return None


def apply_profile(name, mv):
    if os.geteuid() != 0:
        os.execvp("sudo", ["sudo", os.path.realpath(sys.argv[0])] + sys.argv[1:])
    p = PROFILES[name]
    if not os.path.isdir(os.path.dirname(GOVCFG)):
        raise SystemExit("ERROR: governor not installed (%s missing) — run the OPT250 installer first."
                         % os.path.dirname(GOVCFG))
    print("applying profile '%s' (max %dMHz, throttle %dC, 2000MHz anchor %dmV)"
          % (name, p["maxf"], p["throttle"], mv))
    open(GOVCFG, "w").write(build_config(p, mv))
    sh("systemctl enable %s >/dev/null 2>&1" % GOVSVC)
    sh("systemctl restart %s" % GOVSVC)
    rc, out = sh("systemctl is-active %s" % GOVSVC)
    if out != "active":
        raise SystemExit("ERROR: governor failed to start (%s) — check: journalctl -u %s" % (out, GOVSVC))
    set_cpufreq(p["cpu"])
    save_state(name, mv)
    print("  governor: active, config -> %s" % GOVCFG)
    print("  profile persisted (survives reboot). Check with: opt250-profile status")


def status():
    st = load_state()
    print("== OPT250 status ==")
    if st:
        print("  profile   : %s  (2000MHz anchor %smV, set %s)"
              % (st.get("profile"), st.get("mv"), st.get("ts")))
    else:
        print("  profile   : (none applied yet)")
    rc, act = sh("systemctl is-active %s" % GOVSVC)
    print("  governor  : %s" % act)
    gpu = find_gpu()
    if gpu:
        cur = ""
        try:
            m = re.search(r"(\d+)Mhz\s*\*", open(gpu + "/pp_dpm_sclk").read())
            cur = m.group(1) + "MHz" if m else "?"
        except OSError:
            pass
        hw = (glob.glob(gpu + "/hwmon/hwmon*") or [None])[0]
        temp = mvolt = None
        if hw:
            try: temp = int(open(hw + "/temp1_input").read()) // 1000
            except (OSError, ValueError): pass
            try: mvolt = int(open(hw + "/in0_input").read())
            except (OSError, ValueError): pass
        print("  GPU       : %s  %s  vddgfx %smV" % (cur, "%dC" % temp if temp is not None else "?", mvolt))
    if os.path.exists(CULIVE):
        rc, out = sh("%s status 2>/dev/null | grep -i 'active & routed'" % CULIVE)
        if out:
            print("  CUs       : %s" % out.strip())


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("action", nargs="?", default="status")
    ap.add_argument("--mv", type=int, default=DEFAULT_MV,
                    help="voltage (mV) at the 2000MHz curve point (default %d)" % DEFAULT_MV)
    ap.add_argument("--reapply", action="store_true", help="boot hook: re-apply saved CPU governor")
    ap.add_argument("-h", "--help", action="store_true")
    args = ap.parse_args()

    if args.help:
        print(__doc__)
        return
    if args.reapply:
        st = load_state()
        if st and st.get("profile") in PROFILES:
            set_cpufreq(PROFILES[st["profile"]]["cpu"])
        return
    if args.action == "status":
        status()
        return
    if args.action == "list":
        for n, p in PROFILES.items():
            print("  %-12s max %4dMHz  throttle %dC   %s" % (n, p["maxf"], p["throttle"], p["blurb"]))
        return
    if args.action not in PROFILES:
        raise SystemExit("unknown profile '%s' — one of: %s, or 'status'/'list'"
                         % (args.action, ", ".join(PROFILES)))
    if not (MV_MIN <= args.mv <= MV_MAX):
        raise SystemExit("--mv %d out of safe range %d-%d (fleet-measured crash floors are 850-910mV; "
                         "use a per-board floor-hunt before going lower)" % (args.mv, MV_MIN, MV_MAX))
    apply_profile(args.action, args.mv)


if __name__ == "__main__":
    main()
