#!/bin/bash
# Check the parts of regolith-frozen-screenshot that need no display: which
# windows are offered and in what order, the drag rectangle, cutting the
# frozen pictures at one picture pixel per monitor pixel, the Pictures folder
# and the file names. Run from the top of the source tree (debian/rules runs
# it at build time).
set -eu

WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK"; rm -rf "$WORK"' EXIT

HOME=$WORK/home XDG_CONFIG_HOME='' TZ=UTC python3 - "$PWD/scripts/regolith-frozen-screenshot" "$WORK" <<'PY'
import importlib.machinery
import importlib.util
import io
import os
import sys
import types

import cairo

loader = importlib.machinery.SourceFileLoader("picker", sys.argv[1])
spec = importlib.util.spec_from_loader("picker", loader)
picker = importlib.util.module_from_spec(spec)
loader.exec_module(picker)
work = sys.argv[2]
failed = 0


def check(description, got, want):
    global failed
    if got == want:
        print("ok   " + description)
    else:
        print("FAIL %s: got %r, expected %r" % (description, got, want), file=sys.stderr)
        failed = 1


# -- the windows offered -------------------------------------------------------

def win(id, x, y, w, h, title=1, focused=False, **extra):
    """A window: rect is the frame, window_rect the drawing area in it."""
    node = {"id": id, "type": "con", "window": id, "nodes": [], "floating_nodes": [],
            "rect": {"x": x, "y": y, "width": w, "height": h},
            "window_rect": {"x": 1, "y": title, "width": w - 2, "height": h - title - 1},
            "focused": focused}
    node.update(extra)
    return node


def con(id, layout, children, focus=None, x=0, y=0, w=0, h=0):
    return {"id": id, "type": "con", "layout": layout, "nodes": children,
            "floating_nodes": [], "focus": focus or [c["id"] for c in children],
            "rect": {"x": x, "y": y, "width": w, "height": h}}


def floating(id, x, y, w, h, **extra):
    inner = win(id + 1, x, y, w, h, **extra)
    return {"id": id, "type": "floating_con", "nodes": [inner], "floating_nodes": [],
            "rect": {"x": x, "y": y, "width": w, "height": h}}


def ws(name, nodes, floats=(), output="L"):
    return {"id": hash(name) & 0xffff, "type": "workspace", "name": name, "output": output,
            "nodes": nodes, "floating_nodes": list(floats), "rect": {}}


def tree(*workspaces):
    return {"id": 1, "type": "root", "nodes": [
        {"id": 2, "type": "output", "name": "all", "nodes": [
            {"id": 3, "type": "con", "name": "content", "nodes": list(workspaces)}]}]}


def offered(t, showing):
    return [w.id for w in picker.offered_windows(
        t, [{"name": n, "visible": True} for n in showing])]


# Left monitor 0..1000: tiled 10 and 11 side by side, a tabbed container with
# 21 in front of 20 below them, floating 31 over part of 10 and floating 41
# completely over 11. Right monitor 1000..2000: 50 and 51 stacked, 51 in
# front. A workspace that isn't showing and the scratchpad hold more.
t = tree(
    ws("1", [con(5, "splith", [win(10, 0, 0, 500, 400), win(11, 500, 0, 500, 400, focused=True)]),
             con(6, "tabbed", [win(20, 0, 400, 1000, 400), win(21, 0, 400, 1000, 400)],
                 focus=[21, 20])],
       floats=[floating(30, 100, 100, 200, 100), floating(40, 480, -10, 540, 430)]),
    ws("2", [con(7, "stacked", [win(50, 1000, 0, 1000, 800), win(51, 1000, 0, 1000, 800)],
                 focus=[51, 50])], output="R"),
    ws("3", [win(60, 0, 0, 1000, 800)]),
    ws("__i3_scratch", [], floats=[floating(70, 10, 10, 100, 100)]))
check("offered: partly covered and floating windows, the front tab, in reading order",
      offered(t, ["1", "2"]), [41, 10, 51, 31, 21])

# Same top edge: left edge first; same top and left edge: container number
t = tree(ws("1", [win(12, 600, 0, 400, 400), win(11, 0, 0, 600, 400), win(9, 0, 0, 600, 400)]))
check("offered: ties broken by left edge, then container number",
      offered(t, ["1"]), [9, 11, 12])

# A full-screen window covers the others on its workspace only
t = tree(ws("1", [win(10, 0, 0, 500, 800), win(11, 500, 0, 500, 800, fullscreen_mode=1)],
            floats=[floating(30, 100, 100, 200, 100)]),
         ws("2", [win(50, 1000, 0, 1000, 800)], output="R"))
check("offered: a full-screen window hides the rest of its workspace",
      offered(t, ["1", "2"]), [11, 50])

# Full screen over every monitor hides everything else
t = tree(ws("1", [win(10, 0, 0, 1000, 800, fullscreen_mode=2)]),
         ws("2", [win(50, 1000, 0, 1000, 800)], output="R"))
check("offered: a window full screen on all monitors hides every other window",
      offered(t, ["1", "2"]), [10])

