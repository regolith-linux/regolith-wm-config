#!/bin/bash
# Check regolith-wm-display-keys:
# - the four Super keys have an Xresource, a default and a keybinding viewer
#   line, XF86Display switches the layout too, and every key runs a command
#   the helper accepts;
# - the install file ships the partial and the helper;
# - the helper rounds logical sizes half up, closes the gap a switched-off
#   panel leaves, adds it back at the right edge, steps scales within the
#   stated tolerance and shows them as whole percentages;
# - the switcher recognises the layout in force, skips what cannot be put in
#   place, and builds mirror, join, external only and built-in only;
# - mirror is offered when the service leaves supports-mirroring out and
#   skipped when it reports false, and a press whose mirror request is
#   refused (serial still current) moves on to the next layout, within three
#   attempts and one notification.
# Run from the top of the source tree (debian/rules runs it at build time).
set -eu

HELPER=$PWD/scripts/regolith-display-key
PARTIAL=$PWD/usr/share/regolith/common/config.d/66_display_keys
INSTALL=$PWD/debian/regolith-wm-display-keys.install
SUPER=$'\xef\x85\xba'  # U+F17A, the glyph the other viewer lines use
status=0
fail() { echo "FAIL: $*"; status=1; }
pass() { echo "ok: $*"; }

# resource, default, viewer action, viewer keys
expected='laptop_display Ctrl+d Toggle Laptop Display <Ctrl> d
display_scale_up Ctrl+equal Increase Display Scale <Ctrl> equal
display_scale_down Ctrl+minus Decrease Display Scale <Ctrl> minus
display_switch p Switch Display Layout p'

while read -r name default action; do
  key=${action##* }
  action=${action% *}
  case $action in
    *" <Ctrl>") key="<Ctrl> $key"; action=${action% *} ;;
    *) key=" $key" ;;
  esac
  line="set_from_resource \$wm.binding.$name wm.binding.$name $default"
  grep -qxF "$line" "$PARTIAL" && pass "$name defaults to $default" \
    || fail "$PARTIAL lacks: $line"
  grep -qE "^bindsym \\\$mod\+\\\$wm\.binding\.$name exec --no-startup-id regolith-display-key " "$PARTIAL" \
    && pass "$name is bound to \$mod+\$wm.binding.$name" \
    || fail "no binding for \$mod+\$wm.binding.$name"
  grep -qxF "## Modify // $action // <$SUPER>$key ##" "$PARTIAL" \
    && pass "$name has a keybinding viewer line" \
    || fail "no keybinding viewer line for $action"
done <<< "$expected"
grep -qxF 'bindsym XF86Display exec --no-startup-id regolith-display-key --persistent=$wm.display.persistent switch' "$PARTIAL" \
  && pass "XF86Display switches the layout" || fail "XF86Display is not bound to the switcher"
grep -qxF "## Modify // Switch Display Layout // XF86Display ##" "$PARTIAL" \
  && pass "XF86Display has a keybinding viewer line" \
  || fail "no keybinding viewer line for XF86Display"
grep -qxF 'set_from_resource $wm.display.persistent wm.display.persistent false' "$PARTIAL" \
  && pass "changes are temporary by default" \
  || fail "$PARTIAL does not default wm.display.persistent to false"

grep -qxF "usr/share/regolith/common/config.d/66_display_keys" "$INSTALL" \
  && pass "the partial is installed" || fail "$INSTALL lacks the partial"
grep -qxF "scripts/regolith-display-key usr/bin" "$INSTALL" \
  && pass "the helper is installed" || fail "$INSTALL lacks the helper"
[ -x "$HELPER" ] && pass "the helper is executable" || fail "$HELPER is not executable"

# Every command the partial runs, as the helper's arguments
commands=$(sed -n 's/.*exec --no-startup-id regolith-display-key \(.*\)$/\1/p' "$PARTIAL" \
  | sed 's/\$wm\.display\.persistent/false/')

