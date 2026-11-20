#!/bin/bash
# Check regolith-workspace-step and the relative workspace keys in
# 30_navigation:
# - all eight keys are nop bindings that the helper's --serve instance picks
#   up from the window manager's binding events, and one exec_always line
#   starts that instance;
# - the navigation package ships the helper and depends on what it needs;
# - unless wm.workspace.wrap is "no" or "false" (white space around it and
#   letter case ignored), a press runs the window manager's own command; in
#   i3 the value is read from the X resource database as stored (quotes
#   included), as trawl keeps it in sway;
# - otherwise it follows the numbered workspaces by number, then the others
#   in the reported order (or the focused output's workspaces in the reported
#   order), and sends nothing at an end;
# - names reach i3 and sway quoted for each one's command parser, and names
#   sway's workspace command reads as keywords are reached another way.
# Run from the top of the source tree (debian/rules runs it at build time).
set -eu

HELPER=$PWD/scripts/regolith-workspace-step
NAVIGATION=$PWD/usr/share/regolith/common/config.d/30_navigation
INSTALL=$PWD/debian/regolith-wm-navigation.install
CONTROL=$PWD/debian/control
status=0
fail() { echo "FAIL: $*"; status=1; }
pass() { echo "ok: $*"; }

for resource in ws_next ws_next2 ws_next_on_output ws_next_on_output2 \
    ws_prev ws_prev2 ws_prev_on_output ws_prev_on_output2; do
    s=${resource#ws_}
    s=${s%2}
    line=$(grep -E "^bindsym .*\\\$wm\\.binding\\.$resource " "$NAVIGATION" || true)
    if [[ $line == *" nop regolith-workspace-step $s" ]]; then
        pass "$resource is reported to the helper as $s"
    else
        fail "$resource: $line"
    fi
done
n=$(grep -cx 'exec_always --no-startup-id regolith-workspace-step --serve' "$NAVIGATION" || true)
if [ "$n" = 1 ]; then
    pass "one exec_always line starts the helper"
else
    fail "expected one exec_always line, found $n"
fi
if grep -qx 'scripts/regolith-workspace-step usr/bin' "$INSTALL"; then
    pass "regolith-wm-navigation ships the helper"
else
    fail "regolith-wm-navigation does not ship the helper"
fi
depends=$(awk '/^Package: regolith-wm-navigation$/ {p = 1} p && /^$/ {exit} p' "$CONTROL")
for package in python3 python3-i3ipc python3-xlib; do
    if grep -qE "^ +$package,?\$" <<< "$depends"; then
        pass "regolith-wm-navigation depends on $package"
    else
        fail "regolith-wm-navigation does not depend on $package"
    fi
done

PYTHONDONTWRITEBYTECODE=1 python3 - "$HELPER" <<'PY' || status=1
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("step", sys.argv[1])
spec = importlib.util.spec_from_loader("step", loader)
step = importlib.util.module_from_spec(spec)
loader.exec_module(step)
bad = 0


def check(desc, got, want):
    global bad
    if got == want:
        print(f"ok: {desc}")
    else:
        print(f"FAIL: {desc}: got {got!r}, want {want!r}")
        bad = 1


for value in ("", "yes", "true", "off", "0", "nowrap", "falsehood", " YES ", "n o"):
    check(f"{value!r} wraps", step.wraps(value), True)
for value in ("no", "false", " No ", "FALSE", "\tFaLsE\n"):
    check(f"{value!r} stops", step.wraps(value), False)

# The X resource database as set_from_resource reads it: quotes are part of
# the value, wildcards match, the class does not stand in for the name.
for resources, value in (
        ('wm.workspace.wrap: no\n', "no"),
        ('wm.workspace.wrap:\t  No  \n', "No"),
        ('wm.workspace.wrap: "no"\n', '"no"'),
        ('wm.workspace.wrap: "false"\n', '"false"'),
        ("wm.workspace.wrap: 'no'\n", "'no'"),
        ('*.workspace.wrap: false\n', "false"),
        ('wm*wrap: no\n', "no"),
        ('Wm.Workspace.Wrap: no\n', ""),
        ('wm.workspace.other: no\n', ""),
        ('', "")):
    check(f"X resources {resources!r}", step.x_resource(resources), value)
for value in ('"no"', '"false"', "'no'", '""'):
    check(f"{value!r} wraps", step.wraps(value), True)


def workspaces(focused, *specs):
    """specs: (name, num, output)"""
    return [{"id": i, "name": name, "num": num, "output": output,
             "focused": name == focused}
            for i, (name, num, output) in enumerate(specs)]


def want(name):
    return None if name is None else f'workspace --no-auto-back-and-forth "{name}"'


# Numbered by number (ties in reported order), then the rest in reported
# order; the on-output keys keep the reported order of the focused output.
layout = (("web", -1, "A"), ("2:b", 2, "A"), ("-1", -1, "A"), ("0", 0, "B"),
          ("1", 1, "B"), ("2:a", 2, "B"), ("mail", -1, "B"))
order = ["0", "1", "2:b", "2:a", "web", "-1", "mail"]
for i, name in enumerate(order):
    wss = workspaces(name, *layout)
    for sway in (False, True):
        wm = "sway" if sway else "i3"
        check(f"{wm} prev from {name}", step.stop_command(wss, "prev", sway),
              want(order[i - 1] if i > 0 else None))
        check(f"{wm} next from {name}", step.stop_command(wss, "next", sway),
              want(order[i + 1] if i + 1 < len(order) else None))
for focused, direction, target in (
        ("0", "next_on_output", "1"), ("0", "prev_on_output", None),
        ("mail", "next_on_output", None), ("mail", "prev_on_output", "2:a"),
        ("web", "prev_on_output", None), ("web", "next_on_output", "2:b"),
        ("-1", "next_on_output", None), ("2:b", "prev_on_output", "web")):
    check(f"{direction} from {focused}",
          step.stop_command(workspaces(focused, *layout), direction, False), want(target))
for direction in ("next_on_output", "prev_on_output"):
    check(f"{direction} on an output's only workspace",
          step.stop_command(workspaces("only", ("only", -1, "A"), ("1", 1, "B")),
                            direction, False), None)
for direction in step.DIRECTIONS:
    check(f"{direction} without a focused workspace",
          step.stop_command(workspaces(None, ("1", 1, "A"), ("2", 2, "A")), direction, False), None)
check("a missing number counts as unnumbered",
      step.stop_command([{"name": "x", "output": "A", "focused": True},
                         {"name": "3", "num": 3, "output": "A"}], "prev", False), want("3"))

# Quoting. i3: \ and " escaped by a backslash. sway: backslashes kept, double
# quotes in single quotes, $ doubled unless it follows a single backslash.
for name, i3, sway in (
        ('say "hi"', r'"say \"hi\""', '"say "\'"\'"hi"\'"\''),
        ("it's $mod $$ws1", '"it\'s $mod $$ws1"', '"it\'s $$mod $$$$ws1"'),
        (r"back\slash a;b, c", r'"back\\slash a;b, c"', r'"back\slash a;b, c"'),
        (r'x\"y', r'"x\\\"y"', r'"x\"y"'),
        (r"x\$mod", r'"x\\$mod"', r'"x\$mod"'),
        (r"x\\$mod", r'"x\\\\$mod"', r'"x\\$$mod"'),
        ("<span foreground='#95E6CB'>α 日本</span>",
         "\"<span foreground='#95E6CB'>α 日本</span>\"",
         "\"<span foreground='#95E6CB'>α 日本</span>\"")):
    check(f"i3 quotes {name!r}", step.quote_name(name, False), i3)
    check(f"sway quotes {name!r}", step.quote_name(name, True), sway)

# Names sway's workspace command reads as keywords: the output of a visible
# workspace, else the container a hidden one would focus.
tree = {"id": 1, "nodes": [{"id": 2, "name": "A", "nodes": [
    {"id": 10, "type": "workspace", "name": "1", "focus": [], "nodes": []},
    {"id": 11, "type": "workspace", "name": "Gaps", "focus": [21, 20],
     "nodes": [{"id": 20, "nodes": []},
               {"id": 21, "focus": [23, 22],
                "nodes": [{"id": 22, "nodes": []}, {"id": 23, "nodes": []}]}],
     "floating_nodes": []},
    {"id": 12, "type": "workspace", "name": "--no-auto-back-and-forth",
     "focus": [30], "nodes": [], "floating_nodes": [{"id": 30, "nodes": []}]}]},
    {"id": 3, "name": "B", "nodes": [
        {"id": 13, "type": "workspace", "name": "OUTPUT", "focus": [], "nodes": []}]}]}
kw = [{"id": 10, "name": "1", "num": 1, "output": "A", "focused": True, "visible": True},
      {"id": 11, "name": "Gaps", "num": -1, "output": "A", "visible": False},
      {"id": 12, "name": "--no-auto-back-and-forth", "num": -1, "output": "A", "visible": False},
      {"id": 13, "name": "OUTPUT", "num": -1, "output": "B", "visible": True}]
for focused, direction, sway, want_command in (
        ("1", "next", True, "[con_id=23] focus"),
        ("Gaps", "next", True, "[con_id=30] focus"),
        ("--no-auto-back-and-forth", "next", True, 'focus output "B"'),
        ("OUTPUT", "prev", True, "[con_id=30] focus"),
        ("1", "next", False, 'workspace --no-auto-back-and-forth "Gaps"'),
        ("--no-auto-back-and-forth", "next", False,
         'workspace --no-auto-back-and-forth "OUTPUT"')):
    wss = [dict(w, focused=w["name"] == focused) for w in kw]
    check(f"{'sway' if sway else 'i3'} {direction} from {focused!r}",
          step.stop_command(wss, direction, sway, lambda: tree), want_command)


# Only the eight nop bindings count as presses.
for command, direction in (
        ("nop regolith-workspace-step next", "next"),
        ("nop  regolith-workspace-step   prev_on_output ", "prev_on_output"),
        ("NOP regolith-workspace-step prev", "prev"),
        ("nop regolith-workspace-step", None),
        ("nop regolith-workspace-step sideways", None),
        ("exec regolith-workspace-step next", None),
        ("workspace next", None), ("", None), (None, None)):
    check(f"binding {command!r}", step.binding_direction(command), direction)


# A press: the native command, or the stop command, or nothing at an end.
class Reply:
    success, error = True, None


class Conn:
    def __init__(self, wss):
        self.wss, self.commands = wss, []

    def get_workspaces(self):
        return [type("W", (), {"ipc_data": w}) for w in self.wss]

    def command(self, command):
        self.commands.append(command)
        return [Reply()]


for value, focused, direction, sent in (
        ("", "3", "next", ["workspace next"]),
        (" yes ", "1", "prev_on_output", ["workspace prev_on_output"]),
        ("no", "3", "next", []),
        ("False", "3", "prev", ['workspace --no-auto-back-and-forth "2"']),
        ("no", "1", "prev_on_output", [])):
    for sway in (False, True):
        conn = Conn(workspaces(focused, ("1", 1, "A"), ("2", 2, "A"), ("3", 3, "A")))
        resources = type("R", (), {"read": lambda self, value=value: value})()
        step.step(conn, direction, sway, resources)
        check(f"{'sway' if sway else 'i3'} {direction} from {focused} with {value!r}",
              conn.commands, sent)

sys.exit(bad)
PY

exit $status
