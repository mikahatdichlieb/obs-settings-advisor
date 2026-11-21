#!/usr/bin/env bash
# find_obs_logs.sh - locate OBS Studio log files on macOS and Linux (read-only).
#
# Prints JSON with the searched locations and the newest 3 log files.
# Paths are printed with the home directory as "~" and the username as "$USER";
# analyze_obs_log.py expands both, so a printed path can be passed to it unchanged.
# "has_output_stats" tells whether a log contains a stopped stream/recording (needed for frame stats).
#
# Usage:  bash find_obs_logs.sh
# Exit:   0 = at least one log found, 1 = no logs found or unsupported OS

set -u
export LC_ALL=C

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,10p' "$0"
  exit 0
fi

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

# Hide personal parts of a path but keep it usable by analyze_obs_log.py.
redact_path() {
  local p=$1 u=${USER:-$(id -un 2>/dev/null)}
  # shellcheck disable=SC2088 # a literal ~ on purpose; analyze_obs_log.py expands it
  case "$p" in "$HOME"/*) p="~/${p#"$HOME"/}" ;; esac
  if [ ${#u} -ge 3 ]; then p=${p//\/$u\//\/\$USER\/}; fi
  printf '%s' "$p"
}

case "$(uname -s 2>/dev/null)" in
  Linux)
    OS=linux
    CANDIDATES="native|${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio/logs
flatpak|$HOME/.var/app/com.obsproject.Studio/config/obs-studio/logs
snap|$HOME/snap/obs-studio/current/.config/obs-studio/logs"
    mtime() { stat -c %Y "$1"; }
    fsize() { stat -c %s "$1"; }
    isodate() { date -d "@$1" '+%Y-%m-%dT%H:%M:%S'; }
    ;;
  Darwin)
    OS=macos
    CANDIDATES="native|$HOME/Library/Application Support/obs-studio/logs"
    mtime() { stat -f %m "$1"; }
    fsize() { stat -f %z "$1"; }
    isodate() { date -r "$1" '+%Y-%m-%dT%H:%M:%S'; }
    ;;
  *)
    echo "error: unsupported OS. Use find_obs_logs.ps1 on Windows." >&2
    exit 1
    ;;
esac

searched=""
listing="" # lines: mtime<TAB>kind<TAB>path
while IFS='|' read -r kind dir; do
  [ -n "$dir" ] || continue
  exists=false
  if [ -d "$dir" ]; then
    exists=true
    for f in "$dir"/*.txt; do
      [ -f "$f" ] || continue
      listing="${listing}$(mtime "$f")	${kind}	${f}
"
    done
  fi
  searched="${searched:+$searched,}{\"install_type\":\"$kind\",\"path\":\"$(json_escape "$(redact_path "$dir")")\",\"exists\":$exists}"
done <<EOF
$CANDIDATES
EOF

has_stats() { grep -qE "Output '[^']+': stopping|skipped frames due to encoding lag" "$1" 2>/dev/null && echo true || echo false; }

logs="" count=0 newest_with_stats="null"
while IFS='	' read -r ts kind path; do
  [ -n "$path" ] || continue
  stats=$(has_stats "$path")
  if [ $count -lt 3 ]; then
    logs="${logs:+$logs,
    }{\"path\":\"$(json_escape "$(redact_path "$path")")\",\"install_type\":\"$kind\",\"modified\":\"$(isodate "$ts")\",\"size_bytes\":$(fsize "$path"),\"has_output_stats\":$stats}"
  fi
  count=$((count + 1))
  if [ "$stats" = true ] && [ "$newest_with_stats" = "null" ]; then
    newest_with_stats="\"$(json_escape "$(redact_path "$path")")\""
  fi
  [ $count -ge 3 ] && [ "$newest_with_stats" != "null" ] && break
done <<EOF
$(printf '%s' "$listing" | sort -rn)
EOF

printf '{\n  "os": "%s",\n  "searched": [%s],\n  "logs": [\n    %s\n  ],\n  "newest_log_with_output_stats": %s\n}\n' \
  "$OS" "$searched" "$logs" "$newest_with_stats"

if [ $count -eq 0 ]; then
  echo "error: no OBS log files found. Start OBS once (Help > Log Files shows the folder) or ask the user for the log." >&2
  exit 1
fi
exit 0