PYTHONDONTWRITEBYTECODE=1 python3 - "$HELPER" "$commands" <<'PY' || status=1
import contextlib, importlib.machinery, importlib.util, io, sys
loader = importlib.machinery.SourceFileLoader("display_key", sys.argv[1])
spec = importlib.util.spec_from_loader("display_key", loader)
d = importlib.util.module_from_spec(spec)
loader.exec_module(d)
bad = 0
def check(desc, got, want):
    global bad
    if got == want:
        print("ok: " + desc)
    else:
        print("FAIL: %s: got %r, want %r" % (desc, got, want))
        bad = 1

def mode(name, width, height, scales, current=False, preferred=False):
    return (name, width, height, 60.0, 1.0, scales,
            {"is-current": current, "is-preferred": preferred})

def screen(name, modes, builtin=False):
    return ((name, "vendor", "product", name + "-serial"), modes,
            {"is-builtin": builtin})

def logical(x, y, scale, name, primary=False, transform=0):
    return (x, y, scale, transform, primary,
            [(name, "vendor", "product", name + "-serial")], {})

def state(logicals, layout_mode=1, global_scale=False, screens=None):
    screens = screens or [
        screen("A", [mode("1920x1080", 1920, 1080, [1.0, 1.25, 4 / 3, 2.0], True)]),
        screen("P", [mode("2560x1600", 2560, 1600, [1.0, 1.25, 2.0], True, True)],
               builtin=True),
        screen("B", [mode("1366x768", 1366, 768, [1.0, 1.25], True)]),
    ]
    return d.State((7, screens, logicals,
                    {"layout-mode": layout_mode,
                     "global-scale-required": global_scale}))

def layout(arrangement):
    return sorted((it.x, it.y, it.scale, it.primary, it.screens[0][0])
                  for it in arrangement)

for line in sys.argv[2].splitlines():
    with contextlib.redirect_stderr(io.StringIO()):
        args = d.parse_args(line.split())
    check("the helper accepts '%s'" % line,
          args.command in ("laptop-display", "scale", "switch"), True)
with contextlib.redirect_stderr(io.StringIO()):
    check("unknown commands are refused", d.main([d.PROG, "flip"]), 2)

s = state([logical(0, 0, 1.3333333730697632, "A", True),
           logical(1440, 0, 1.0, "P"), logical(4000, 0, 2.0, "B")])
check("1920 at 4/3 is 1440 wide, not 1439", s.size(s.logical[0]), (1440, 810))
check("1366 at 2 is 683 wide (halves round up)", s.size(s.logical[2]), (683, 384))
s.logical[0].transform = 1
check("a quarter turn swaps the sides", s.size(s.logical[0]), (810, 1440))
p = state([logical(0, 0, 2.0, "A", True)], layout_mode=2)
check("physical sizes ignore the scale", p.size(p.logical[0]), (1920, 1080))

s = state([logical(0, 0, 1.0, "A"), logical(1920, 0, 1.0, "P", True),
           logical(4480, 0, 1.0, "B")])
off = d.switch_off(s, s.screens[1])
check("the panel's gap closes and the primary moves to the left",
      layout(off.arrangement),
      [(0, 0, 1.0, True, "A"), (1920, 0, 1.0, False, "B")])

after = state([logical(it.x, it.y, it.scale, it.screens[0][0], it.primary)
               for it in off.arrangement])
on = d.switch_on(after, after.screens[1], off.memory)
check("switching back on restores the arrangement exactly",
      layout(on.arrangement), layout(s.logical))
moved = state([logical(0, 0, 1.25, "A", True), logical(1536, 0, 1.0, "B")])
on = d.switch_on(moved, moved.screens[1], off.memory)
check("after a change the panel comes back at the right edge",
      layout(on.arrangement),
      [(0, 0, 1.25, True, "A"), (1536, 0, 1.0, False, "B"),
       (2902, 0, 1.0, False, "P")])

