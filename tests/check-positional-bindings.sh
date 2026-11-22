#!/bin/bash
# Check regolith-wm-positional-bindings, the program both root configs list
# their partials with:
# - with wm.keyboard.positional_bindings unset or not "yes", it prints the
#   files of each folder as `include FOLDER/*` takes them; names with a blank
#   (which the include line splits) or a pattern character (which the
#   keybinding viewer expands) are printed as links, and names that are not
#   UTF-8 come out byte for byte;
# - with "yes", key bindings on characters of a US keyboard become the
#   bindcodes of their US keys, in i3's and in sway's way; other keys, mouse
#   bindings, bindcodes and options stay as written;
# - if the conversion fails, it falls back to the partials as written;
# - sway gets the list for the keybinding viewer;
# - the packaging ships the program and both root configs run it.
# Run from the top of the source tree (debian/rules runs it at build time).
# The config lines in single quotes are literal: their $ is not the shell's.
# shellcheck disable=SC2016
set -eu

HELPER=$PWD/scripts/regolith-wm-positional-bindings
INSTALL=$PWD/debian/install
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
status=0
fail() { echo "FAIL: $*"; status=1; }
pass() { echo "ok: $*"; }

export LC_ALL=C.UTF-8 HOME=$WORK/home XDG_RUNTIME_DIR=$WORK/run DISPLAY=:99
mkdir -p "$WORK/bin" "$XDG_RUNTIME_DIR" "$WORK/system" "$WORK/user"
# Stand-ins for xrdb -query (i3) and trawldb --query (sway).
for tool in xrdb trawldb; do
    printf '#!/bin/sh\ncat "%s/resources"\n' "$WORK" > "$WORK/bin/$tool"
    chmod +x "$WORK/bin/$tool"
done
export PATH=$WORK/bin:$PATH
resources() { printf '%s\n' "$@" > "$WORK/resources"; }

cat > "$WORK/root" <<'EOF'
set $mod Mod4
set_from_resource $wm.binding.fullscreen wm.binding.fullscreen f
EOF
cat > "$WORK/system/30_keys" <<'EOF'
## Navigate // Relative Window // <> k ##
bindsym $mod+k focus up
bindsym $mod+$wm.binding.fullscreen fullscreen toggle
bindsym $mod+Shift+q kill
bindsym $mod+Return exec terminal
bindsym $mod+eacute exec no-us-key
bindsym --release $mod+1 workspace number 1
bindcode $mod+38 exec keycode
bindsym button3 floating toggle
bindsym Group1+$mod+j focus down
mode "resize" {
    bindsym h resize shrink width 6 px
    bindsym Escape mode "default"
}
EOF
printf 'bindsym $mod+y exec other\n' > "$WORK/system/20_other"
printf 'exec true\n' > "$WORK/system/10_plain"
printf 'bindsym $mod+u exec user\n' > "$WORK/user/50_user"
printf 'exec true\n' > "$WORK/user/my keys"
printf 'exec true\n' > "$WORK/user/x*"
printf 'exec true\n' > "$WORK/user/$(printf 'caf\351')"
printf 'exec true\n' > "$WORK/user/.hidden"

run() { # run <i3|sway> [extra path]; output in $WORK/out, stderr in $WORK/err
    "$HELPER" "$1" "$WORK/root" "$WORK/system" "$WORK/missing" "$WORK/user" "${@:2}" \
        > "$WORK/out" 2> "$WORK/err"
}

