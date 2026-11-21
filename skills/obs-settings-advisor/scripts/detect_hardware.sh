#!/usr/bin/env bash
# detect_hardware.sh - read-only hardware detection for obs-settings-advisor (macOS and Linux).
#
# Prints one JSON object to stdout. Writes no files and changes no settings.
# Never prints usernames, hostnames, home paths, serial numbers, MAC or IP addresses.
# Every external tool is optional: missing tools produce null fields plus a "warnings" entry.
# Compatible with the bash 3.2 that ships with macOS.
#
# Usage:  bash detect_hardware.sh
# Exit:   0 = JSON printed (check "warnings"), 1 = unsupported OS or fatal error

set -u
export LC_ALL=C

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,10p' "$0"
  exit 0
fi

WARNINGS=()
warn() { WARNINGS+=("$1"); }
have() { command -v "$1" >/dev/null 2>&1; }
# a hung driver tool must not block the skill
run_t() { if have timeout; then timeout 10 "$@"; else "$@"; fi; }

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/ }
  s=${s//$'\r'/}
  s=${s//$'\n'/ }
  printf '%s' "$s"
}
jstr() { if [ -n "${1:-}" ]; then printf '"%s"' "$(json_escape "$1")"; else printf 'null'; fi; }
jnum() { case "${1:-}" in '' | *[!0-9.]* | .*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }
jbool() { case "${1:-}" in true) printf 'true' ;; false) printf 'false' ;; *) printf 'null' ;; esac; }
jcsv() { # "a,b,c" -> ["a","b","c"]; "" -> []
  local out="" x old_ifs=$IFS
  IFS=,
  # shellcheck disable=SC2086 # split on commas on purpose
  for x in $1; do [ -n "$x" ] && out="${out:+$out,}$(jstr "$x")"; done
  IFS=$old_ifs
  printf '[%s]' "$out"
}
trim() { local s=$1; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Prints "codecs|note". codecs: comma list, "" = no hardware encoder, "?" = unknown.
# Heuristic from the model name only; references/encoders.md has the full table.
infer_codecs() {
  local key
  key="$(lower "$1"):$(lower "$2")"
  case "$key" in
    nvidia:*"gt 1030"*) echo "|GT 1030 has no NVENC" ;;
    nvidia:*mx[0-9][0-9][0-9]* | nvidia:*"gt "[0-9][0-9][0-9]*) echo "?|many MX/GT models have no NVENC" ;;
    nvidia:*"rtx 50"[0-9][0-9]* | nvidia:*"rtx 40"[0-9][0-9]*) echo "h264,hevc,av1|" ;;
    nvidia:*"rtx 30"[0-9][0-9]* | nvidia:*"rtx 20"[0-9][0-9]* | nvidia:*"gtx 16"[0-9][0-9]*) echo "h264,hevc|" ;;
    nvidia:*"gtx 10"[5-8]0* | nvidia:*"gtx 9"[5-8]0*) echo "h264,hevc|older NVENC generation, lower quality per bit than RTX" ;;
    amd:*"rx 64"[0-9][0-9]* | amd:*"rx 65"[0-9][0-9]*) echo "|RX 6400/6500 (Navi 24) have no hardware encoder" ;;
    amd:*"rx 9"[0-9][0-9][0-9]* | amd:*"rx 7"[0-9][0-9][0-9]*) echo "h264,hevc,av1|" ;;
    amd:*"radeon 7"[0-9]0m* | amd:*"radeon 8"[0-9]0m* | amd:*"radeon 8"[0-9][0-9]0s*) echo "h264,hevc,av1|" ;;
    amd:*"rx 6"[0-9][0-9][0-9]* | amd:*"rx 5"[0-9][0-9][0-9]* | amd:*"radeon 6"[0-9]0m*) echo "h264,hevc|" ;;
    amd:*"rx "[45][0-9]0* | amd:*vega*) echo "h264,hevc|older AMD encoder generation" ;;
    intel:*" arc"* | intel:*"[arc"*) echo "h264,hevc,av1|" ;;
    intel:*"iris xe"* | intel:*"uhd graphics"* | intel:*"iris plus"* | intel:*"iris pro"*) echo "h264,hevc|AV1 is decode-only on this iGPU generation" ;;
    intel:*"hd graphics"*) echo "h264|older iGPU, HEVC depends on generation" ;;
    apple:*"apple m"*) echo "h264,hevc|Apple silicon media engine" ;;
    *) echo "?|model not in the built-in table" ;;
  esac
}