g = state([logical(0, 0, 2.0, "A", True)], layout_mode=2, global_scale=True,
          screens=[screen("A", [mode("1920x1080", 1920, 1080, [1.0, 2.0], True)]),
                   screen("P", [mode("1366x768", 1366, 768, [1.0], True)],
                          builtin=True)])
on = d.switch_on(g, g.screens[1], None)
check("with a global scale every screen falls back to a common one",
      layout(on.arrangement),
      [(0, 0, 1.0, True, "A"), (1920, 0, 1.0, False, "P")])

d.focused_output = lambda: "A"
s = state([logical(0, 0, 1.00005, "A", True), logical(1920, 0, 1.0, "P")])
up = d.step_scale(s, True)
check("a scale step picks the next listed scale and moves the neighbour",
      layout(up.arrangement),
      [(0, 0, 1.25, True, "A"), (1536, 0, 1.0, False, "P")])
check("4/3 is shown as 133%", d.percent(1.3333333730697632), "133%")
check("percentages round half up", (d.percent(1.125), d.percent(1.5)),
      ("113%", "150%"))
top = d.step_scale(state([logical(0, 0, 2.0, "A", True)]), True)
check("the end of the list changes nothing", isinstance(top, d.Notice), True)
d.focused_output = lambda: "P"
check("a focused output on no active screen changes nothing",
      isinstance(d.step_scale(state([logical(0, 0, 1.0, "A", True)]), True),
                 d.Notice), True)

# Remembered values that lapsed: the mode first, then the scale.
lapsed = dict(off.memory, mode="gone", scale=1.25, transform=2)
moved = state([logical(0, 0, 1.25, "A", True), logical(1536, 0, 1.0, "B")])
on = d.switch_on(moved, moved.screens[1], lapsed)
check("a mode no longer listed gives way to the preferred one, keeping a "
      "scale it lists and the transform",
      [(it.screens, it.scale, it.transform) for it in on.arrangement][-1],
      ([("P", "2560x1600")], 1.25, 2))
on = d.switch_on(moved, moved.screens[1], dict(lapsed, scale=1.5))
check("a scale the mode no longer lists gives way to the preferred scale",
      on.arrangement[-1].scale, 1.0)

# The display switcher. P is the panel; A, B and P share 1920x1080.
def hd(name, builtin=False):
    return screen(name, [mode("1920x1080", 1920, 1080, [1.0, 1.25, 2.0], True, True)],
                  builtin)

def three(logicals, mirroring=True):
    properties = {"layout-mode": 1}
    if mirroring is not None:  # None: the property is left out
        properties["supports-mirroring"] = mirroring
    return d.State((7, [hd("A"), hd("P", True), hd("B")], logicals, properties))

def members(*names):
    return [(n, "vendor", "product", n + "-serial") for n in names]

def group(x, names, primary=False):
    return (x, 0, 1.0, 0, primary, members(*names), {})

def switched(s):
    with contextlib.redirect_stderr(io.StringIO()):
        d.lid_closed = lambda: False
        return d.display_switch(s)

def names(change):
    return [(it.x, it.primary, [n for n, _m in it.screens]) for it in change.arrangement]

joined = three([group(0, "P", True), group(1920, "A"), group(3840, "B")])
panel = joined.screens[1]
check("one monitor per screen is join",
      d.layout_in_force(joined, panel), d.JOIN)
check("join is followed by external only, in listed order",
      names(switched(joined)), [(0, True, ["A"]), (1920, False, ["B"])])
external = three([group(0, "A", True), group(1920, "B")])
check("the panel alone is built-in only after external only",
      names(switched(external)), [(0, True, ["P"])])
builtin = three([group(0, "P", True)])
check("built-in only wraps round to mirror",
      names(switched(builtin)), [(0, True, ["A", "P", "B"])])
