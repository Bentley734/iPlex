#!/bin/sh
# All paths are positional arguments, never interpolated shell source.
set -u
pid="$1"; target="$2"; next="$3"; backup="$4"; log="$5"; ack="$6"
opener="${7:-/usr/bin/open}"; timeout="${8:-30}"
exec >>"$log" 2>&1
stage="${next%/*}"
trap '/bin/rm -f "$0"' EXIT
case "${stage##*/}" in .iPlex-update-?*) ;; *) exit 1 ;; esac
[ "${stage%/*}" = "${target%/*}" ] && [ "$next" = "$stage/Candidate.app" ] &&
  [ "$backup" = "$stage/Previous.app" ] && [ -d "$stage" ] && [ ! -L "$stage" ] &&
  [ -d "$next" ] && [ ! -L "$next" ] && [ ! -e "$backup" ] && [ ! -L "$backup" ] || exit 1

finish() {
  /bin/rm -f "$ack" "$ack.pid"
  /bin/rmdir "$stage" 2>/dev/null || true
}

tries=0
while kill -0 "$pid" 2>/dev/null; do
  tries=$((tries + 1)); [ "$tries" -gt 60 ] && exit 1
  sleep 1
done
/bin/mv "$target" "$backup" || exit 1
replacement_installed=false
if /bin/mv "$next" "$target"; then
  replacement_installed=true
fi
if [ "$replacement_installed" = true ] && "$opener" -n "$target" --args --update-ack "$ack"; then
  tries=0
  while [ "$tries" -lt "$timeout" ]; do
    if [ -f "$ack" ]; then
      if /bin/rm -rf "$backup"; then
        echo 'Update opened successfully. Previous app removed.'
      else
        echo 'Update opened successfully. Could not remove the hidden rollback copy at:' "$backup"
      fi
      finish
      exit 0
    fi
    tries=$((tries + 1)); sleep 1
  done
fi
# A startup PID file permits stopping a failed launch before restoring its bundle.
if [ -f "$ack.pid" ]; then
  newpid="$(cat "$ack.pid")"
  case "$newpid" in ''|*[!0-9]*) ;; *) kill "$newpid" 2>/dev/null || true ;; esac
fi
if [ "$replacement_installed" = true ] && [ -e "$target" ]; then
  /bin/mv "$target" "$next" || exit 1
fi
[ ! -e "$target" ] && [ ! -L "$target" ] || exit 1
/bin/mv "$backup" "$target" || exit 1
/bin/rm -rf "$next"
finish
"$opener" -n "$target"
echo 'Update failed; restored the previous app.'
exit 1
