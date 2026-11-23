#!/bin/bash
# Run regolith-copy-from-screen against stand-ins for slurp, slop, grim,
# import, tesseract, zbarimg, wl-copy, xclip and notify-send, in the sway
# (WAYLAND_DISPLAY set) and the X11 mode, and check the calls it makes and
# what reaches the clipboard. Also check the keys in 80_copy_from_screen and
# the packaging. Run from the top of the source tree (debian/rules runs it at
# build time).
set -eu

HELPER=$PWD/scripts/regolith-copy-from-screen
PARTIAL=$PWD/usr/share/regolith/common/config.d/80_copy_from_screen
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
status=0
fail() { echo "FAIL: $*"; status=1; }
pass() { echo "ok: $*"; }

mkdir -p "$WORK/bin"

# Each stand-in logs its arguments to $STUB_LOG.
# slurp, slop: print $STUB_AREA ("x y w h"), or fail as a cancelled selection
for tool in slurp slop; do
  cat > "$WORK/bin/$tool" <<'STUB'
#!/bin/sh
echo "[${0##*/} $*]" >> "$STUB_LOG"
[ -n "${STUB_CANCEL-}" ] && exit 1
echo "$STUB_AREA"
STUB
done
# grim, import: a 2x2 PPM whose pixels are all $STUB_RGB (three bytes, octal)
for tool in grim import; do
  cat > "$WORK/bin/$tool" <<'STUB'
#!/bin/sh
echo "[${0##*/} $*]" >> "$STUB_LOG"
printf 'P6\n2 2\n255\n'
for _ in 1 2 3 4; do printf "$STUB_RGB"; done
STUB
done
# tesseract: list $STUB_LANGS, or print $STUB_OCR for an image on stdin
cat > "$WORK/bin/tesseract" <<'STUB'
#!/bin/sh
echo "[tesseract $*]" >> "$STUB_LOG"
if [ "$1" = --list-langs ]; then
  echo 'List of available languages in "/usr/share/tesseract-ocr/5/tessdata/" (2):'
  for l in $STUB_LANGS; do echo "$l"; done
  exit 0
fi
cat > /dev/null
printf "$STUB_OCR"
STUB
# zbarimg: $STUB_QR_COUNT symbols in the XML pass, the file $STUB_QR in the
# raw pass
cat > "$WORK/bin/zbarimg" <<'STUB'
#!/bin/sh
echo "[zbarimg $*]" >> "$STUB_LOG"
cat > /dev/null
case " $* " in
*" --xml "*)
  echo "<barcodes><source href='-'><index num='0'>"
  i=0
  while [ "$i" -lt "$STUB_QR_COUNT" ]; do
    echo "<symbol type='QR-Code'><data><![CDATA[<symbol>]]></data></symbol>"
    i=$((i + 1))
  done
  echo "</index></source></barcodes>"
  [ "$STUB_QR_COUNT" -gt 0 ] || exit 4 ;;
*) cat "$STUB_QR" ;;
esac
STUB
# wl-copy, xclip: keep stdin in $WORK/clip
for tool in wl-copy xclip; do
  cat > "$WORK/bin/$tool" <<'STUB'
