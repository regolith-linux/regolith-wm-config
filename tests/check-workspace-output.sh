#!/bin/bash
# Check regolith-wm-workspace-output:
# - the common partial starts the helper, the i3 root config includes the
#   assignments it writes after the user partials, and the install file ships
#   both;
# - the helper names workspaces as each window manager does: i3 keeps the
#   double quotes of the looks' markup, sway strips them, and the i3
#   configuration parser only knows the escape \";
# - it reads the output lists, leaves workspaces with a line of the user's own
#   to that line, and writes the assignments both sessions need;
# - it moves pinned workspaces when outputs come and go, as the lists say.
# Run from the top of the source tree (debian/rules runs it at build time).
set -eu

HELPER=$PWD/scripts/regolith-workspace-output
PARTIAL=$PWD/usr/share/regolith/common/config.d/41_workspace-output
INSTALL=$PWD/debian/regolith-wm-workspace-output.install
I3_ROOT=$PWD/etc/regolith/i3/config
status=0
fail() { echo "FAIL: $*"; status=1; }
pass() { echo "ok: $*"; }

grep -qxF 'exec_always --no-startup-id /usr/bin/regolith-workspace-output' "$PARTIAL" \
  && pass "the partial starts the helper with exec_always" \
  || fail "$PARTIAL does not start the helper with exec_always"
grep -qxF 'usr/share/regolith/common/config.d/41_workspace-output' "$INSTALL" \
  && pass "the partial is installed" || fail "$INSTALL lacks the partial"
grep -qE '^scripts/regolith-workspace-output[[:space:]]+usr/bin$' "$INSTALL" \
  && pass "the helper is installed" || fail "$INSTALL lacks the helper"
[ -x "$HELPER" ] && pass "the helper is executable" || fail "$HELPER is not executable"

include='include $XDG_RUNTIME_DIR/regolith-workspace-output/i3.conf'
inc=$(grep -nxF "$include" "$I3_ROOT" | cut -d: -f1)
user=$(grep -nxF 'include $HOME/.config/regolith3/i3/config.d/*' "$I3_ROOT" | cut -d: -f1)
if [ -n "$inc" ] && [ -n "$user" ] && [ "$inc" -gt "$user" ]; then
  pass "the i3 root config includes the assignments after the user partials"
else
  fail "$I3_ROOT must include the assignments after the user partials"
fi

PYTHONDONTWRITEBYTECODE=1 python3 - "$HELPER" <<'PY' || status=1
import importlib.machinery, importlib.util, os, re, sys, tempfile
loader = importlib.machinery.SourceFileLoader("workspace_output", sys.argv[1])
spec = importlib.util.spec_from_loader("workspace_output", loader)
w = importlib.util.module_from_spec(spec)
loader.exec_module(w)
w.log = lambda message: None
bad = 0


def check(desc, got, want):
    global bad
    if got == want:
        print("ok: " + desc)
    else:
        print("FAIL: %s: got %r, want %r" % (desc, got, want))
        bad = 1


LOOK = '5:<span> </span>5 <span foreground="#cb4b16">★</span><span> </span>'
SINGLE = "3:<span> </span>3 <span foreground='#859900'>★</span><span> </span>"

# What sway 1.11 names `workspace number "<value>"` (checked against sway).
for value, name in [
        (LOOK, LOOK.replace('"', "")),
        (SINGLE, SINGLE),
        ("plain name", "plain name"),
        ('a "b c" d', 'a b c" d"'),
        ("it's", "it's"),
        ("x;y", "x;y"),
        ('mixed "q" and \'s\'', "mixed q and 's'")]:
    check("sway names %r %r" % (value, name),
          " ".join(w.sway_words('"' + value + '"')), name)
# What i3 4.25 names `workspace number <value>` (checked against i3).
for value, name in [(LOOK, LOOK), (SINGLE, SINGLE), ('a "b c" d', 'a "b c" d'),
                    ("back\\\\slash", "back\\slash"), ('"7"', "7"),
                    ("cut;here", "cut")]:
    check("i3 names %r %r" % (value, name), w.i3_string(value)[0], name)