# A floating window completely under a later (higher) floating window
t = tree(ws("1", [win(10, 0, 0, 1000, 800)],
            floats=[floating(30, 100, 100, 200, 100), floating(40, 50, 50, 400, 300)]))
check("offered: a floating window completely under another floating window is not",
      offered(t, ["1"]), [10, 41])

check("offered: nothing on an empty workspace", offered(tree(ws("1", [])), ["1"]), [])

# The drawing area excludes borders and title bar
w = picker.Window(win(10, 100, 50, 300, 200, title=20), [])
check("drawing area: the window_rect inside the frame",
      (w.content.x, w.content.y, w.content.width, w.content.height), (101, 70, 298, 179))

# -- the drag rectangle ----------------------------------------------------------

screen = types.SimpleNamespace(sources=[picker.Output("L", picker.Rect(0, 0, 1000, 800)),
                                        picker.Output("R", picker.Rect(1000, 0, 500, 400), 2.0)])


def drag(press, release):
    state = types.SimpleNamespace(sources=screen.sources, press=press)
    r = picker.Picker.drag_rect(state, release)
    return (r.x, r.y, r.width, r.height)


check("drag: both ends included, any direction", drag((10, 20), (5, 40)), (5, 20, 6, 21))
check("drag: kept inside the screen", drag((990, 790), (1600, 900)), (990, 790, 510, 10))

# -- cutting the frozen pictures ---------------------------------------------------


def flat(width, height, rgb):
    surface = cairo.ImageSurface(cairo.FORMAT_RGB24, width, height)
    cr = cairo.Context(surface)
    cr.set_source_rgb(*rgb)
    cr.paint()
    return surface


def png_info(data):
    surface = cairo.ImageSurface.create_from_png(io.BytesIO(data))
    stride, raw = surface.get_stride(), surface.get_data()
    px = lambda x, y: tuple(raw[y * stride + x * 4 + i] for i in (2, 1, 0))
    w, h = surface.get_width(), surface.get_height()
    return (w, h), px(0, 0), px(w - 1, h - 1)


left = picker.Output("L", picker.Rect(0, 0, 100, 50))
left.surface = flat(100, 50, (1, 0, 0))
right = picker.Output("R", picker.Rect(100, 0, 50, 25), 2.0)
right.surface = flat(100, 50, (0, 0, 1))
sources = [left, right]
check("crop: a monitor at scale 1 gives its own size",
      png_info(picker.crop(sources, picker.Rect(10, 10, 30, 20))),
      ((30, 20), (255, 0, 0), (255, 0, 0)))
check("crop: a monitor at scale 2 gives twice the size, one pixel per monitor pixel",
      png_info(picker.crop(sources, picker.Rect(110, 5, 20, 10))),
      ((40, 20), (0, 0, 255), (0, 0, 255)))
check("crop: the whole monitor at scale 2",
      png_info(picker.crop(sources, right)), ((100, 50), (0, 0, 255), (0, 0, 255)))

# -- the Pictures folder and file names ------------------------------------------------

home = os.environ["HOME"]
config = os.path.join(home, ".config")
os.makedirs(config)


def folder(user_dirs):
    path = os.path.join(config, "user-dirs.dirs")
    if user_dirs is None:
        if os.path.exists(path):
            os.unlink(path)
    else:
        with open(path, "w") as handle:
            handle.write(user_dirs)
    return picker.pictures_folder()


check("folder: ~/Pictures without user-dirs.dirs", folder(None), home + "/Pictures")
check("folder: XDG_PICTURES_DIR under $HOME, with a space",
      folder('# comment\nXDG_PICTURES_DIR="$HOME/My Pictures"\n'), home + "/My Pictures")
check("folder: an absolute XDG_PICTURES_DIR, escapes removed",
      folder('XDG_PICTURES_DIR="/srv/shots \\"x\\""\n'), '/srv/shots "x"')
check("folder: other entries ignored",
      folder('XDG_DESKTOP_DIR="$HOME/Desktop"\n'), home + "/Pictures")

picker.PRESSED = 1767268800.0  # 2026-01-01 12:00:00 UTC
shots = os.path.join(work, "new folder", "shots")
names = [picker.save(shots, b"png %d" % i) for i in range(3)]
check("save: named after the key press; -2, -3 when taken; folder made", names,
      ["Screenshot from 2026-01-01 12-00-00.png", "Screenshot from 2026-01-01 12-00-00-2.png",
       "Screenshot from 2026-01-01 12-00-00-3.png"])
with open(os.path.join(shots, names[0]), "rb") as handle:
    check("save: an earlier picture is never overwritten", handle.read(), b"png 0")
check("save: no partial file left", sorted(os.listdir(shots)), sorted(names))
if os.geteuid() == 0:
    print("skip save: an unwritable folder (running as root)")
else:
    os.chmod(shots, 0o555)
    try:
        picker.save(shots, b"x")
        check("save: an unwritable folder fails", "saved", "PermissionError")
    except PermissionError:
        check("save: an unwritable folder fails", "PermissionError", "PermissionError")
    check("save: nothing written in an unwritable folder", sorted(os.listdir(shots)),
          sorted(names))

sys.exit(failed)
PY