#!/bin/sh
echo "[${0##*/} $*]" >> "$STUB_LOG"
cat > "$STUB_CLIP"
STUB
done
cat > "$WORK/bin/notify-send" <<'STUB'
#!/bin/sh
echo "[notify-send $*]" >> "$STUB_LOG"
STUB
chmod +x "$WORK/bin"/*

export STUB_LOG=$WORK/log STUB_CLIP=$WORK/clip STUB_QR=$WORK/qr
export STUB_AREA='10 20 300 40' STUB_RGB='\0\0\0' STUB_LANGS='eng deu'
export STUB_OCR='' STUB_QR_COUNT=0

# run DESCRIPTION SESSION(wayland|x11) ARGS...: run the helper with a fresh
# log and clipboard; the clipboard holds "untouched" until the helper sets it.
# PATH holds the stand-ins, except those named in $HIDE, and cat.
PYTHON=$(command -v python3)
run() {
  desc=$1 session=$2
  shift 2
  : > "$STUB_LOG"
  printf untouched > "$STUB_CLIP"
  rm -rf "$WORK/path"
  mkdir "$WORK/path"
  ln -s "$(command -v cat)" "$WORK/path/cat"
  for stub in "$WORK/bin"/*; do
    case " ${HIDE-} " in *" ${stub##*/} "*) ;; *) ln -s "$stub" "$WORK/path/" ;; esac
  done
  if [ "$session" = wayland ]; then
    env -u DISPLAY WAYLAND_DISPLAY=wayland-1 PATH="$WORK/path" \
      "$PYTHON" "$HELPER" "$@" || fail "$desc: exit status $?"
  else
    env -u WAYLAND_DISPLAY DISPLAY=:0 PATH="$WORK/path" \
      "$PYTHON" "$HELPER" "$@" || fail "$desc: exit status $?"
  fi
}
logged() { grep -qF -- "$2" "$STUB_LOG" && pass "$1" || fail "$1: no '$2' in: $(cat "$STUB_LOG")"; }
not_logged() { ! grep -qF -- "$2" "$STUB_LOG" && pass "$1" || fail "$1: '$2' in: $(cat "$STUB_LOG")"; }
clip_is() {
  if [ "$(od -An -c "$STUB_CLIP")" = "$(printf '%s' "$2" | od -An -c)" ]; then pass "$1"
  else fail "$1: clipboard holds '$(cat "$STUB_CLIP")', want '$2'"; fi
}

# Colour: a point (slurp -p, slop -t 0), the middle pixel, #rrggbb
STUB_RGB='\022\064\126' STUB_AREA='5 6 0 0' run "colour (sway)" wayland color
logged "sway colour: slurp picks a point" "[slurp -f %x %y %w %h -p]"
logged "sway colour: grim captures the point" "[grim -t ppm -g 5,6 1x1 -]"
logged "sway colour: wl-copy offers text" "[wl-copy --type text/plain;charset=utf-8]"
clip_is "sway colour: the clipboard holds #123456" "#123456"
logged "sway colour: the notification shows the value" "Colour copied #123456"
STUB_RGB='\377\200\001' STUB_AREA='7 8 1 1' run "colour (X11)" x11 color
logged "X11 colour: slop picks a point, without window selection" "[slop -f %x %y %w %h -t 0]"
logged "X11 colour: import captures the point" "-crop 1x1+7+8"
logged "X11 colour: xclip sets the CLIPBOARD as UTF8_STRING" "[xclip -selection clipboard -t UTF8_STRING]"
clip_is "X11 colour: the clipboard holds #ff8001" "#ff8001"

# Text: lines trimmed, empty lines dropped, no final newline
STUB_OCR='  Hello there  \n\n  second line \n\n' run "text (sway)" wayland text
logged "sway text: slurp drags an area" "[slurp -f %x %y %w %h]"
logged "sway text: grim captures the area" "[grim -t ppm -g 10,20 300x40 -]"
logged "sway text: tesseract reads English by default" "-l eng --psm 6"
clip_is "sway text: the clipboard holds the trimmed lines" "Hello there
second line"
logged "sway text: the notification quotes the first line" "Text copied Hello there"
STUB_OCR='Größe der Straße\n' run "text (X11, deu)" x11 text deu
logged "X11 text: tesseract reads the languages asked for" "-l deu --psm 6"
logged "X11 text: import captures the area" "-crop 300x40+10+20"
clip_is "X11 text: umlauts and ß survive" "Größe der Straße"
STUB_OCR='\n  \n' run "no text" wayland text
logged "no text: a notification says so" "No text found"
clip_is "no text: the clipboard is untouched" "untouched"
run "missing language" wayland text deu+fra
logged "missing language: the notification names the code" "not installed: fra"
not_logged "missing language: no selection is asked for" "[slurp"
clip_is "missing language: the clipboard is untouched" "untouched"
run "bad language list" x11 text 'eng;rm'
logged "bad language list: a notification says so" "not a tesseract language list"
not_logged "bad language list: tesseract never reads an image" "--psm"