check("an i3 word ends at whitespace", w.i3_string("one two", word=True),
      ("one", " two"))
check("an i3 quoted word keeps its spaces", w.i3_string('"a b" output X', word=True),
      ("a b", " output X"))
check("i3 config quoting escapes double quotes only", w.i3_config_quote('a"b\\c'),
      '"a\\"b\\c"')
check("i3 config quoting refuses a backslash before a quote",
      w.i3_config_quote('a\\"b'), None)
check("i3 config quoting refuses a trailing backslash", w.i3_config_quote("a\\"), None)
check("i3 command quoting escapes backslashes too", w.i3_quote('a"b\\c'), '"a\\"b\\\\c"')

home = tempfile.mkdtemp()


def settings(wm, resources, user=None):
    for directory in ("common-wm", "i3", "sway"):
        path = os.path.join(home, ".config", "regolith3", directory, "config.d")
        os.makedirs(path, exist_ok=True)
        for old in os.listdir(path):
            os.unlink(os.path.join(path, old))
    if user:
        directory, text = user
        with open(os.path.join(home, ".config", "regolith3", directory,
                               "config.d", "50-mine"), "w") as f:
            f.write(text)
    return w.Settings(wm, resources, home)


res = {"wm.workspace.05.name": LOOK,
       "wm.workspace.05.output": "HDMI-1\tHDMI-A-1  eDP-1",
       "wm.workspace.03.name": SINGLE,
       "wm.workspace.03.output": 'bad"name DP-2 <x>',
       "wm.workspace.04.output": "",
       "wm.workspace.01.output": "eDP-1"}
i3 = settings("i3", res)
check("output names split at spaces and tabs", i3.pins[5], ["HDMI-1", "HDMI-A-1", "eDP-1"])
check("output names neither window manager takes are dropped", i3.pins[3], ["DP-2"])
check("an empty value pins nothing", 4 in i3.pins, False)
check("a workspace without a name resource is pinned by its number",
      i3.assignments()[0], 'workspace "1" output eDP-1')
check("i3 assignments keep the look's double quotes, escaped",
      i3.assignments()[2],
      'workspace "%s" output HDMI-1 HDMI-A-1 eDP-1' % LOOK.replace('"', '\\"'))
check("the i3 file starts with its header and has one line per pin",
      i3.config().splitlines()[2:], i3.assignments())
sway = settings("sway", res)
check("sway assignments give the value as the keys do, in double quotes",
      sway.assignments()[2], 'workspace "%s" output HDMI-1 HDMI-A-1 eDP-1' % LOOK)
check("sway's name for the look's workspace drops the quotes",
      sway.names[5], LOOK.replace('"', ""))
check("sway opens the workspace with the keys' own argument",
      sway.argument(5), '"%s"' % LOOK)
check("i3 opens the workspace with an escaped argument",
      i3.argument(5), '"%s"' % LOOK.replace('"', '\\"'))
check("no assignments, no i3 file", settings("i3", {}).config(), "")
# i3 names the key's workspace "end\" (its parser turns \\ into \), a name
# its configuration parser cannot read back.
bs = settings("i3", {"wm.workspace.02.name": "end\\\\", "wm.workspace.02.output": "eDP-1"})
check("i3 cannot assign a name ending in a backslash", (bs.names[2], bs.pins),
      ("end\\", {}))

check("the first connected output in the list is the target",
      i3.target(5, ["eDP-1", "hdmi-a-1"]), "hdmi-a-1")
check("no connected output in the list, no target", i3.target(5, ["DP-9"]), None)
check("ranks follow the list", [i3.rank(5, o) for o in ("HDMI-1", "eDP-1", "DP-9")],
      [0, 2, 3])

