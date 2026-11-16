#!/bin/bash
# Check regolith-wm-partials, which gathers the partials in force for the
# root configurations:
# - both root configurations include its output, and regolith-wm-config, which
#   both root config packages depend on, installs it;
# - a user partial replaces shipped partials of the same name in the slot of
#   the first, an empty file or a link to /dev/null switches them off, and
#   the session folder wins over the common one;
# - entries that are not partials and remnant names are passed over;
# - the output file is private, replaced in place, and its path is printed;
#   with nowhere to write, the shipped partials are printed.
# Run from the top of the source tree (debian/rules runs it at build time).
set -eu

HELPER=$PWD/scripts/regolith-wm-partials
status=0
fail() { echo "FAIL: $*"; status=1; }
pass() { echo "ok: $*"; }

for wm in i3 sway; do
  if grep -qxF "include \$(/usr/bin/regolith-wm-partials $wm)" "etc/regolith/$wm/config"; then
    pass "the $wm root config includes the partials in force"
  else
    fail "etc/regolith/$wm/config doesn't include regolith-wm-partials $wm"
  fi
  if grep -qE '^include .*/config\.d/\*' "etc/regolith/$wm/config"; then
    fail "etc/regolith/$wm/config still includes a config.d folder directly"
  fi
done
if grep -qxF "scripts/regolith-wm-partials /usr/bin" debian/install; then
  pass "regolith-wm-config installs the helper"
else
  fail "debian/install lacks the helper"
fi
if [ -x "$HELPER" ]; then pass "the helper is executable"; else fail "$HELPER is not executable"; fi
# The root configs need the helper of their own version: an older
# regolith-wm-config without it would leave the session with no partials.
same_version="regolith-wm-config (= \${binary:Version})"
for wm in i3 sway; do
  if sed -n "/^Package: regolith-$wm-root-config\$/,/^\$/p" debian/control \
      | grep -qF "$same_version"; then
    pass "regolith-$wm-root-config depends on regolith-wm-config of its version"
  else
    fail "regolith-$wm-root-config lacks $same_version"
  fi
done

work=$(mktemp -d)
trap 'chmod -R u+rwx "$work"; rm -rf "$work"' EXIT

PYTHONDONTWRITEBYTECODE=1 python3 - "$HELPER" "$work" <<'PY' || status=1
import importlib.machinery, importlib.util, io, os, stat, subprocess, sys
loader = importlib.machinery.SourceFileLoader("wm_partials", sys.argv[1])
spec = importlib.util.spec_from_loader("wm_partials", loader)
p = importlib.util.module_from_spec(spec)
loader.exec_module(p)
work = sys.argv[2]
bad = 0
def check(desc, got, want):
    global bad
    if got == want:
        print("ok: " + desc)
    else:
        print("FAIL: %s: got %r, want %r" % (desc, got, want))
        bad = 1

dirs = {}
for layer in ("common", "wm", "user-common", "user-wm"):
    dirs[layer] = os.path.join(work, layer)
    os.mkdir(dirs[layer])
def put(layer, name, data=None):
    path = os.path.join(dirs[layer], name)
    with open(path, "wb") as handle:
        handle.write(name.encode() + b"\n" if data is None else data)
    return path
def link(layer, name, target):
    os.symlink(target, os.path.join(dirs[layer], name))
def loaded(user=True):
    shipped = [os.fsencode(dirs["common"]), os.fsencode(dirs["wm"])]
    users = [os.fsencode(dirs["user-common"]), os.fsencode(dirs["user-wm"])] if user else [None, None]
    return [c.decode().strip() for _path, c in p.effective_partials(shipped, users)]

for name in ("10_a", "20_b", "30_c", "40_d", "60_f", "70_g", "80_h"):
    put("common", name)
for name in ("20_b", "50_e", "55 space", "56_é"):
    put("wm", name)
put("common", "90_x~")
put("wm", ".hidden")
os.mkdir(os.path.join(dirs["wm"], "57_folder"))
os.mkfifo(os.path.join(dirs["wm"], "58_pipe"))
check("without user partials, shipped partials load in folder order",
      loaded(user=False),
      ["10_a", "20_b", "30_c", "40_d", "60_f", "70_g", "80_h", "20_b", "50_e", "55 space", "56_é"])
shipped_dirs = [os.fsencode(dirs["common"]), os.fsencode(dirs["wm"])]
check("the fallback lists the same shipped partials, in the same order",
      [os.path.basename(path).decode() for path in p.shipped_paths(shipped_dirs)],
      ["10_a", "20_b", "30_c", "40_d", "60_f", "70_g", "80_h", "20_b", "50_e", "55 space", "56_é"])
check("each partial comes under its source and ends with a newline",
      p.render([(b"/a/10_x", b"set $x 1"), (b"/b/20_y", b"set $y 2\n")]),
      b"# /a/10_x\nset $x 1\n# /b/20_y\nset $y 2\n")