mirror = three([(0, 0, 1.0, 0, True, members("A", "P", "B"), {})])
check("mirror is followed by join, the panel first",
      names(switched(mirror)),
      [(0, True, ["P"]), (1920, False, ["A"]), (3840, False, ["B"])])
check("with supports-mirroring false built-in only goes to join",
      names(switched(three([group(0, "P", True)], mirroring=False)))[0],
      (0, True, ["P"]))
check("without supports-mirroring (GNOME Flashback) built-in only goes to "
      "mirror", names(switched(three([group(0, "P", True)], mirroring=None))),
      [(0, True, ["A", "P", "B"])])
check("a missing supports-mirroring counts as supported",
      three([], mirroring=None).mirroring, True)
odd = three([group(0, "A", True)])
check("an unknown arrangement starts at the first possible layout",
      d.layout_in_force(odd, odd.screens[1]) is None
      and names(switched(odd)) == [(0, True, ["A", "P", "B"])], True)
nopanel = d.State((7, [hd("A"), hd("B")], [group(0, "A", True), group(1920, "B")],
                   {"layout-mode": 1, "supports-mirroring": False}))
check("with only join possible the arrangement stays",
      isinstance(switched(nopanel), d.Notice), True)
check("one screen changes nothing",
      isinstance(switched(d.State((7, [hd("A")], [group(0, "A", True)], {}))),
                 d.Notice), True)
fast = mode("1920x1080-75", 1920, 1080, [1.0], False)
fast = (fast[0], 1920, 1080, 75.0, 1.0, [1.0], fast[6])
plain = [hd("A"), screen("P", [mode("1920x1080-60", 1920, 1080, [1.0, 2.0]), fast,
                               mode("2560x1600", 2560, 1600, [1.0, 2.0], True, True)],
                         True)]
s = d.State((7, plain, [group(0, "P", True)], {"supports-mirroring": True}))
check("mirror takes the fastest mode of the shared size when none is preferred",
      switched(s).arrangement[0].screens, [("A", "1920x1080"), ("P", "1920x1080-75")])

def odd_scales(name, builtin=False, scales=(1.0, 1.25), preferred=1.0):
    return screen(name, [("1920x1080", 1920, 1080, 60.0, preferred, list(scales),
                          {"is-current": True, "is-preferred": True})], builtin)

s = d.State((7, [odd_scales("A", scales=[1.5]), odd_scales("P", True)],
             [group(0, "P", True)], {"supports-mirroring": True}))
check("mirror is passed over when no scale fits every chosen mode",
      names(switched(s)), [(0, True, ["P"]), (1920, False, ["A"])])
s = d.State((7, [odd_scales("A", scales=[2.0], preferred=2.0),
                 odd_scales("P", True, scales=[1.0, 2.0], preferred=2.0),
                 odd_scales("B", scales=[1.0])],
             [group(0, "P", True)], {"global-scale-required": True}))
check("join and external only are passed over without a shared scale",
      isinstance(switched(s), d.Notice), True)
s = d.State((7, [odd_scales("A"), odd_scales("P", True, scales=[1.0, 2.0],
                                               preferred=2.0)],
             [group(0, "A", True)], {"global-scale-required": True,
                                     "layout-mode": 2}))
built = switched(s)
check("built-in only keeps the panel's own scale under a global scale",
      [(it.scale, it.screens) for it in built.arrangement],
      [(2.0, [("P", "1920x1080")])])
with contextlib.redirect_stderr(io.StringIO()):
    d.lid_closed = lambda: True
    one = d.display_switch(d.State((7, [hd("A")], [group(0, "A", True)], {})))
    nopan = d.laptop_display(d.State((7, [hd("A"), hd("B")],
                                      [group(0, "A", True)], {})))
check("the lid is reported before the screen count",
      "lid" in (one.summary + one.body).lower(), True)