# A line of the user's own wins over the value of its workspace only.
plain = dict(res, **{"wm.workspace.03.name": "3", "wm.workspace.03.output": "DP-2"})
for wm, directory, line, gone in [
        ("i3", "i3", "workspace $ws3 output DP-1\n", 3),
        ("i3", "common-wm", "workspace 5 output DP-1\n", 5),
        ("i3", "i3", 'workspace "%s" output DP-1\n' % LOOK.replace('"', '\\"'), 5),
        ("sway", "sway", "workspace $ws5 output DP-1\n", 5),
        ("sway", "common-wm", "workspace %s output DP-1\n" % LOOK.replace('"', ""), 5),
        ("sway", "sway", "workspace $ws3 output DP-1\n", 3)]:
    s = settings(wm, plain, (directory, line))
    check("%s: %r overrides the value of workspace %d" % (wm, line.strip(), gone),
          (gone in s.pins, sorted(set(s.pins) - {gone})),
          (False, sorted(set(settings(wm, plain).pins) - {gone})))
check("sway assigns no bare numbers: 'workspace 5' is not workspace 5's line",
      5 in settings("sway", plain, ("sway", "workspace 5 output DP-1\n")).pins, True)
check("commented lines don't count",
      5 in settings("i3", plain, ("i3", "# workspace 5 output DP-1\n")).pins, True)
check("gaps lines don't count",
      5 in settings("i3", plain, ("i3", "workspace 5 gaps inner 4\n")).pins, True)


class FakeWM:
    """Just enough of the IPC interface to move workspaces between outputs."""

    def __init__(self, wm, outputs, workspaces):
        self.wm = wm
        self.outputs = list(outputs)
        self.ws = [dict(id=100 + num, num=num, name=str(num), output=out,
                        visible=False, focused=False) for num, out in workspaces]
        self.commands = []

    def request(self, kind, payload=""):
        if kind == w.IPC_GET_OUTPUTS:
            return [dict(name=o, active=True) for o in self.outputs]
        if kind == w.IPC_GET_WORKSPACES:
            return [dict(ws) for ws in self.ws]
        if kind == w.IPC_GET_TREE:
            return dict(id=1, type="root", nodes=[
                dict(id=ws["id"], type="workspace", focused=False, nodes=[
                    dict(id=ws["id"] + 1000, type="con", nodes=[])])
                for ws in self.ws])
        raise AssertionError(kind)

    def command(self, text):
        self.commands.append(text)
        m = re.match(r'\[con_id=(\d+)\] move workspace to output "(.+)"$', text)
        if m:
            con = int(m.group(1))
            for ws in self.ws:
                if con in (ws["id"], ws["id"] + 1000):
                    ws["output"] = m.group(2)
        return True

    def unplug(self, out, fallback):
        self.outputs.remove(out)
        for ws in self.ws:
            if ws["output"] == out:
                ws["output"] = fallback


def placement(wm, lists, outputs, workspaces):
    resources = {"wm.workspace.%02d.output" % n: v for n, v in lists.items()}
    fake = FakeWM(wm, outputs, workspaces)
    p = w.Placement("unused", fake, wm, home, arrange=False)
    p.settings = w.Settings(wm, resources, home)
    p.remember()
    return p, fake


settings("i3", {})  # no user lines
for wm in ("i3", "sway"):
    p, fake = placement(wm, {5: "C B A", 6: "B"}, ["A", "B", "C"],
                        [(5, "C"), (6, "B"), (7, "C")])
    fake.unplug("C", "A")  # i3 and sway put orphans on any output
    p.follow_outputs()
    got = {ws["num"]: ws["output"] for ws in fake.ws}
    check("%s: a workspace whose output left goes to the next one in its list" % wm,
          got[5], "B")
    check("%s: a workspace without a value stays where the WM put it" % wm, got[7], "A")
    fake.outputs.append("C")
    p.follow_outputs()
    got = {ws["num"]: ws["output"] for ws in fake.ws}
    check("%s: it returns when a higher-ranked output appears" % wm, got[5], "C")
    check("%s: others stay" % wm, (got[6], got[7]), ("B", "A"))
    fake.ws[0]["output"] = "A"   # the user moved workspace 5 to A
    p.remember()
    fake.outputs.append("D")     # an output in nobody's list
    p.follow_outputs()
    check("%s: an output in no list moves nothing" % wm, fake.ws[0]["output"], "A")

sys.exit(bad)
PY

exit $status