put("user-common", "20_b", b"user 20_b\n")       # replaces both shipped 20_b, once
put("user-common", "30_c", b"")                   # switches off
link("user-common", "40_d", "/dev/null")          # switches off
put("user-common", "50_e", b"common 50_e\n")
put("user-wm", "50_e", b"wm 50_e\n")              # session folder wins
put("user-common", "05_new", b"new common\n")
put("user-wm", "01_new", b"new wm\n")
put("user-common", "08_both", b"common 08\n")
put("user-wm", "08_both", b"")                    # session switch-off hides the common one
put("user-wm", "55 space", b"user space\n")
put("user-common", "56_é", b"user unicode\n")
target = put("user-wm", ".target", b"through links\n")
link("user-wm", ".middle", target)
link("user-wm", "70_g", os.path.join(dirs["user-wm"], ".middle"))
empty = put("user-wm", ".empty", b"")
link("user-wm", "80_h", empty)                    # a link to an empty file is nothing
link("user-common", "10_a", "missing")            # dangling: passed over
os.mkdir(os.path.join(dirs["user-wm"], "60_f"))   # folder: passed over
put("user-common", "60_f", b"common 60_f\n")      # ... so the common one is used
os.mkfifo(os.path.join(dirs["user-common"], "90_pipe"))
link("user-common", "91_loop", "91_loop")
link("user-common", "93_device", "/dev/zero")
for name in ("20_b.dpkg-old", "20_b.bak", "#20_b#", ".20_b", "20_b.swp"):
    put("user-common", name, b"junk\n")
check("user partials replace, switch off and follow the shipped ones",
      loaded(),
      ["10_a", "user 20_b", "common 60_f", "through links", "80_h", "wm 50_e",
       "user space", "user unicode", "new common", "new wm"])

env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
       "HOME": os.path.join(work, "home"), "XDG_RUNTIME_DIR": os.path.join(work, "run")}
os.mkdir(env["XDG_RUNTIME_DIR"], 0o700)
def run(**over):
    e = dict(env)
    e.update(over)
    e = {k: v for k, v in e.items() if v is not None}
    return subprocess.run([sys.argv[1], "sway"], env=e, capture_output=True, text=True)
first = run()
out = first.stdout.strip()
check("the helper prints the file it wrote in the runtime folder", out,
      os.path.join(env["XDG_RUNTIME_DIR"], "regolith3", "wm-partials", "sway"))
check("the file is private", stat.S_IMODE(os.stat(out).st_mode) & 0o077, 0)
run()
check("another load leaves one file", sorted(os.listdir(os.path.dirname(out))), ["sway"])
check("an unknown session is refused",
      subprocess.run([sys.argv[1], "x"], capture_output=True).returncode, 2)
os.mkdir(env["HOME"], 0o700)
check("without a runtime folder the file goes under the home",
      run(XDG_RUNTIME_DIR=None).stdout.strip(),
      os.path.join(env["HOME"], ".cache", "regolith3", "wm-partials", "sway"))
fallback = run(XDG_RUNTIME_DIR=None, HOME=None)
check("with nowhere to write, the shipped partials are printed",
      fallback.stdout.split(), [os.fsdecode(path) for path in p.shipped_paths(
          [b"/usr/share/regolith/common/config.d", b"/usr/share/regolith/sway/config.d"])])

# A home that is not valid UTF-8 gets its partials too
odd_home = os.path.join(os.fsencode(work), b"h\xff")
os.mkdir(odd_home, 0o700)
odd = subprocess.run([sys.argv[1], "i3"], capture_output=True,
                     env={b"PATH": b"/usr/bin:/bin", b"LANG": b"C.UTF-8", b"HOME": odd_home})
check("a home that isn't UTF-8 works", (odd.returncode, odd.stdout),
      (0, os.path.join(odd_home, b".cache/regolith3/wm-partials/i3") + b"\n"))


# Any error while gathering the partials falls back to the shipped ones
def broken(*_args):
    raise ValueError("broken")


saved = p.effective_partials, sys.stdout, sys.stderr
p.effective_partials = broken
sys.stdout, sys.stderr = io.TextIOWrapper(io.BytesIO()), io.StringIO()
try:
    status_code = p.main(["regolith-wm-partials", "i3"])
    sys.stdout.flush()
    printed, warned = sys.stdout.buffer.getvalue(), sys.stderr.getvalue()
finally:
    p.effective_partials, sys.stdout, sys.stderr = saved
check("an error while gathering is reported", "regolith-wm-partials: broken" in warned, True)
check("an error while gathering falls back to the shipped partials",
      (status_code, printed.split()), (0, p.shipped_paths(
          [b"/usr/share/regolith/common/config.d", b"/usr/share/regolith/i3/config.d"])))
sys.exit(bad)
PY

exit $status