vendor_from_text() {
  case "$(lower "$1")" in
    *nvidia* | *10de*) echo NVIDIA ;;
    *"advanced micro"* | *amd* | *radeon* | *1002*) echo AMD ;;
    *intel* | *8086*) echo Intel ;;
    *apple*) echo Apple ;;
    *) echo Unknown ;;
  esac
}

# gpu_json vendor model driver vram_mb api codecs source note
gpu_json() {
  local codecs_json
  if [ "$6" = "?" ]; then codecs_json=null; else codecs_json=$(jcsv "$6"); fi
  printf '{"vendor":%s,"model":%s,"driver":%s,"vram_mb":%s,"hw_encoder":{"api":%s,"codecs":%s,"source":%s,"note":%s}}' \
    "$(jstr "$1")" "$(jstr "$2")" "$(jstr "$3")" "$(jnum "$4")" "$(jstr "$5")" "$codecs_json" "$(jstr "$7")" "$(jstr "$8")"
}

GPUS=()
DISPLAYS=()
OBS_INSTALLS=()
OS_NAME="" OS_VERSION="" OS_BUILD="" KERNEL="" ARCH="" SESSION="" DESKTOP=""
CPU_MODEL="" CPU_CORES="" CPU_THREADS="" CPU_MAX_MHZ="" CPU_PCORES="" CPU_ECORES=""
RAM_MB="" IS_LAPTOP="" HW_MODEL="" CONTAINER=false VIRT=""

display_json() { # name WxH refresh note
  printf '{"name":%s,"resolution":%s,"refresh_hz":%s,"note":%s}' "$(jstr "$1")" "$(jstr "$2")" "$(jnum "$3")" "$(jstr "$4")"
}

# ---------------------------------------------------------------- Linux
linux_cpu() {
  if have lscpu; then
    local l sockets="" cps=""
    while IFS= read -r l; do
      case "$l" in
        "Model name:"*) CPU_MODEL=$(trim "${l#*:}") ;;
        "Socket(s):"*) sockets=$(trim "${l#*:}") ;;
        "Core(s) per socket:"*) cps=$(trim "${l#*:}") ;;
        "CPU(s):"*) CPU_THREADS=$(trim "${l#*:}") ;;
        "CPU max MHz:"*) CPU_MAX_MHZ=$(trim "${l#*:}") ;;
      esac
    done < <(lscpu 2>/dev/null)
    case "$sockets$cps" in *[!0-9]* | '') ;; *) CPU_CORES=$((sockets * cps)) ;; esac
  else
    warn "lscpu not found; CPU core count taken from /proc/cpuinfo"
  fi
  if [ -z "$CPU_MODEL" ] || [ "$CPU_MODEL" = "-" ]; then
    CPU_MODEL=$(awk -F: '/^model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
    CPU_MODEL=$(trim "$CPU_MODEL")
  fi
  [ -z "$CPU_THREADS" ] && CPU_THREADS=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
  if [ -z "$CPU_CORES" ]; then
    CPU_CORES=$(awk -F: '/^physical id/ {p=$2} /^core id/ {print p ":" $2}' /proc/cpuinfo 2>/dev/null | sort -u | wc -l | tr -d ' ')
    [ "$CPU_CORES" = "0" ] && CPU_CORES=""
  fi
  CPU_MAX_MHZ=${CPU_MAX_MHZ%%.*}
}

