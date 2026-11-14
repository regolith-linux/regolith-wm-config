#!/bin/bash
# Run regolith-terminal-cwd against stand-ins for swaymsg, i3-msg and xdotool
# that report a "focused window" whose process is a real process with shell
# children in known directories, and check the directory the command starts
# in. Also check that 15_base_launchers keeps "home" as the default.
# Run from the top of the source tree (debian/rules runs it at build time).
set -eu

SCRIPTS=$PWD/scripts
PARTIAL=$PWD/usr/share/regolith/common/config.d/15_base_launchers
WORK=$(mktemp -d)
pids=()
cleanup() { kill "${pids[@]}" 2> /dev/null || :; rm -rf "$WORK"; }
trap cleanup EXIT
status=0
fail() { echo "FAIL: $*"; status=1; }
pass() { echo "ok: $*"; }

BASH_BIN=$(readlink -f "$(command -v bash)")
grep -qx "$BASH_BIN" /etc/shells || grep -qx "$(command -v bash)" /etc/shells || {
  echo "skip: bash is not in /etc/shells here"; exit 0; }

mkdir -p "$WORK/bin" "$WORK/home/src" "$WORK/a" "$WORK/b"
# swaymsg/i3-msg: print $STUB_TREE; xdotool getwindowpid: print $STUB_PID
printf '#!/bin/sh\nprintf "%%s\\n" "$STUB_TREE"\n' > "$WORK/bin/swaymsg"
cp "$WORK/bin/swaymsg" "$WORK/bin/i3-msg"
printf '#!/bin/sh\n[ "$1" = getwindowpid ] && [ "$2" = 4242 ] && echo "$STUB_PID"\n' > "$WORK/bin/xdotool"
chmod +x "$WORK/bin/"*
export PATH="$SCRIPTS:$WORK/bin:$PATH" HOME=$WORK/home

# terminal <dir>...: start a stand-in terminal process with one shell child
# per directory ("-" for a child that is not a shell); sets $term
terminal() {
  local script=''
  for d in "$@"; do
    if [ "$d" = - ]; then script+="sleep 60 & "
    else script+="(cd '$d' && exec bash -c 'sleep 60; :') & "; fi
  done
  sh -c "${script}wait" &
  term=$!
  pids+=("$term")
  for _ in $(seq 50); do
    [ "$(pgrep -P "$term" | wc -l)" -ge $# ] && break
    sleep 0.1
  done
  sleep 0.2
}

sway_tree() { # <pid> <title>
  STUB_TREE=$(jq -cn --argjson pid "$1" --arg name "$2" \
    '{type:"root",focused:false,nodes:[{type:"workspace",name:"1",focused:false,nodes:[{type:"con",focused:true,pid:$pid,name:$name}]}]}')
  export STUB_TREE SWAYSOCK=/nonexistent
}

# check <description> <expected dir> <mode>: run the helper from /
check() {
  local got
  got=$(cd / && regolith-terminal-cwd "$3" sh -c pwd 2>&1) || :
  [ "$got" = "$2" ] && pass "$1" || fail "$1: started in '$got', expected '$2'"
}

terminal "$WORK/a"
sway_tree "$term" "Alacritty"
check "sway: one shell, its directory" "$WORK/a" focused
check "sway: mode home keeps the old behaviour" "/" home

terminal "$WORK/a" "$WORK/b"
sway_tree "$term" "user@host: $WORK/b"
check "sway: two shells, the one the title names" "$WORK/b" focused
sway_tree "$term" "Terminal"
check "sway: two shells and a title that names neither, home" "$WORK/home" focused
sway_tree "$term" "user@host: $WORK"
check "sway: a title naming a parent directory doesn't match" "$WORK/home" focused

terminal "$WORK/home/src" "$WORK/a"
sway_tree "$term" "user@host: ~/src"
check "sway: a title with ~ for the home directory" "$WORK/home/src" focused
terminal "$WORK/home" "$WORK/a"
sway_tree "$term" "user@host: ~"
check "sway: a title showing ~ alone" "$WORK/home" focused

terminal "$WORK/a" "$WORK/a"
sway_tree "$term" "Terminal"
check "sway: two shells in the same directory" "$WORK/a" focused

terminal -
sway_tree "$term" "Firefox"
check "sway: a window without a shell, home" "$WORK/home" focused

export STUB_TREE='{"type":"root","focused":false,"nodes":[{"type":"workspace","name":"1","focused":true,"nodes":[]}]}'
check "sway: an empty workspace, home" "$WORK/home" focused

# i3: the tree has the X window, xdotool gives its process
unset SWAYSOCK
terminal "$WORK/b"
STUB_PID=$term
STUB_TREE=$(jq -cn '{type:"root",focused:false,nodes:[{type:"con",focused:true,window:4242,name:"xterm"}]}')
export STUB_PID STUB_TREE
check "i3: one shell, its directory" "$WORK/b" focused
check "i3: mode home keeps the old behaviour" "/" home
export STUB_PID=999999999
check "i3: the window's process is gone, home" "$WORK/home" focused

got=$(cd / && regolith-terminal-cwd sh -c 'echo "$0 $1"' x y)
[ "$got" = "x y" ] && pass "without a mode, the command runs unchanged" || fail "no mode: got '$got'"

if grep -qxF 'set_from_resource $wm.terminal.cwd wm.terminal.cwd home' "$PARTIAL" &&
   grep -qxF 'bindsym $mod+$wm.binding.terminal exec --no-startup-id regolith-terminal-cwd $wm.terminal.cwd systemd-run --user --scope $wm.program.terminal' "$PARTIAL"; then
  pass "15_base_launchers defaults to home and keeps systemd-run and \$wm.program.terminal"
else
  fail "15_base_launchers: unexpected terminal binding"
fi

exit $status