# --- off -------------------------------------------------------------------
glob_list() { # what `include FOLDER/*` takes, one per line
    local f
    for f in "$WORK/system"/* "$WORK/user"/*; do printf '%s\n' "$f"; done
}
for value in "" "wm.keyboard.positional_bindings: no" "wm.keyboard.positional_bindings: Yes"; do
    resources "$value"
    for wm in i3 sway; do
        if ! run "$wm"; then fail "$wm [$value]: exit status"; continue; fi
        # the names the include line would split or expand come out as links
        # (read byte by byte: in a UTF-8 locale, bash before 5.3 takes the
        # newline after the name that is not UTF-8 into that line)
        resolved=$(LC_ALL=C; while IFS= read -r p; do
            case $p in "$XDG_RUNTIME_DIR"/*) readlink "$p" ;; *) printf '%s\n' "$p" ;; esac
        done < "$WORK/out")
        if [ "$resolved" = "$(glob_list)" ]; then pass "$wm [$value]: the partials as include FOLDER/* takes them"
        else fail "$wm [$value]: got $(cat "$WORK/out")"; fi
    done
done
if grep -q -e ' ' -e '\*' "$WORK/out"; then fail "a printed path has a blank or a pattern character"
else pass "names with a blank or a pattern character are printed as links"; fi
if grep -qa "$(printf 'caf\351')\$" "$WORK/out"; then pass "a name that is not UTF-8 is printed byte for byte"
else fail "the name that is not UTF-8 is missing"; fi
# As in a UTF-8 locale such as en_US.UTF-8, where Python's output is strict.
if PYTHONIOENCODING=utf-8:strict run i3 && [ -s "$WORK/out" ]; then pass "strict UTF-8 output: no failure on a name that is not UTF-8"
else fail "a name that is not UTF-8 fails with strict UTF-8 output: $(cat "$WORK/err")"; fi
run i3 "$WORK/root"
if [ "$(tail -1 "$WORK/out")" = "$WORK/root" ]; then pass "a file argument is printed as it is"
else fail "file argument: $(tail -1 "$WORK/out")"; fi
run sway
if [ "$(sed 's/^include //' "$XDG_RUNTIME_DIR/regolith-wm-positional-bindings/sway-partials")" = "$(cat "$WORK/out")" ]
then pass "sway: the keybinding viewer list includes the printed paths"
else fail "sway: keybinding viewer list differs from the printed paths"; fi

# --- on --------------------------------------------------------------------
converted() { # converted <name>: the copy printed for a partial
    grep -- "-$1\$" "$WORK/out" | head -1
}
expect() { # expect <wm> <file> <line>...
    local wm=$1 file=$2 line
    shift 2
    for line in "$@"; do
        if grep -qxF -- "$line" "$file"; then pass "$wm: $line"
        else fail "$wm: missing '$line' in $(cat "$file")"; fi
    done
}
resources "wm.keyboard.positional_bindings: yes" "wm.binding.fullscreen: g"
for wm in i3 sway; do
    run "$wm" || fail "$wm: exit status"
    copy=$(converted 30_keys)
    if [ -z "$copy" ]; then fail "$wm: 30_keys was not converted: $(cat "$WORK/out" "$WORK/err")"; continue; fi
    expect "$wm" "$copy" \
        '## Navigate // Relative Window // <> k ##' \
        'bindcode Mod4+45 focus up' \
        'bindcode Mod4+42 fullscreen toggle' \
        'bindcode Shift+Mod4+24 kill' \
        'bindsym $mod+Return exec terminal' \
        'bindsym $mod+eacute exec no-us-key' \
        'bindcode --release Mod4+10 workspace number 1' \
        'bindcode $mod+38 exec keycode' \
        'bindsym button3 floating toggle' \
        'bindcode Group1+Mod4+44 focus down' \
        '    bindcode 43 resize shrink width 6 px' \
        '    bindsym Escape mode "default"'
    expect "$wm" "$(converted 50_user)" 'bindcode Mod4+30 exec user'
    if grep -qx "$WORK/system/10_plain" "$WORK/out"; then pass "$wm: a partial with no key bindings is included as it is"
    else fail "$wm: 10_plain not printed as it is"; fi
done
# The shifted character: i3 grabs the key without Shift, sway runs it with Shift.
printf 'bindsym Mod4+question exec viewer\n' > "$WORK/user/60_question"
run i3; expect i3 "$(converted 60_question)" 'bindcode Mod4+61 exec viewer'
run sway; expect sway "$(converted 60_question)" 'bindcode Shift+Mod4+61 exec viewer'
printf 'bindsym --to-code Mod4+t exec to-code\n' > "$WORK/user/60_question"
run sway; expect sway "$(converted 60_question)" 'bindcode Mod4+28 exec to-code'
rm "$WORK/user/60_question"

# A conversion that fails falls back to the partials as written.
rm -rf "$XDG_RUNTIME_DIR/regolith-wm-positional-bindings/i3"
ln -s "$WORK" "$XDG_RUNTIME_DIR/regolith-wm-positional-bindings/i3"
run i3
if [ "$(head -1 "$WORK/out")" = "$WORK/system/10_plain" ] && grep -q "including partials as written" "$WORK/err" \
    && grep -qx "$WORK/system/30_keys" "$WORK/out"
then pass "a failed conversion falls back to the partials as written, with a warning"
else fail "failed conversion: $(cat "$WORK/out" "$WORK/err")"; fi

# --- packaging -------------------------------------------------------------
if grep -qxF 'scripts/regolith-wm-positional-bindings /usr/bin' "$INSTALL"
then pass "regolith-wm-config ships the program"
else fail "regolith-wm-config does not ship the program"; fi
for wm in i3 sway; do
    config=$PWD/etc/regolith/$wm/config
    if grep -q "^include \$(/usr/bin/regolith-wm-positional-bindings $wm /etc/regolith/$wm/config " "$config" \
        && ! grep -q '^include .*config\.d/\*' "$config"
    then pass "the $wm root config lists its partials through the program"
    else fail "the $wm root config does not list its partials through the program"; fi
    # The root config runs the program: it needs the regolith-wm-config that has it.
    stanza=$(awk -v p="Package: regolith-$wm-root-config" '$0 == p {s = 1} s && /^$/ {exit} s' \
        "$PWD/debian/control")
    if grep -qxF '  regolith-wm-config (= ${binary:Version}),' <<< "$stanza"
    then pass "regolith-$wm-root-config depends on regolith-wm-config of the same version"
    else fail "regolith-$wm-root-config misses the versioned dependency on regolith-wm-config"; fi
done
if grep -qxF 'include $XDG_RUNTIME_DIR/regolith-wm-positional-bindings/sway-partials' "$PWD/etc/regolith/sway/config"
then pass "the sway root config includes the keybinding viewer list"
else fail "the sway root config misses the keybinding viewer list"; fi

exit $status