linux_os() {
  if [ -r /etc/os-release ]; then
    # shellcheck source=/dev/null
    OS_NAME=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}")
    # shellcheck source=/dev/null
    OS_VERSION=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
  else
    OS_NAME="Linux"
    warn "/etc/os-release not readable; distribution unknown"
  fi
  KERNEL=$(uname -r)
  SESSION=${XDG_SESSION_TYPE:-}
  DESKTOP=${XDG_CURRENT_DESKTOP:-}
  local kb
  kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
  [ -n "$kb" ] && RAM_MB=$((kb / 1024))
  IS_LAPTOP=false
  local b
  for b in /sys/class/power_supply/BAT*; do [ -e "$b" ] && IS_LAPTOP=true; done
  case "$(cat /sys/class/dmi/id/chassis_type 2>/dev/null)" in 8 | 9 | 10 | 14 | 31 | 32) IS_LAPTOP=true ;; esac
  if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then CONTAINER=true; fi
  HW_MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
  case "$HW_MODEL" in "System Product Name" | "To Be Filled By O.E.M." | "Default string" | "Not Applicable") HW_MODEL="" ;; esac
  have systemd-detect-virt && VIRT=$(systemd-detect-virt 2>/dev/null)
}

# Prints "codecs|driver version" from vainfo for the render node of a PCI vendor id (e.g. 0x1002).
vaapi_codecs() {
  local want=$1 node out codecs="" drv
  have vainfo || return 1
  for node in /dev/dri/renderD*; do
    [ -e "$node" ] || continue
    [ "$(cat "/sys/class/drm/${node##*/}/device/vendor" 2>/dev/null)" = "$want" ] || continue
    out=$(run_t vainfo --display drm --device "$node" 2>/dev/null) || continue
    drv=$(printf '%s\n' "$out" | sed -n 's/.*Driver version: *//p' | head -n 1)
    printf '%s\n' "$out" | grep -q 'VAProfileH264.*EncSlice' && codecs="h264"
    printf '%s\n' "$out" | grep -q 'VAProfileHEVC.*EncSlice' && codecs="${codecs:+$codecs,}hevc"
    printf '%s\n' "$out" | grep -q 'VAProfileAV1.*EncSlice' && codecs="${codecs:+$codecs,}av1"
    echo "$codecs|$drv"
    return 0
  done
  return 1
}

linux_gpus() {
  local smi_lines=() smi_i=0 l
  if have nvidia-smi; then
    while IFS= read -r l; do [ -n "$l" ] && smi_lines+=("$l"); done \
      < <(run_t nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits 2>/dev/null)
    [ ${#smi_lines[@]} -eq 0 ] && warn "nvidia-smi is installed but returned no GPUs (driver not loaded?)"
  fi

  local entries=()
  if have lspci; then
    while IFS= read -r l; do entries+=("$l"); done < <(lspci -nn 2>/dev/null | grep -E '\[03(00|02|80)\]')
  else
    warn "lspci not found (install pciutils for GPU model names); using /sys/class/drm"
    local c
    for c in /sys/class/drm/card[0-9] /sys/class/drm/card[0-9][0-9]; do
      [ -r "$c/device/vendor" ] || continue
      entries+=("sysfs $(sed 's/^0x//' "$c/device/vendor"):$(sed 's/^0x//' "$c/device/device") [$(sed 's/^0x//' "$c/device/vendor"):0000]")
    done
  fi
  [ ${#entries[@]} -eq 0 ] && warn "no GPU found via lspci or /sys/class/drm"

  local e addr desc vid model vendor driver vram api inf codecs note source
  for e in ${entries[@]+"${entries[@]}"}; do
    addr=${e%% *}
    desc=${e#*]: }
    vid=$(printf '%s' "$e" | sed -nE 's/.*\[([0-9a-f]{4}):[0-9a-f]{4}\].*/\1/p')
    model=$(printf '%s' "$desc" | sed -E 's/ \[[0-9a-f]{4}:[0-9a-f]{4}\]//; s/ \(rev [0-9a-f]+\)//')
    [ "$addr" = "sysfs" ] && model="PCI device $(printf '%s' "$e" | cut -d' ' -f2) (install pciutils for the model name)"
    vendor=$(vendor_from_text "$vid $desc")
    driver="" vram=""
    if [ "$addr" != "sysfs" ]; then
      driver=$(lspci -k -s "$addr" 2>/dev/null | sed -n 's/.*Kernel driver in use: *//p' | head -n 1)
    fi
    api="" codecs="?" note="" source="inferred_from_model"
    case "$vendor" in
      NVIDIA)
        api="NVENC"
        if [ $smi_i -lt ${#smi_lines[@]} ]; then
          l=${smi_lines[$smi_i]}
          smi_i=$((smi_i + 1))
          model=$(trim "${l%%,*}")
          l=${l#*,}
          driver="nvidia $(trim "${l%%,*}")"
          vram=$(trim "${l##*,}")
        elif [ -r /proc/driver/nvidia/version ]; then
          l=$(sed -nE 's/^NVRM.*[[:space:]]([0-9]{3,}\.[0-9]+(\.[0-9]+)?)[[:space:]].*/\1/p' /proc/driver/nvidia/version | head -n 1)
          [ -n "$l" ] && driver="nvidia $l"
        fi
        ;;
      AMD) api="VAAPI" ;;
      Intel) api="VAAPI or QSV" ;;
    esac
    inf=$(infer_codecs "$vendor" "$model")
    codecs=${inf%%|*}
    note=${inf#*|}
    if [ "$vendor" = "AMD" ] || [ "$vendor" = "Intel" ]; then
      local va
      if va=$(vaapi_codecs "0x$vid"); then
        codecs=${va%%|*}
        source="vainfo"
        note="VA-API encode profiles reported by the driver"
        [ -n "${va#*|}" ] && driver="${driver:+$driver, }${va#*|}"
      elif ! have vainfo; then
        warn "vainfo not found (libva-utils); $vendor encoder codecs are inferred from the model name"
      fi
    fi
    [ "$codecs" = "?" ] && source="unknown"
    GPUS+=("$(gpu_json "$vendor" "$model" "$driver" "$vram" "$api" "$codecs" "$source" "$note")")
  done

  # nvidia-smi saw GPUs that lspci did not (no pciutils): add them anyway
  while [ $smi_i -lt ${#smi_lines[@]} ]; do
    l=${smi_lines[$smi_i]}
    smi_i=$((smi_i + 1))
    model=$(trim "${l%%,*}")
    inf=$(infer_codecs NVIDIA "$model")
    local rest=${l#*,}
    GPUS+=("$(gpu_json NVIDIA "$model" "nvidia $(trim "${rest%%,*}")" "$(trim "${l##*,}")" NVENC "${inf%%|*}" inferred_from_model "${inf#*|}")")
  done
  [ -n "${LIBVA_DRIVER_NAME:-}" ] && warn "LIBVA_DRIVER_NAME=${LIBVA_DRIVER_NAME} is set; it can stop VA-API encoding in OBS"
}

linux_displays() {
  local l found=""
  if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && have hyprctl; then
    while IFS='|' read -r n r h; do DISPLAYS+=("$(display_json "$n" "$r" "$h" "hyprctl")") && found=1; done < <(
      run_t hyprctl monitors 2>/dev/null | awk '/^Monitor /{n=$2} /^[ \t]+[0-9]+x[0-9]+@/{split($1,a,"@"); printf "%s|%s|%.2f\n", n, a[1], a[2]}')
  fi
  if [ -z "$found" ] && [ -n "${SWAYSOCK:-}" ] && have swaymsg; then
    while IFS='|' read -r n r h; do DISPLAYS+=("$(display_json "$n" "$r" "$h" "swaymsg")") && found=1; done < <(
      run_t swaymsg -p -t get_outputs 2>/dev/null | awk '/^Output /{n=$2} /Current mode:/{printf "%s|%s|%s\n", n, $3, $5}')
  fi
  if [ -z "$found" ] && have kscreen-doctor && [ "${SESSION}" = "wayland" ]; then
    while IFS='|' read -r n r h; do DISPLAYS+=("$(display_json "$n" "$r" "$h" "kscreen-doctor")") && found=1; done < <(
      run_t kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '
        /Output:/ {n=$3}
        { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+:[0-9]+x[0-9]+@[0-9.]+!?\*/) { m=$i; sub(/^[0-9]+:/,"",m); gsub(/[*!]/,"",m); split(m,a,"@"); print n "|" a[1] "|" a[2] } }')
  fi
  if [ -z "$found" ] && have wlr-randr && [ -n "${WAYLAND_DISPLAY:-}" ]; then
    while IFS='|' read -r n r h; do DISPLAYS+=("$(display_json "$n" "$r" "$h" "wlr-randr")") && found=1; done < <(
      run_t wlr-randr 2>/dev/null | awk '/^[^ ]/{n=$1} /current/{printf "%s|%s|%s\n", n, $1, $3}')
  fi
  if [ -z "$found" ] && have xrandr && [ -n "${DISPLAY:-}" ]; then
    local note="xrandr"
    [ "$SESSION" = "wayland" ] && note="xrandr via XWayland (refresh may be inaccurate)"
    while IFS='|' read -r n r h; do DISPLAYS+=("$(display_json "$n" "$r" "$h" "$note")") && found=1; done < <(
      run_t xrandr --current 2>/dev/null | awk '
        / connected/ {n=$1}
        /^ +[0-9]+x[0-9]+/ { for (i=2;i<=NF;i++) if ($i ~ /\*/) { h=$i; gsub(/[*+]/,"",h); print n "|" $1 "|" h } }')
  fi
  if [ -z "$found" ]; then
    local s
    for s in /sys/class/drm/card*-*; do
      [ "$(cat "$s/status" 2>/dev/null)" = "connected" ] || continue
      l=$(head -n 1 "$s/modes" 2>/dev/null)
      [ -n "$l" ] && DISPLAYS+=("$(display_json "${s##*card[0-9]-}" "$l" "" "preferred mode from sysfs; current mode and refresh unknown")") && found=1
    done
  fi
  [ -z "$found" ] && warn "could not read display resolution/refresh rate; ask the user"
}

linux_obs() {
  local v
  if have flatpak; then
    v=$(run_t flatpak info com.obsproject.Studio 2>/dev/null | sed -n 's/^ *Version: *//p' | head -n 1)
    [ -n "$v" ] && OBS_INSTALLS+=("{\"source\":\"flatpak\",\"version\":$(jstr "$v")}")
  fi
  if have snap; then
    v=$(snap list obs-studio 2>/dev/null | awk 'NR==2 {print $2}')
    [ -n "$v" ] && OBS_INSTALLS+=("{\"source\":\"snap\",\"version\":$(jstr "$v")}")
  fi
  if have pacman; then
    v=$(pacman -Q 2>/dev/null | awk '$1 ~ /^obs-studio/ {print $1 " " $2; exit}')
    [ -n "$v" ] && OBS_INSTALLS+=("{\"source\":\"pacman\",\"version\":$(jstr "$v")}")
  elif have dpkg-query; then
    # shellcheck disable=SC2016 # dpkg-query format string, not a shell variable
    v=$(dpkg-query -W -f='${Version}' obs-studio 2>/dev/null)
    [ -n "$v" ] && OBS_INSTALLS+=("{\"source\":\"dpkg\",\"version\":$(jstr "$v")}")
  elif have rpm; then
    v=$(rpm -q --qf '%{VERSION}' obs-studio 2>/dev/null) || v=""
    [ -n "$v" ] && OBS_INSTALLS+=("{\"source\":\"rpm\",\"version\":$(jstr "$v")}")
  fi
  if [ ${#OBS_INSTALLS[@]} -eq 0 ] && have obs; then
    v=$(run_t obs --version 2>/dev/null | sed -n 's/^OBS Studio - //p' | head -n 1)
    [ -n "$v" ] && OBS_INSTALLS+=("{\"source\":\"obs --version\",\"version\":$(jstr "$v")}")
  fi
}

# ---------------------------------------------------------------- macOS
mac_all() {
  OS_NAME=$(sw_vers -productName 2>/dev/null)
  OS_VERSION=$(sw_vers -productVersion 2>/dev/null)
  OS_BUILD=$(sw_vers -buildVersion 2>/dev/null)
  KERNEL=$(uname -r)
  CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
  CPU_CORES=$(sysctl -n hw.physicalcpu 2>/dev/null)
  CPU_THREADS=$(sysctl -n hw.logicalcpu 2>/dev/null)
  CPU_PCORES=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null)
  CPU_ECORES=$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null)
  HW_MODEL=$(sysctl -n hw.model 2>/dev/null)
  local bytes
  bytes=$(sysctl -n hw.memsize 2>/dev/null)
  [ -n "$bytes" ] && RAM_MB=$((bytes / 1048576))
  case "$HW_MODEL" in MacBook*) IS_LAPTOP=true ;; *) IS_LAPTOP=false ;; esac
  if [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" = "1" ]; then VIRT="macOS VM ($HW_MODEL)"; fi
  if have pmset && pmset -g batt 2>/dev/null | grep -q InternalBattery; then IS_LAPTOP=true; fi

  if ! have system_profiler; then
    warn "system_profiler not found; GPU and display unknown"
  else
    local kind a b c cur_model="" cur_vendor="" cur_vram="" cur_cores=""
    flush_gpu() {
      [ -n "$cur_model" ] || return 0
      local inf codecs note
      if [ "$cur_vendor" = "Apple" ]; then
        inf=$(infer_codecs Apple "$cur_model")
      else
        inf="h264|Intel Mac: VideoToolbox H.264; HEVC needs a 7th-gen+ Intel CPU or T2 chip"
      fi
      codecs=${inf%%|*}
      note=${inf#*|}
      [ -n "$cur_cores" ] && note="${note:+$note; }$cur_cores GPU cores"
      GPUS+=("$(gpu_json "$cur_vendor" "$cur_model" "bundled with macOS" "$cur_vram" VideoToolbox "$codecs" inferred_from_model "$note")")
      cur_model="" cur_vendor="" cur_vram="" cur_cores=""
    }
    while IFS='|' read -r kind a b c; do
      case "$kind" in
        GPU) flush_gpu; cur_model=$a ;;
        VENDOR) cur_vendor=$(vendor_from_text "$a") ;;
        VRAM) cur_vram=$(printf '%s' "$a" | awk '/GB/ {print $1*1024; next} {print $1+0}') ;;
        CORES) cur_cores=$a ;;
        DISP) DISPLAYS+=("$(display_json "display" "$a" "$b" "$c")") ;;
      esac
    done < <(run_t system_profiler SPDisplaysDataType 2>/dev/null | awk '
      function flush() { if (res != "") print "DISP|" res "|" hz "|" (ui != "" ? "UI looks like " ui : "native panel resolution"); res=""; hz=""; ui="" }
      /Chipset Model:/        { flush(); v=$0; sub(/.*Chipset Model: */, "", v); print "GPU|" v; next }
      /^ *Vendor:/            { v=$0; sub(/.*Vendor: */, "", v); print "VENDOR|" v; next }
      /VRAM/                  { v=$0; sub(/.*: */, "", v); print "VRAM|" v; next }
      /Total Number of Cores:/ { v=$0; sub(/.*: */, "", v); print "CORES|" v; next }
      /^ *Resolution:/        { flush(); v=$0; sub(/.*Resolution: */, "", v)
                                if (match(v, /[0-9]+ x [0-9]+/)) { res=substr(v, RSTART, RLENGTH); gsub(/ /, "", res) }
                                if (match(v, /@ *[0-9.]+ *Hz/)) { hz=substr(v, RSTART, RLENGTH); gsub(/[@ Hz]/, "", hz) } next }
      /UI Looks like:/        { v=$0; sub(/.*UI Looks like: */, "", v)
                                if (match(v, /[0-9]+ x [0-9]+/)) { ui=substr(v, RSTART, RLENGTH); gsub(/ /, "", ui) }
                                if (match(v, /@ *[0-9.]+ *Hz/)) { hz=substr(v, RSTART, RLENGTH); gsub(/[@ Hz]/, "", hz) } next }
      END { flush() }')
    flush_gpu
    [ ${#GPUS[@]} -eq 0 ] && warn "system_profiler returned no GPU"
    [ ${#DISPLAYS[@]} -eq 0 ] && warn "no display found via system_profiler; ask the user for resolution and refresh rate"
  fi

  local app v
  for app in "/Applications/OBS.app" "$HOME/Applications/OBS.app"; do
    [ -r "$app/Contents/Info.plist" ] || continue
    if [ -x /usr/libexec/PlistBuddy ]; then
      v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null)
    else
      v=$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null)
    fi
    # shellcheck disable=SC2088 # a literal ~ on purpose: never print the real home path
    case "$app" in "$HOME"*) app="~/Applications/OBS.app" ;; esac
    OBS_INSTALLS+=("{\"source\":$(jstr "$app"),\"version\":$(jstr "$v")}")
  done
}

# ---------------------------------------------------------------- main
OS_KIND=$(uname -s 2>/dev/null)
ARCH=$(uname -m 2>/dev/null)
case "$OS_KIND" in
  Linux)
    linux_os
    linux_cpu
    linux_gpus
    linux_displays
    linux_obs
    PLATFORM=linux
    ;;
  Darwin)
    mac_all
    PLATFORM=macos
    ;;
  *)
    echo "error: unsupported OS '$OS_KIND'. Use detect_hardware.ps1 on Windows." >&2
    exit 1
    ;;
esac

[ "$CONTAINER" = true ] && warn "running inside a container: results may not describe the user's PC"
case "$VIRT" in "" | none) ;; *) warn "running in a virtual machine ($VIRT): results may not describe the user's PC" ;; esac
[ ${#OBS_INSTALLS[@]} -eq 0 ] && warn "OBS Studio installation not found (or installed in an unusual way)"

join() { local IFS=,; printf '%s' "$*"; }
warn_json=""
for w in ${WARNINGS[@]+"${WARNINGS[@]}"}; do warn_json="${warn_json:+$warn_json,}$(jstr "$w")"; done

OUT=$(
  printf '{\n'
  printf '  "schema": "obs-settings-advisor/hardware/v1",\n'
  printf '  "os": {"platform":%s,"name":%s,"version":%s,"build":%s,"kernel":%s,"arch":%s,"session_type":%s,"desktop":%s},\n' \
    "$(jstr "$PLATFORM")" "$(jstr "$OS_NAME")" "$(jstr "$OS_VERSION")" "$(jstr "$OS_BUILD")" "$(jstr "$KERNEL")" \
    "$(jstr "$ARCH")" "$(jstr "$SESSION")" "$(jstr "$DESKTOP")"
  printf '  "machine": {"model":%s,"is_laptop":%s,"container":%s,"virtualization":%s},\n' \
    "$(jstr "$HW_MODEL")" "$(jbool "$IS_LAPTOP")" "$(jbool "$CONTAINER")" "$(jstr "${VIRT#none}")"
  printf '  "cpu": {"model":%s,"cores":%s,"threads":%s,"performance_cores":%s,"efficiency_cores":%s,"max_mhz":%s},\n' \
    "$(jstr "$CPU_MODEL")" "$(jnum "$CPU_CORES")" "$(jnum "$CPU_THREADS")" "$(jnum "$CPU_PCORES")" "$(jnum "$CPU_ECORES")" "$(jnum "$CPU_MAX_MHZ")"
  printf '  "memory": {"total_mb":%s},\n' "$(jnum "$RAM_MB")"
  printf '  "gpus": [%s],\n' "$(join ${GPUS[@]+"${GPUS[@]}"})"
  printf '  "displays": [%s],\n' "$(join ${DISPLAYS[@]+"${DISPLAYS[@]}"})"
  printf '  "obs": {"installs": [%s]},\n' "$(join ${OBS_INSTALLS[@]+"${OBS_INSTALLS[@]}"})"
  printf '  "notes": ["hw_encoder.codecs with source inferred_from_model is a heuristic; the encoder list in an OBS log (analyze_obs_log.py available_video_encoders) is authoritative"],\n'
  printf '  "warnings": [%s]\n' "$warn_json"
  printf '}\n'
)
# last line of defence against personal paths in tool output
printf '%s\n' "$OUT" | sed -E 's#/(home|Users)/[^/" ]+#/\1/<user>#g'