# QR: the exact bytes; the content is never shown or passed as an argument
printf 'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP\nline 2\n' > "$STUB_QR"
STUB_QR_COUNT=1 run "QR (sway)" wayland qr
logged "sway QR: only QR codes are read" "-Sdisable -Sqrcode.enable"
clip_is "sway QR: the clipboard holds the exact content" "$(cat "$STUB_QR")
"
logged "sway QR: the notification says QR" "QR code copied"
not_logged "sway QR: the content appears in no argument" "JBSWY3DPEHPK3PXP"
printf '\377\376binary' > "$STUB_QR"
STUB_QR_COUNT=1 run "binary QR (X11)" x11 qr
logged "X11 QR: bytes that aren't UTF-8 are offered as binary" "[xclip -selection clipboard -t application/octet-stream]"
clip_is "X11 QR: the clipboard holds the exact bytes" "$(printf '\377\376binary')"
STUB_QR_COUNT=2 run "two QR codes" wayland qr
logged "two QR codes: a notification says so" "Several QR codes found"
clip_is "two QR codes: the clipboard is untouched" "untouched"
STUB_QR_COUNT=0 run "no QR code" x11 qr
logged "no QR code: a notification says so" "No QR code found"
clip_is "no QR code: the clipboard is untouched" "untouched"

# Cancelling does nothing
for mode in text qr color; do
  STUB_CANCEL=1 STUB_QR_COUNT=1 run "cancelled $mode" wayland $mode
  if grep -qE '^\[(notify-send|grim|wl-copy) ' "$STUB_LOG"; then
    fail "cancelled $mode: $(cat "$STUB_LOG")"
  else
    pass "cancelled $mode: no capture, copy or notification"
  fi
  clip_is "cancelled $mode: the clipboard is untouched" "untouched"
done

# A missing program disables only the key that needs it
HIDE=tesseract run "no tesseract" wayland text
logged "no tesseract: the notification names it" "tesseract was not found"
printf 'x' > "$STUB_QR"
HIDE=tesseract STUB_QR_COUNT=1 run "no tesseract, QR" wayland qr
clip_is "no tesseract: the QR key still works" "x"
HIDE=zbarimg run "no zbarimg" x11 qr
logged "no zbarimg: the notification names it" "zbarimg was not found"
HIDE=zbarimg STUB_OCR='still here' run "no zbarimg, text" x11 text
clip_is "no zbarimg: the text key still works" "still here"
HIDE=slurp run "no slurp" wayland color
logged "no slurp: the notification names it" "slurp was not found"
clip_is "no slurp: the clipboard is untouched" "untouched"

# The keys: $mod+$alt plus a letter from a resource, with viewer labels
for spec in "copy_text o text \$wm.ocr.languages" "copy_qr b qr" "copy_color c color"; do
  set -- $spec
  res=$1 key=$2
  shift 2
  if grep -qxF "set_from_resource \$wm.binding.$res wm.binding.$res $key" "$PARTIAL" &&
     grep -qxF "bindsym \$mod+\$alt+\$wm.binding.$res exec --no-startup-id regolith-copy-from-screen $*" "$PARTIAL"; then
    pass "wm.binding.$res defaults to $key and runs 'regolith-copy-from-screen $*'"
  else
    fail "$PARTIAL lacks the wm.binding.$res resource or binding"
  fi
  grep -qE "^## Session // Copy .* // <[^>]+><Alt> $key ##\$" "$PARTIAL" &&
    pass "the viewer lists <Super><Alt> $key" || fail "no viewer label for $key"
done
grep -qxF 'set_from_resource $wm.ocr.languages wm.ocr.languages eng' "$PARTIAL" &&
  pass "wm.ocr.languages defaults to eng" || fail "no wm.ocr.languages resource"

# Packaging: one package ships the partial and the helper, and both root
# configs recommend it
install=$PWD/debian/regolith-wm-copy-from-screen.install
grep -qxF usr/share/regolith/common/config.d/80_copy_from_screen "$install" &&
  grep -qxF 'scripts/regolith-copy-from-screen usr/bin' "$install" &&
  pass "regolith-wm-copy-from-screen ships the partial and the helper" ||
  fail "$install doesn't ship the partial and the helper"
for root in regolith-i3-root-config regolith-sway-root-config; do
  awk -v p="$root" '$1 == "Package:" {on = ($2 == p)} on' debian/control |
    grep -q 'regolith-wm-copy-from-screen' &&
    pass "$root recommends regolith-wm-copy-from-screen" ||
    fail "$root doesn't recommend regolith-wm-copy-from-screen"
done

exit $status