check("the lid is reported before a missing panel",
      "lid" in (nopan.summary + nopan.body).lower(), True)

# A press against a stand-in service: apply() answers from a script of
# outcomes, and the serial moves only on a stale refusal.
import types
d.gio()
GLib = d.GLib
d.Gio = types.SimpleNamespace(bus_get_sync=lambda *_a: object(),
                              BusType=d.Gio.BusType)
d.lid_closed = lambda: False

def press(make, outcomes, decide=d.display_switch):
    """make(serial) builds the service's state. outcomes, per apply call:
    None accepts, "stale" refuses with a new serial, any other text refuses
    with the serial unchanged."""
    serial = [7]
    applied, notices = [], []
    def apply(_bus, _serial, _method, arrangement):
        outcome = outcomes[len(applied)] if len(applied) < len(outcomes) else None
        applied.append([[n for n, _m in it.screens] for it in arrangement])
        if outcome == "stale":
            serial[0] += 1
        if outcome is not None:
            raise GLib.Error(outcome)
    d.current_state = lambda _bus: make(serial[0])
    d.apply_allowed = lambda _bus: True
    d.apply = apply
    d.notify = notices.append
    with contextlib.redirect_stderr(io.StringIO()):
        rc = d.run(decide, d.METHOD_TEMPORARY)
    return rc, applied, [(n.summary, n.body) for n in notices]

MIRRORED = [["A", "P", "B"]]
JOINED = [["P"], ["A"], ["B"]]

def flashback(serial):  # GNOME Flashback's properties, panel alone
    return d.State((serial, [hd("A"), hd("P", True), hd("B")],
                    [group(0, "P", True)],
                    {"layout-mode": 2, "global-scale-required": True}))

rc, applied, notices = press(flashback, ["Mirroring is not possible"])
check("a refused mirror moves on to join within the same press",
      (rc, applied), (0, [MIRRORED, JOINED]))
check("the fall-through shows one notification naming join and the refusal",
      notices, [("Display layout: join", "The display configuration service "
                 "refused mirror: Mirroring is not possible")])
check("the remote error name is left out of the message",
      d.error_text(GLib.Error("GDBus.Error:org.freedesktop.DBus.Error."
                              "InvalidArgs: mirroring is not supported")),
      "mirroring is not supported")
rc, applied, notices = press(flashback, ["no", "no"])
check("a refused join after a refused mirror is reported as refused",
      (rc, applied, [summary for summary, _b in notices]),
      (1, [MIRRORED, JOINED], ["Display change refused"]))
rc, applied, notices = press(flashback, ["stale", "stale", "no"])
check("stale retries and the mirror fall-through share three attempts",
      (rc, len(applied), [summary for summary, _b in notices]),
      (1, 3, ["Display change refused"]))
rc, applied, notices = press(flashback, ["stale", "no"])
check("after a stale retry a refused mirror still moves on to join",
      (rc, applied, len(notices)), (0, [MIRRORED, MIRRORED, JOINED], 1))

def no_panel(serial):  # only mirror and join are possible
    return d.State((serial, [hd("A"), hd("B")],
                    [group(0, "A", True), group(1920, "B")], {"layout-mode": 2}))

rc, applied, notices = press(no_panel, ["Mirroring is not possible"])
check("a refused mirror with only join left keeps the layout and says why",
      (rc, applied, [(summary, "refused mirror" in body)
                     for summary, body in notices]),
      (0, [[["A", "B"]]], [("Display layout unchanged", True)]))
rc, applied, notices = press(
    lambda serial: state([logical(0, 0, 1.0, "A"),
                          logical(1920, 0, 1.0, "P", True)]),
    ["no"], lambda st, _refused: d.laptop_display(st))
check("the other keys report a refusal at once",
      (rc, len(applied), [summary for summary, _b in notices]),
      (1, 1, ["Display change refused"]))
sys.exit(bad)
PY

exit $status
