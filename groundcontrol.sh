#!/usr/bin/env bash
#
# groundcontrol.sh — control the ADS-B stack on a uConsole with a HackerGadgets AIOv2 board.
#
# Nothing touches the radio without clearance from here.
#
# The AIOv2 puts the RTL-SDR and the GPS behind GPIO power rails that must be switched on
# with aiov2_ctl BEFORE anything tries to use them. readsb.service is enabled at boot, so if
# the SDR rail is off readsb sits in a restart loop (exit 1, every 15s) because the RTL device
# doesn't exist. This menu enforces the ordering: rail on -> wait for USB enumeration ->
# start services.
#
# Only ONE process can hold the RTL at a time. readsb (and therefore the tar1090 web map) must
# be stopped before acarsdec / dumpvdl2 / rtl_adsb / kismet can use the radio. Those entries
# prompt first and restore readsb when the tool exits, including on Ctrl-C.
#
# viewadsb is the exception: it reads beast data over TCP :30005, so it runs happily alongside
# readsb without touching the radio.
#
# GPS lives on /dev/ttyAMA0 (serial) while the SDR is USB, so GPS NEVER conflicts with an SDR
# tool and can be left on permanently.
#
# Usage:  ./groundcontrol.sh
#
set -euo pipefail

# --- paths this script owns ----------------------------------------------
# NOTE: config path keeps the old adsb-menu name on purpose, so saved locations
# survive the rename to groundcontrol. Do not "tidy" this.
CONF_DIR="${HOME}/.config/adsb-menu"
LOCATIONS_FILE="${CONF_DIR}/locations.tsv"   # name<TAB>lat<TAB>lon<TAB>source<TAB>timestamp
ACTIVE_FILE="${CONF_DIR}/active-location"    # name<TAB>lat<TAB>lon<TAB>source<TAB>timestamp
READSB_DEFAULTS="/etc/default/readsb"        # the ONLY system file we write
KISMET_CONF="/etc/kismet/kismet.conf"

TAR1090_PORT=8504
BEAST_PORT=30005
GPS_FIX_TIMEOUT=45          # seconds to wait for a GPS fix
RTL_ENUM_TIMEOUT=10         # seconds to wait for the RTL to appear on USB after rail-on

# --- frequency reference ---------------------------------------------------
# Format:  MHz|region|use|decoder
FREQ_ADSB='1090.000|worldwide|ADS-B / Mode S extended squitter (downlink)|readsb, viewadsb, rtl_adsb
1030.000|worldwide|SSR / Mode S interrogation (ground radar uplink)|not decoded here
978.000|USA only|UAT, below 18,000 ft (not used in Canada)|dump978 (not installed)'

FREQ_ACARS='131.550|worldwide|Primary ACARS channel|acarsdec
130.025|USA + Canada|Secondary|acarsdec
130.450|USA + Canada|Additional|acarsdec
129.125|USA + Canada|Additional|acarsdec
131.125|USA|Additional|acarsdec
130.425|USA|Additional|acarsdec
131.475|Canada|Air Canada company channel|acarsdec
136.850|N. America|SITA|acarsdec
131.725|Europe|Primary (SITA)|acarsdec
131.525|Europe|Secondary|acarsdec
131.850|Europe|Additional|acarsdec'

FREQ_VDL2='136.975|worldwide|Common Signalling Channel (CSC), link setup|dumpvdl2
136.650|N. America|ARINC|dumpvdl2
136.700|N. America|ARINC|dumpvdl2
136.800|N. America|SITA|dumpvdl2
136.725|Europe|ARINC|dumpvdl2
136.775|Europe|SITA|dumpvdl2
136.825|Europe|ARINC|dumpvdl2
136.875|Europe|SITA|dumpvdl2'

# --- CYVR voice (plain AM, no decoder) -------------------------------------
# Transcribed from ~/Radio-Ref-QueryResult.csv (RadioReference export, rows 82-153),
# which is the YVR block of that query. Everything here is AM voice: there is nothing
# to decode, you just listen, so it needs rtl_fm rather than readsb/acarsdec/dumpvdl2.
# Table data avoids em-dashes on purpose — printf pads by bytes, so multibyte
# characters in a column would throw the alignment off.
FREQ_VOICE_ATC='124.600|CYVR ATIS|Automatic terminal information|start here, always on
118.700|CYVR Tower|Tower - south|
119.550|CYVR Tower|Tower - north|
120.150|CYVR Tower|Tower - backup|
124.025|CYVR Tower|Tower - outer|
121.700|CYVR Ground|Ground - south|
127.150|CYVR Ground|Ground - north|
121.400|CYVR Delivery|Clearance delivery|IFR clearances
133.100|Terminal|Arrivals low - inner|
128.600|Terminal|Arrivals high - outer|
126.125|Terminal|Departures - north|
132.300|Terminal|Departures - south|
125.200|Terminal|YVR TRSA|terminal radio svc area
120.500|Terminal|ILS monitor|
120.800|Terminal|ILS monitor|
128.175|Terminal|ILS monitor|
121.500|Emergency|Air distress (guard)|not in CSV, standard
243.000|Military UHF|Tower|above the VHF airband
226.500|Military UHF|Tower|
236.600|Military UHF|Tower|
275.800|Military UHF|Ground|
352.700|Military UHF|Arrivals|
363.800|Military UHF|Departures|'

FREQ_VOICE_OPS='129.900|Air Canada|Technical services (maintenance)|
130.000|Air Canada|Jazz maintenance|
130.150|Air Canada|De-icing / STOC backup|
130.175|Air Canada|STOC (terminal ops centre)|
130.350|Air Canada|Jazz jet ops|
130.475|Air Canada|Jazz flight dispatch|
130.800|Air Canada|Dispatch - international|
130.900|Air Canada|Dispatch - CRJ / 737|
131.775|Air Canada|Ops (AGRIS)|
130.575|WestJet|Ops|
131.875|WestJet|Ops|
129.450|United|Ops|
128.900|Cathay / Lufthansa|Ops (shared)|Dragon Ops
130.200|British Airways|Ops|
130.975|China Airlines|Ops|
131.175|Air Transat|Ops|
130.675|NW / Continental|Ops (shared)|
122.950|Philippine|Ops|shared, see FBO below
132.000|Horizon Air|Ops|
131.925|FedEx|Ops|
129.425|UPS / Cargojet|Ops (shared)|
128.950|Purolator|Ops (Kelowna Flightcraft)|
130.050|Helijet|Ops|
131.250|Helijet|Ops|
122.850|Seair / ESSO|Ops / FBO (shared)|
129.300|Seair / Omega Air|Ops (shared)|
130.950|Pacific Coastal|Ops|
130.375|N. Thunderbird|Ops|
129.775|North Vancouver Air|Ops|
129.150|KD Air|Ops|
131.675|Hawkair|Ops|
130.275|BC Ambulance|Fixed-wing air ambulance|
122.350|Pacific Heliport|Heliport services|
123.400|RTD Helicopters|Ops|
122.950|FBO / handling|Globe Gnd / Million Air / Skysvc|
123.000|FBO|Shell Aerocentre|Piedmont Hawthorne
122.925|FBO|Penta Aviation|
128.950|Maintenance|Pacific Avionics|
123.150|Kamloops FIC|Flight service station RCO|remote outlet'

# rtl_fm demod settings for the voice channels above. 12 kHz is plenty for AM voice
# and keeps the pipe to aplay small. Squelch (-l) MUST be non-zero for rtl_fm to hop
# between multiple -f arguments; with -l 0 it parks on the first one.
VOICE_SAMP=12000
VOICE_SQUELCH=30
VOICE_ATIS_FREQ="124.6M"
VOICE_SCAN_FREQS="118.7M 119.55M 121.4M 121.7M"

# Launch defaults. Two decoder quirks, both confirmed on this box:
#
#   acarsdec takes MHz, and every channel must fit inside its 2.0 MS/s tuner window.
#   A span wider than ~2 MHz aborts with "Frequencies too far apart". The set below
#   spans 1.525 MHz (130.025 -> 131.550) and includes Air Canada's company channel.
ACARS_FREQS="130.025 130.450 131.125 131.475 131.550"
#
#   dumpvdl2 takes Hz, NOT MHz. Passing 136.975 is accepted silently and tunes the
#   radio to 136 Hz, so it decodes nothing at all. North American channels + the CSC.
VDL2_FREQS="136650000 136700000 136800000 136975000"

# --- colors --------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'; C_MAGENTA=$'\033[35m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''
    C_GREEN=''; C_RED=''; C_YELLOW=''; C_CYAN=''; C_MAGENTA=''
fi

# --- preflight -----------------------------------------------------------
for bin in aiov2_ctl systemctl awk; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "ERROR: required command '$bin' not found in PATH." >&2
        exit 1
    fi
done

if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
    if ! sudo -n true 2>/dev/null; then
        echo "NOTE: sudo will prompt for a password (rail toggles and systemctl need root)." >&2
    fi
fi

mkdir -p "$CONF_DIR"

# ==========================================================================
# state gathering
# ==========================================================================

# Parses `aiov2_ctl --status` once per redraw and caches the fields we show.
# Output format (verified):
#   GPS   GPIO27: OFF
#   ...
#   Capacity  : 99%
#   Direction : discharging
#   Power     : 5.23 W
RAIL_GPS=""; RAIL_SDR=""; RAIL_LORA=""; RAIL_USB=""
BATT_CAP=""; BATT_DIR=""; BATT_PWR=""; BATT_SRC=""

read_aiov2_status() {
    local out
    out="$(aiov2_ctl --status 2>/dev/null)" || out=""

    RAIL_GPS="$(awk '/^GPS[[:space:]]+GPIO/ {print $NF}'  <<<"$out")"
    RAIL_LORA="$(awk '/^LORA[[:space:]]+GPIO/ {print $NF}' <<<"$out")"
    RAIL_SDR="$(awk '/^SDR[[:space:]]+GPIO/ {print $NF}'  <<<"$out")"
    RAIL_USB="$(awk '/^USB[[:space:]]+GPIO/ {print $NF}'  <<<"$out")"

    BATT_CAP="$(awk -F': *' '/^Capacity/  {print $2}' <<<"$out")"
    BATT_DIR="$(awk -F': *' '/^Direction/ {print $2}' <<<"$out")"
    BATT_PWR="$(awk -F': *' '/^Power/     {print $2}' <<<"$out")"
    BATT_SRC="$(awk -F': *' '/^Source/    {print $2}' <<<"$out")"

    : "${RAIL_GPS:=?}" "${RAIL_LORA:=?}" "${RAIL_SDR:=?}" "${RAIL_USB:=?}"
}

rail_on() { [[ "$1" == "ON" ]]; }

svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

svc_state() { systemctl is-active "$1" 2>/dev/null || true; }

set_rail() {
    local feature="$1" state="$2"
    echo "  ${C_DIM}\$ aiov2_ctl ${feature} ${state}${C_RESET}"
    if ! $SUDO aiov2_ctl "$feature" "$state" >/dev/null 2>&1; then
        echo "  ${C_RED}failed to switch ${feature} ${state}${C_RESET}"
        return 1
    fi
    return 0
}

# Known bogus positions. Some counterfeit "u-blox" modules emit a canned 3D fix at
# 30.0000N/120.0000E (Zhejiang, CN) with NO satellites listed and no GSV sentences at
# all — gpsd reports mode 3 for it, so checking mode >= 2 alone is NOT sufficient.
# The AIOv2 module fitted here does exactly that. 0,0 (null island) is the other classic.
GPS_BOGUS="30.0,120.0 0.0,0.0"
GPS_BOGUS_TOL=0.01

# gps_fix() reports through these globals rather than stdout: it has to set a rejection
# reason, and $(...) would run it in a subshell where that assignment is lost.
GPS_FIX_REASON=""
GPS_MODE=""; GPS_LAT=""; GPS_LON=""; GPS_USED=""; GPS_SEEN=""

# Reads gpsd and validates the fix. Returns 0 and populates GPS_MODE/GPS_LAT/GPS_LON/
# GPS_USED/GPS_SEEN on success; returns non-zero and sets GPS_FIX_REASON otherwise.
# $1 = seconds to sample (default 3; the header uses a short window).
gps_fix() {
    local secs="${1:-3}"
    GPS_FIX_REASON=""; GPS_MODE=""; GPS_LAT=""; GPS_LON=""; GPS_USED=""; GPS_SEEN=""

    svc_active gpsd                      || { GPS_FIX_REASON="gpsd not running";     return 1; }
    command -v gpspipe >/dev/null 2>&1     || { GPS_FIX_REASON="gpspipe not installed"; return 1; }
    command -v jq >/dev/null 2>&1          || { GPS_FIX_REASON="jq not installed";      return 1; }

    local raw
    raw="$(timeout "$secs" gpspipe -w 2>/dev/null \
           | jq -c --unbuffered 'select(.class=="TPV" or .class=="SKY")' 2>/dev/null)" || true
    [[ -n "$raw" ]] || { GPS_FIX_REASON="no data from gpsd"; return 1; }

    local mode lat lon used seen
    mode="$(jq -rs '[.[]|select(.class=="TPV")]|last|.mode//0'          <<<"$raw" 2>/dev/null)"
    lat="$( jq -rs '[.[]|select(.class=="TPV" and .lat!=null)]|last|.lat//""' <<<"$raw" 2>/dev/null)"
    lon="$( jq -rs '[.[]|select(.class=="TPV" and .lon!=null)]|last|.lon//""' <<<"$raw" 2>/dev/null)"
    # '.satellites // []' keeps these total when no SKY report arrived at all (which is
    # itself the counterfeit signature) instead of erroring on a null iterate.
    seen="$(jq -rs '[.[]|select(.class=="SKY" and .satellites!=null)]|last|.satellites//[]|length' <<<"$raw" 2>/dev/null)"
    used="$(jq -rs '[.[]|select(.class=="SKY" and .satellites!=null)]|last|.satellites//[]|map(select(.used==true))|length' <<<"$raw" 2>/dev/null)"

    [[ "$mode" =~ ^[0-9]+$ ]] || mode=0
    [[ "$seen" =~ ^[0-9]+$ ]] || seen=0
    [[ "$used" =~ ^[0-9]+$ ]] || used=0

    if (( mode < 2 )); then
        GPS_FIX_REASON="no fix (mode ${mode})"
        return 1
    fi
    if [[ -z "$lat" || -z "$lon" || "$lat" == "null" || "$lon" == "null" ]]; then
        GPS_FIX_REASON="fix reported without coordinates"
        return 1
    fi

    # A receiver claiming a fix while tracking no satellites is fabricating it.
    if (( used < 3 )); then
        GPS_FIX_REASON="module claims a ${mode}D fix but reports ${used} satellites used${seen:+ (${seen} seen)} — not trusted"
        return 1
    fi

    local b blat blon
    for b in $GPS_BOGUS; do
        blat="${b%,*}"; blon="${b#*,}"
        if awk -v a="$lat" -v b="$blat" -v t="$GPS_BOGUS_TOL" \
               'BEGIN{exit !((a-b<t)&&(b-a<t))}' && \
           awk -v a="$lon" -v b="$blon" -v t="$GPS_BOGUS_TOL" \
               'BEGIN{exit !((a-b<t)&&(b-a<t))}'; then
            GPS_FIX_REASON="rejected known placeholder position ${blat},${blon} (counterfeit module default)"
            return 1
        fi
    done

    GPS_MODE="$mode"; GPS_LAT="$lat"; GPS_LON="$lon"; GPS_USED="$used"; GPS_SEEN="$seen"
    return 0
}

# ==========================================================================
# location store
# ==========================================================================

seed_locations() {
    [[ -f "$LOCATIONS_FILE" ]] && return 0
    # 'home' is lifted from the lat/lon already configured in /etc/default/readsb.
    local home_lat home_lon
    home_lat="$(grep -oP -- '--lat \K[0-9.-]+' "$READSB_DEFAULTS" 2>/dev/null || true)"
    home_lon="$(grep -oP -- '--lon \K[0-9.-]+' "$READSB_DEFAULTS" 2>/dev/null || true)"
    {
        printf '# groundcontrol saved locations\n'
        printf '# name\tlat\tlon\tsource\ttimestamp   (edit by hand if you like)\n'
        # No hardcoded fallback: a receiver position is personal data, so 'home' is
        # only seeded when readsb is already configured with one on this machine.
        if [[ -n "$home_lat" && -n "$home_lon" ]]; then
            printf 'home\t%s\t%s\tpreset\t%s\n' "$home_lat" "$home_lon" "$(date -Is)"
        fi
        # YVR airport reference point, 49°11'41"N 123°10'57"W.
        printf 'yvr\t49.194722\t-123.182500\tpreset\t%s\n' "$(date -Is)"
        # Burnaby Fraser Foreshore Park, 7751 Fraser Park Dr — on the Fraser River's
        # north arm in SOUTH Burnaby (not Burrard Inlet). Coords per City of Burnaby.
        printf 'foreshore\t49.194494\t-122.991686\tpreset\t%s\n' "$(date -Is)"
    } > "$LOCATIONS_FILE"
    echo "  ${C_DIM}seeded ${LOCATIONS_FILE}${C_RESET}"
}

# Echoes the active location as "name<TAB>lat<TAB>lon<TAB>source<TAB>timestamp".
active_location() {
    [[ -f "$ACTIVE_FILE" ]] && { cat "$ACTIVE_FILE"; return 0; }
    # Fall back to whatever readsb is configured with.
    local lat lon
    lat="$(grep -oP -- '--lat \K[0-9.-]+' "$READSB_DEFAULTS" 2>/dev/null || true)"
    lon="$(grep -oP -- '--lon \K[0-9.-]+' "$READSB_DEFAULTS" 2>/dev/null || true)"
    [[ -n "$lat" && -n "$lon" ]] || return 1
    printf '(readsb config)\t%s\t%s\treadsb\t-\n' "$lat" "$lon"
}

set_active_location() {
    local name="$1" lat="$2" lon="$3" src="$4"
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$lat" "$lon" "$src" "$(date -Is)" > "$ACTIVE_FILE"
    echo "  ${C_GREEN}active position -> ${name}  ${lat},${lon}  (${src})${C_RESET}"
    echo "  ${C_DIM}written to ${ACTIVE_FILE}${C_RESET}"
}

list_locations() {
    grep -v '^#' "$LOCATIONS_FILE" 2>/dev/null | grep -v '^[[:space:]]*$' || true
}

# ==========================================================================
# drawing
# ==========================================================================

dot() { # $1 = ON/active -> green filled, else dim hollow
    if [[ "$1" == "ON" || "$1" == "active" ]]; then
        printf '%s●%s' "$C_GREEN" "$C_RESET"
    elif [[ "$1" == "activating" ]]; then
        printf '%s◐%s' "$C_YELLOW" "$C_RESET"
    else
        printf '%s○%s' "$C_DIM" "$C_RESET"
    fi
}

draw_header() {
    read_aiov2_status

    local readsb_st tar_st gpsd_st
    readsb_st="$(svc_state readsb)"
    tar_st="$(svc_state tar1090)"
    gpsd_st="$(svc_state gpsd)"

    local arrow="" batt_col="$C_GREEN"
    case "$BATT_DIR" in
        charging)    arrow="▲" ;;
        discharging) arrow="▼" ;;
        *)           arrow="·" ;;
    esac
    if [[ -n "$BATT_CAP" ]]; then
        local capnum="${BATT_CAP%\%}"
        if [[ "$capnum" =~ ^[0-9]+$ ]]; then
            (( capnum <= 15 )) && batt_col="$C_RED"
            (( capnum > 15 && capnum <= 40 )) && batt_col="$C_YELLOW"
        fi
    fi

    clear
    printf '%s╔══════════════════════════════════════════════╗%s\n' "$C_CYAN" "$C_RESET"
    printf '%s║%s  %suConsole AIOv2 — ADS-B Control%s              %s║%s\n' \
        "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '%s╚══════════════════════════════════════════════╝%s\n' "$C_CYAN" "$C_RESET"

    printf ' SDR %s %-3s   GPS %s %-3s   BATT %s%s %s%s%s\n' \
        "$(dot "$RAIL_SDR")" "$RAIL_SDR" \
        "$(dot "$RAIL_GPS")" "$RAIL_GPS" \
        "$batt_col" "${BATT_CAP:-?}" "$arrow" "${BATT_PWR:-?}" "$C_RESET"

    printf ' readsb %s %-10s tar1090 %s %-10s\n' \
        "$(dot "$readsb_st")" "$readsb_st" "$(dot "$tar_st")" "$tar_st"

    # GPS fix line — only costs time when gpsd is actually running.
    local fix_line="${C_DIM}--${C_RESET}"
    if [[ "$gpsd_st" == "active" ]]; then
        if gps_fix 2; then
            fix_line="$(printf '%s%dD %s,%s (%s sats)%s' "$C_GREEN" "$GPS_MODE" \
                "$(printf '%.5f' "$GPS_LAT")" "$(printf '%.5f' "$GPS_LON")" \
                "$GPS_USED" "$C_RESET")"
        else
            # Truncated so a long rejection reason can't wrap the header.
            fix_line="${C_YELLOW}${GPS_FIX_REASON:0:44}${C_RESET}"
        fi
    fi
    printf ' gpsd   %s %-10s fix: %b\n' "$(dot "$gpsd_st")" "$gpsd_st" "$fix_line"

    local act
    if act="$(active_location)"; then
        local n la lo sr
        IFS=$'\t' read -r n la lo sr _ <<<"$act"
        printf ' position: %s%s%s %s,%s %s(%s)%s\n' \
            "$C_MAGENTA" "$n" "$C_RESET" \
            "$(printf '%.5f' "$la")" "$(printf '%.5f' "$lo")" "$C_DIM" "$sr" "$C_RESET"
    else
        printf ' position: %sunset%s\n' "$C_DIM" "$C_RESET"
    fi

    printf '%s────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
}

pause() {
    printf '\n%s[enter] to continue%s ' "$C_DIM" "$C_RESET"
    read -r _ || true
}

confirm() { # $1 = prompt, $2 = default (y/n)
    local prompt="$1" def="${2:-n}" ans hint
    [[ "$def" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    printf '%s %s ' "$prompt" "$hint"
    read -r ans || ans=""
    ans="${ans:-$def}"
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ==========================================================================
# receiver control
# ==========================================================================

rtl_present() {
    lsusb 2>/dev/null | grep -qiE 'ID 0bda:28|RTL2838|RTL2832'
}

# Rail on -> wait for USB enumeration -> services. Refuses to touch systemd if the
# radio never shows up, so we don't recreate the crash loop this script exists to fix.
start_receiver() {
    echo
    echo "${C_BOLD}Starting ADS-B receiver${C_RESET}"

    if svc_active readsb && svc_active tar1090; then
        echo "  readsb and tar1090 are already running."
        show_web_url
        pause; return 0
    fi

    if ! rail_on "$RAIL_SDR"; then
        set_rail SDR on || { pause; return 1; }
    else
        echo "  SDR rail already on."
    fi

    printf '  waiting for the RTL to enumerate '
    local i=0
    while (( i < RTL_ENUM_TIMEOUT )); do
        if rtl_present; then echo " ${C_GREEN}found${C_RESET}"; break; fi
        printf '.'; sleep 1; i=$((i+1))
    done

    if ! rtl_present; then
        echo " ${C_YELLOW}not seen${C_RESET}"
        echo "  ${C_DIM}no Realtek 0bda:28xx device in lsusb. Some clones report other IDs.${C_RESET}"
        if ! confirm "  Start readsb anyway?" n; then
            echo "  aborted — services left alone."
            pause; return 1
        fi
    fi

    echo "  ${C_DIM}\$ systemctl start readsb tar1090${C_RESET}"
    $SUDO systemctl start readsb tar1090 || true
    sleep 2

    if svc_active readsb; then
        echo "  readsb   ${C_GREEN}active${C_RESET}"
    else
        echo "  readsb   ${C_RED}$(svc_state readsb)${C_RESET}"
        echo "  ${C_DIM}last log lines:${C_RESET}"
        journalctl -u readsb -n 5 --no-pager 2>/dev/null | sed 's/^/    /' || true
    fi
    svc_active tar1090 && echo "  tar1090  ${C_GREEN}active${C_RESET}" \
                       || echo "  tar1090  ${C_RED}$(svc_state tar1090)${C_RESET}"

    show_web_url
    pause
}

show_web_url() {
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$ip" ]] || ip="$(hostname)"
    echo
    echo "  web map: ${C_CYAN}http://${ip}:${TAR1090_PORT}${C_RESET}   (also http://${ip}/)"
}

stop_receiver() {
    echo
    echo "${C_BOLD}Stopping ADS-B receiver${C_RESET}"
    echo "  ${C_DIM}\$ systemctl stop readsb tar1090${C_RESET}"
    $SUDO systemctl stop readsb tar1090 || true
    sleep 1
    echo "  readsb  $(svc_state readsb)"
    echo "  tar1090 $(svc_state tar1090)"

    read_aiov2_status
    if rail_on "$RAIL_SDR"; then
        echo
        if confirm "  Power down the SDR rail to save battery?" y; then
            set_rail SDR off
        fi
    fi
    pause
}

# ==========================================================================
# tools
# ==========================================================================

run_viewadsb() {
    echo
    if ! svc_active readsb; then
        echo "  viewadsb reads beast data from readsb on :${BEAST_PORT}, and readsb is $(svc_state readsb)."
        if confirm "  Start the receiver first?" y; then
            start_receiver
        else
            return 0
        fi
        svc_active readsb || { echo "  readsb still not running — aborting."; pause; return 1; }
    fi

    # viewadsb has no --net-bo-port; it connects as a beast client via --net-connector
    # (its own default is 127.0.0.1,30005,beast_in — stated explicitly here).
    # Position goes on the command line, so viewadsb always gets the live one.
    local args=(--net-connector "127.0.0.1,${BEAST_PORT},beast_in")
    local act
    if act="$(active_location)"; then
        local la lo
        IFS=$'\t' read -r _ la lo _ _ <<<"$act"
        args+=(--lat "$la" --lon "$lo")
        echo "  using position ${la},${lo} for distance/bearing columns"
    fi
    echo "  ${C_DIM}\$ viewadsb ${args[*]}${C_RESET}"
    echo "  ${C_DIM}(q or Ctrl-C to return to the menu)${C_RESET}"
    sleep 1
    viewadsb "${args[@]}" || true
}

# Stops readsb, runs an SDR-exclusive tool in the foreground, restores readsb on exit
# (including Ctrl-C, which otherwise leaves you with a dead receiver).
RESTORE_DONE=0
restore_readsb() {
    [[ "$RESTORE_DONE" == "1" ]] && return 0
    RESTORE_DONE=1
    echo
    echo "  ${C_DIM}restarting readsb + tar1090...${C_RESET}"
    $SUDO systemctl start readsb tar1090 || true
    sleep 1
    echo "  readsb $(svc_state readsb)"
}

run_exclusive_tool() {
    local label="$1"; shift
    local -a cmd=("$@")

    echo
    echo "${C_BOLD}${label}${C_RESET}"
    echo "  ${C_YELLOW}${cmd[0]} needs exclusive access to the RTL-SDR.${C_RESET}"

    local was_running=0 restore=0
    if svc_active readsb || svc_active tar1090; then
        was_running=1
        echo "  readsb is currently running and will be stopped."
        if confirm "  Restart readsb when ${cmd[0]} exits?" y; then restore=1; fi
        if ! confirm "  Continue?" n; then
            echo "  aborted — nothing changed."
            pause; return 0
        fi
        echo "  ${C_DIM}\$ systemctl stop readsb tar1090${C_RESET}"
        $SUDO systemctl stop readsb tar1090 || true
        sleep 1
    else
        if ! confirm "  Continue?" y; then pause; return 0; fi
    fi

    read_aiov2_status
    if ! rail_on "$RAIL_SDR"; then
        set_rail SDR on || { [[ $restore == 1 ]] && restore_readsb; pause; return 1; }
        sleep 2
    fi

    # Let the user tweak the command before it runs.
    echo
    echo "  command: ${C_CYAN}${cmd[*]}${C_RESET}"
    printf '  edit it, or [enter] to run as-is: '
    local edited
    read -r edited || edited=""
    if [[ -n "$edited" ]]; then
        read -r -a cmd <<<"$edited"
    fi

    echo "  ${C_DIM}(Ctrl-C to stop and return to the menu)${C_RESET}"
    sleep 1

    RESTORE_DONE=0
    if [[ $restore == 1 ]]; then
        trap 'restore_readsb' INT TERM
    else
        trap 'echo' INT TERM
    fi

    "${cmd[@]}" || true

    trap - INT TERM
    [[ $restore == 1 ]] && restore_readsb
    [[ $was_running == 1 && $restore == 0 ]] && \
        echo "  ${C_DIM}readsb left stopped, as requested.${C_RESET}"
    pause
}

run_kismet() {
    echo
    echo "${C_BOLD}Kismet ADS-B capture${C_RESET}"
    # Kismet geotags everything via gpsd, but that line ships commented out.
    if grep -qE '^[[:space:]]*gps=gpsd' "$KISMET_CONF" 2>/dev/null; then
        echo "  ${C_GREEN}gpsd geotagging is enabled${C_RESET} in ${KISMET_CONF}"
    else
        echo "  ${C_YELLOW}gpsd geotagging is NOT enabled.${C_RESET}"
        echo "  ${C_DIM}To geotag captures, uncomment this line in ${KISMET_CONF}:${C_RESET}"
        echo "  ${C_DIM}  gps=gpsd:host=localhost,port=2947${C_RESET}"
        echo "  ${C_DIM}(left for you to edit — this script won't touch kismet.conf)${C_RESET}"
    fi
    run_exclusive_tool "Kismet" kismet -c rtladsb-0
}

# ==========================================================================
# GPS / location manager
# ==========================================================================

enable_gps() {
    echo
    read_aiov2_status
    if ! rail_on "$RAIL_GPS"; then
        set_rail GPS on || { pause; return 1; }
        sleep 1
    else
        echo "  GPS rail already on."
    fi

    if ! svc_active gpsd; then
        echo "  ${C_DIM}\$ systemctl start gpsd.socket gpsd${C_RESET}"
        $SUDO systemctl start gpsd.socket gpsd || true
        sleep 1
    fi
    echo "  gpsd $(svc_state gpsd)  ${C_DIM}(device /dev/ttyAMA0, per /etc/default/gpsd)${C_RESET}"

    echo
    printf '  waiting up to %ds for a fix (Ctrl-C to give up) ' "$GPS_FIX_TIMEOUT"
    local waited=0 ok=1
    while (( waited < GPS_FIX_TIMEOUT )); do
        if gps_fix 3; then ok=0; break; fi
        printf '.'
        waited=$((waited+3))
    done
    echo

    if (( ok == 0 )); then
        echo "  ${C_GREEN}fix: ${GPS_MODE}D  ${GPS_LAT},${GPS_LON}${C_RESET}  sats used/seen: ${GPS_USED}/${GPS_SEEN}"
    else
        echo "  ${C_YELLOW}no usable fix: ${GPS_FIX_REASON}${C_RESET}"
        case "$GPS_FIX_REASON" in
            *counterfeit*|*"not trusted"*)
                echo
                echo "  ${C_DIM}The module is reporting a fix it cannot actually have. Check the raw"
                echo "  NMEA with:  gpspipe -r | grep -E 'GPGSA|GPGSV|GPRMC'"
                echo "  A genuine receiver emits GPGSV (satellites in view) and lists PRNs in"
                echo "  GPGSA. If those are empty while it claims a 3D fix, don't trust it.${C_RESET}" ;;
            *)
                echo "  ${C_DIM}Cold starts can take several minutes with a clear sky view.${C_RESET}" ;;
        esac
        echo "  ${C_DIM}Use 'pick a saved location' below in the meantime.${C_RESET}"
    fi
    pause
}

use_fix_as_active() {
    echo
    if ! gps_fix 5; then
        echo "  ${C_YELLOW}no usable GPS fix: ${GPS_FIX_REASON}${C_RESET}"
        pause; return 1
    fi
    echo "  ${GPS_MODE}D fix: ${GPS_LAT},${GPS_LON}  (${GPS_USED}/${GPS_SEEN} sats)"
    set_active_location "gps-fix" "$GPS_LAT" "$GPS_LON" "gps"
    pause
}

pick_saved_location() {
    echo
    echo "${C_BOLD}Saved locations${C_RESET}  ${C_DIM}${LOCATIONS_FILE}${C_RESET}"
    echo
    local -a names=() lats=() lons=()
    local n la lo sr ts i=0
    while IFS=$'\t' read -r n la lo sr ts; do
        [[ -n "$n" ]] || continue
        i=$((i+1))
        names+=("$n"); lats+=("$la"); lons+=("$lo")
        printf '  %2d) %-14s %12s, %-13s %s%s  %s%s\n' \
            "$i" "$n" "$la" "$lo" "$C_DIM" "$sr" "$ts" "$C_RESET"
    done < <(list_locations)

    if (( i == 0 )); then
        echo "  ${C_YELLOW}no saved locations.${C_RESET}"
        pause; return 1
    fi

    echo
    printf '  select (or [enter] to cancel): '
    local sel; read -r sel || sel=""
    [[ -n "$sel" ]] || return 0
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        echo "  invalid selection."
        pause; return 1
    fi
    local idx=$((sel-1))
    set_active_location "${names[$idx]}" "${lats[$idx]}" "${lons[$idx]}" "saved"
    pause
}

save_current_position() {
    echo
    local lat lon src

    echo "  1) save the current GPS fix"
    echo "  2) type coordinates by hand"
    printf '  choice: '
    local c; read -r c || c=""

    case "$c" in
        1)
            if ! gps_fix 5; then
                echo "  ${C_YELLOW}no usable GPS fix: ${GPS_FIX_REASON}${C_RESET}"
                pause; return 1
            fi
            lat="$GPS_LAT"; lon="$GPS_LON"
            src="gps"
            ;;
        2)
            printf '  latitude:  '; read -r lat || lat=""
            printf '  longitude: '; read -r lon || lon=""
            src="manual"
            ;;
        *) return 0 ;;
    esac

    if ! [[ "$lat" =~ ^-?[0-9]+(\.[0-9]+)?$ && "$lon" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        echo "  ${C_RED}invalid coordinates: '${lat}' '${lon}'${C_RESET}"
        pause; return 1
    fi

    printf '  name for this location: '
    local name; read -r name || name=""
    name="${name// /-}"
    if [[ -z "$name" ]]; then
        echo "  a name is required."
        pause; return 1
    fi

    if grep -qP "^\Q${name}\E\t" "$LOCATIONS_FILE" 2>/dev/null; then
        if ! confirm "  '${name}' already exists. Replace it?" n; then
            pause; return 0
        fi
        grep -vP "^\Q${name}\E\t" "$LOCATIONS_FILE" > "${LOCATIONS_FILE}.tmp" || true
        mv "${LOCATIONS_FILE}.tmp" "$LOCATIONS_FILE"
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$lat" "$lon" "$src" "$(date -Is)" >> "$LOCATIONS_FILE"
    echo "  ${C_GREEN}saved${C_RESET} ${name}  ${lat},${lon}"
    echo "  ${C_DIM}appended to ${LOCATIONS_FILE}${C_RESET}"

    if confirm "  Make it the active position?" y; then
        set_active_location "$name" "$lat" "$lon" "saved"
    fi
    pause
}

push_position_to_readsb() {
    echo
    echo "${C_BOLD}Push active position into readsb${C_RESET}"
    echo "  ${C_DIM}target file: ${READSB_DEFAULTS}${C_RESET}"

    local act
    if ! act="$(active_location)"; then
        echo "  ${C_YELLOW}no active position set.${C_RESET}"
        pause; return 1
    fi
    local name lat lon
    IFS=$'\t' read -r name lat lon _ _ <<<"$act"

    local cur_lat cur_lon
    cur_lat="$(grep -oP -- '--lat \K[0-9.-]+' "$READSB_DEFAULTS" 2>/dev/null || echo '?')"
    cur_lon="$(grep -oP -- '--lon \K[0-9.-]+' "$READSB_DEFAULTS" 2>/dev/null || echo '?')"

    echo
    echo "    before:  --lat ${cur_lat}  --lon ${cur_lon}"
    echo "    after:   ${C_GREEN}--lat ${lat}  --lon ${lon}${C_RESET}   (${name})"
    echo
    echo "  ${C_DIM}readsb reads this at startup only, so it will be restarted.${C_RESET}"

    if ! confirm "  Write and restart readsb?" n; then
        echo "  aborted — ${READSB_DEFAULTS} untouched."
        pause; return 0
    fi

    local bak="${READSB_DEFAULTS}.bak"
    $SUDO cp -a "$READSB_DEFAULTS" "$bak"
    echo "  ${C_DIM}backup: ${bak}${C_RESET}"

    # readsb-set-location validates the range, rewrites DECODER_OPTIONS and restarts readsb.
    echo "  ${C_DIM}\$ readsb-set-location ${lat} ${lon}${C_RESET}"
    $SUDO readsb-set-location "$lat" "$lon" | sed 's/^/  /'

    echo
    echo "  now: $(grep -oP -- '--lat [0-9.-]+ --lon [0-9.-]+' "$READSB_DEFAULTS" || true)"
    echo "  readsb $(svc_state readsb)"
    pause
}

# ==========================================================================
# frequency reference
# ==========================================================================

FREQ_FILE="${CONF_DIR}/frequencies.txt"

# $3/$4 rename columns 2 and 4, $5/$6 set their widths — the voice tables carry
# operator names and short notes rather than region/decoder, and need different room.
show_freq_table() {
    local title="$1" data="$2" h2="${3:-REGION}" h4="${4:-DECODER}" w2="${5:-13}" w3="${6:-46}"
    echo
    echo "  ${C_BOLD}${title}${C_RESET}"
    printf '  %s%-9s %-*s %-*s %s%s\n' "$C_DIM" "MHz" "$w2" "$h2" "$w3" "USE" "$h4" "$C_RESET"
    local f r d t
    while IFS='|' read -r f r d t; do
        [[ -n "$f" ]] || continue
        printf '  %s%-9s%s %-*s %-*s %s%s%s\n' \
            "$C_CYAN" "$f" "$C_RESET" "$w2" "$r" "$w3" "$d" "$C_DIM" "$t" "$C_RESET"
    done <<<"$data"
}

# Both voice tables, in the order you'd actually tune them.
show_voice_tables() {
    show_freq_table "CYVR voice - ATC (AM airband)" "$FREQ_VOICE_ATC" \
        "SERVICE" "NOTES" 14 34
    show_freq_table "CYVR voice - company + ground ops" "$FREQ_VOICE_OPS" \
        "OPERATOR" "NOTES" 20 34
}

# The two quirks below are the whole reason this screen is worth having — both
# fail silently or confusingly if you get them wrong from another tool.
freq_note_acars() {
    echo
    echo "  ${C_YELLOW}acarsdec takes MHz${C_RESET}, and all channels must fit inside its 2.0 MS/s"
    echo "  tuner window — a span over ~2 MHz aborts with \"Frequencies too far apart\"."
    echo "  ${C_DIM}\$ acarsdec -o 2 -r 0 ${ACARS_FREQS}${C_RESET}"
    echo "  ${C_DIM}  (that set spans 1.525 MHz — menu option 4 runs exactly this)${C_RESET}"
}

freq_note_vdl2() {
    echo
    echo "  ${C_YELLOW}dumpvdl2 takes Hz, NOT MHz.${C_RESET} Passing 136.975 is accepted silently and"
    echo "  tunes to 136 Hz, decoding nothing. Always use the full 136975000 form."
    echo "  ${C_DIM}\$ dumpvdl2 --rtlsdr 0 ${VDL2_FREQS}${C_RESET}"
    echo "  ${C_DIM}  (menu option 5 runs exactly this)${C_RESET}"
}

freq_note_voice() {
    echo
    echo "  ${C_YELLOW}Airband voice is AM, not FM${C_RESET} — rtl_fm defaults to FM and gives you"
    echo "  nothing but hiss on these. Always pass -M am."
    echo
    echo "  ${C_DIM}one channel (ATIS is transmitting 24/7, so it's the honest test):${C_RESET}"
    echo "  ${C_DIM}\$ rtl_fm -M am -f ${VOICE_ATIS_FREQ} -s ${VOICE_SAMP} -g 40 -l 0 - | \\"
    echo "      aplay -r ${VOICE_SAMP} -f S16_LE -t raw -c 1${C_RESET}"
    echo
    echo "  ${C_DIM}scan several (squelch must be non-zero or it parks on the first):${C_RESET}"
    echo "  ${C_DIM}\$ rtl_fm -M am -f ${VOICE_SCAN_FREQS// / -f } -s ${VOICE_SAMP} -l ${VOICE_SQUELCH} - | \\"
    echo "      aplay -r ${VOICE_SAMP} -f S16_LE -t raw -c 1${C_RESET}"
    echo
    echo "  rtl_fm takes the radio exclusively, same as the decoders — stop readsb first"
    echo "  (menu option 2) and make sure the SDR rail is on."
    echo "  ${C_DIM}Source: ~/Radio-Ref-QueryResult.csv, the CYVR block. Receive only.${C_RESET}"
}

freq_note_adsb() {
    echo
    echo "  1090 MHz is handled by readsb (menu option 1); rtl_adsb (option 6) shows raw"
    echo "  frames. 1030 MHz is the ground-to-air interrogation side — you'd need a second"
    echo "  radio to watch both. 978 MHz UAT is US-only, so it's not useful here."
}

write_freq_file() {
    {
        echo "Aeronautical frequency reference — generated by groundcontrol.sh"
        echo "Host: $(hostname)    Written: $(date -Is)"
        echo
        local f r d t
        printf '%s\n' "== ADS-B / Mode S =="
        printf '%-10s %-14s %-48s %s\n' "MHz" "REGION" "USE" "DECODER"
        while IFS='|' read -r f r d t; do [[ -n "$f" ]] && printf '%-10s %-14s %-48s %s\n' "$f" "$r" "$d" "$t"; done <<<"$FREQ_ADSB"
        echo
        printf '%s\n' "== ACARS (VHF) =="
        printf '%-10s %-14s %-48s %s\n' "MHz" "REGION" "USE" "DECODER"
        while IFS='|' read -r f r d t; do [[ -n "$f" ]] && printf '%-10s %-14s %-48s %s\n' "$f" "$r" "$d" "$t"; done <<<"$FREQ_ACARS"
        echo
        printf '%s\n' "== VDL Mode 2 =="
        printf '%-10s %-14s %-48s %s\n' "MHz" "REGION" "USE" "DECODER"
        while IFS='|' read -r f r d t; do [[ -n "$f" ]] && printf '%-10s %-14s %-48s %s\n' "$f" "$r" "$d" "$t"; done <<<"$FREQ_VDL2"
        echo
        printf '%s\n' "== CYVR voice - ATC (AM airband, no decoder) =="
        printf '%-10s %-16s %-36s %s\n' "MHz" "SERVICE" "USE" "NOTES"
        while IFS='|' read -r f r d t; do [[ -n "$f" ]] && printf '%-10s %-16s %-36s %s\n' "$f" "$r" "$d" "$t"; done <<<"$FREQ_VOICE_ATC"
        echo
        printf '%s\n' "== CYVR voice - company + ground ops =="
        printf '%-10s %-22s %-36s %s\n' "MHz" "OPERATOR" "USE" "NOTES"
        while IFS='|' read -r f r d t; do [[ -n "$f" ]] && printf '%-10s %-22s %-36s %s\n' "$f" "$r" "$d" "$t"; done <<<"$FREQ_VOICE_OPS"
        echo
        echo "== Ready-to-run commands =="
        echo "ADS-B  : systemctl start readsb tar1090      # web map on :${TAR1090_PORT}"
        echo "         viewadsb --net-connector 127.0.0.1,${BEAST_PORT},beast_in"
        echo "         rtl_adsb                            # raw frames"
        echo "ACARS  : acarsdec -o 2 -r 0 ${ACARS_FREQS}"
        echo "VDL2   : dumpvdl2 --rtlsdr 0 ${VDL2_FREQS}"
        echo "Voice  : rtl_fm -M am -f ${VOICE_ATIS_FREQ} -s ${VOICE_SAMP} -g 40 -l 0 - | aplay -r ${VOICE_SAMP} -f S16_LE -t raw -c 1"
        echo "         rtl_fm -M am -f ${VOICE_SCAN_FREQS// / -f } -s ${VOICE_SAMP} -l ${VOICE_SQUELCH} - | aplay -r ${VOICE_SAMP} -f S16_LE -t raw -c 1"
        echo
        echo "== Gotchas =="
        echo "* acarsdec wants MHz; all channels must sit inside a ~2 MHz window"
        echo "  (2.0 MS/s tuner) or it exits with 'Frequencies too far apart'."
        echo "* dumpvdl2 wants Hz. '136.975' is taken as 136 Hz and decodes nothing."
        echo "* Airband voice is AM: rtl_fm needs -M am, its FM default hears nothing."
        echo "* rtl_fm only hops between multiple -f channels when squelch (-l) is set."
        echo "* Only one process can hold the RTL-SDR at a time — stop readsb first."
    } > "$FREQ_FILE"
    echo
    echo "  ${C_GREEN}written${C_RESET} ${FREQ_FILE}"
    echo "  ${C_DIM}$(wc -l < "$FREQ_FILE") lines — plain text, for use from your other tools${C_RESET}"
}

freq_menu() {
    while true; do
        draw_header
        echo "  ${C_BOLD}Frequency reference${C_RESET}"
        echo
        echo "   1) ADS-B / Mode S"
        echo "   2) ACARS  (VHF)"
        echo "   3) VDL Mode 2"
        echo "   4) CYVR voice — ATC          ${C_DIM}(tower / ground / ATIS / terminal)${C_RESET}"
        echo "   5) CYVR voice — company ops  ${C_DIM}(airline, FBO, heli)${C_RESET}"
        echo "   6) Everything"
        echo "   7) Write to ${FREQ_FILE/#$HOME/\~}"
        echo "   b) Back"
        printf '\n  Select: '
        local c; read -r c || c="b"
        case "$c" in
            1) show_freq_table "ADS-B / Mode S" "$FREQ_ADSB"; freq_note_adsb; pause ;;
            2) show_freq_table "ACARS (VHF)"    "$FREQ_ACARS"; freq_note_acars; pause ;;
            3) show_freq_table "VDL Mode 2"     "$FREQ_VDL2";  freq_note_vdl2;  pause ;;
            4) show_freq_table "CYVR voice - ATC (AM airband)" "$FREQ_VOICE_ATC" \
                   "SERVICE" "NOTES" 14 34
               freq_note_voice; pause ;;
            5) show_freq_table "CYVR voice - company + ground ops" "$FREQ_VOICE_OPS" \
                   "OPERATOR" "NOTES" 20 34
               freq_note_voice; pause ;;
            6) show_freq_table "ADS-B / Mode S" "$FREQ_ADSB"
               show_freq_table "ACARS (VHF)"    "$FREQ_ACARS"
               show_freq_table "VDL Mode 2"     "$FREQ_VDL2"
               show_voice_tables
               freq_note_acars; freq_note_vdl2; freq_note_voice; pause ;;
            7) write_freq_file; pause ;;
            b|B|q|Q) return 0 ;;
            *) ;;
        esac
    done
}

gps_menu() {
    while true; do
        draw_header
        echo "  ${C_BOLD}GPS / location manager${C_RESET}"
        echo
        echo "   1) Enable GPS rail + gpsd, wait for a fix"
        echo "   2) Use current GPS fix as active position"
        echo "   3) Pick a saved location"
        echo "   4) Save a position (GPS or manual) under a name"
        echo "   5) Push active position into readsb"
        echo "   6) Show live GPS (cgps)"
        echo "   7) Turn GPS rail off"
        echo "   b) Back"
        echo
        echo "  ${C_DIM}saved:  ${LOCATIONS_FILE}${C_RESET}"
        echo "  ${C_DIM}active: ${ACTIVE_FILE}${C_RESET}"
        echo "  ${C_DIM}readsb: ${READSB_DEFAULTS}  (--lat/--lon in DECODER_OPTIONS)${C_RESET}"
        printf '\n  Select: '
        local c; read -r c || c="b"
        case "$c" in
            1) enable_gps ;;
            2) use_fix_as_active ;;
            3) pick_saved_location ;;
            4) save_current_position ;;
            5) push_position_to_readsb ;;
            6) if svc_active gpsd; then cgps || true
               else echo; echo "  gpsd is not running (option 1 first)."; pause; fi ;;
            7) echo; $SUDO systemctl stop gpsd gpsd.socket || true
               set_rail GPS off; pause ;;
            b|B|q|Q) return 0 ;;
            *) ;;
        esac
    done
}

# ==========================================================================
# power rails
# ==========================================================================

rails_menu() {
    while true; do
        draw_header
        echo "  ${C_BOLD}Power rails${C_RESET}  ${C_DIM}(aiov2_ctl)${C_RESET}"
        echo
        printf '   1) SDR   %s %s\n' "$(dot "$RAIL_SDR")"  "$RAIL_SDR"
        printf '   2) GPS   %s %s\n' "$(dot "$RAIL_GPS")"  "$RAIL_GPS"
        printf '   3) LORA  %s %s\n' "$(dot "$RAIL_LORA")" "$RAIL_LORA"
        printf '   4) USB   %s %s\n' "$(dot "$RAIL_USB")"  "$RAIL_USB"
        echo "   s) Full aiov2_ctl --status"
        echo "   b) Back"
        printf '\n  Select a rail to toggle: '
        local c; read -r c || c="b"

        local feature="" cur=""
        case "$c" in
            1) feature=SDR;  cur="$RAIL_SDR"  ;;
            2) feature=GPS;  cur="$RAIL_GPS"  ;;
            3) feature=LORA; cur="$RAIL_LORA" ;;
            4) feature=USB;  cur="$RAIL_USB"  ;;
            s|S) echo; aiov2_ctl --status | sed 's/^/  /'; pause; continue ;;
            b|B|q|Q) return 0 ;;
            *) continue ;;
        esac

        local target
        [[ "$cur" == "ON" ]] && target=off || target=on

        echo
        # Killing the SDR rail out from under readsb is what causes the crash loop.
        if [[ "$feature" == "SDR" && "$target" == "off" ]] && svc_active readsb; then
            echo "  ${C_YELLOW}readsb is running and will start crash-looping without the SDR rail.${C_RESET}"
            if confirm "  Stop readsb + tar1090 as well?" y; then
                $SUDO systemctl stop readsb tar1090 || true
            fi
        fi
        set_rail "$feature" "$target"
        sleep 1
    done
}

# ==========================================================================
# main
# ==========================================================================

seed_locations

while true; do
    draw_header
    echo "   1) Start ADS-B receiver + web map"
    echo "   2) Stop ADS-B receiver"
    echo "   3) viewadsb        ${C_DIM}(CLI table, runs alongside readsb)${C_RESET}"
    echo "   4) ACARS decoder   ${C_DIM}(acarsdec — takes the radio)${C_RESET}"
    echo "   5) VDL Mode 2      ${C_DIM}(dumpvdl2 — takes the radio)${C_RESET}"
    echo "   6) rtl_adsb raw    ${C_DIM}(takes the radio)${C_RESET}"
    echo "   7) Kismet ADS-B    ${C_DIM}(takes the radio)${C_RESET}"
    echo "   8) GPS / location manager  ▸"
    echo "   9) Power rails             ▸"
    echo "   f) Frequency reference     ▸  ${C_DIM}(ADS-B / ACARS / VDL2)${C_RESET}"
    echo "   s) Full status                          q) Quit"
    printf '%s────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
    printf '  Select: '

    choice=""
    read -r choice || choice="q"

    case "$choice" in
        1) start_receiver ;;
        2) stop_receiver ;;
        3) run_viewadsb ;;
        4) # shellcheck disable=SC2086
           run_exclusive_tool "ACARS decoder" acarsdec -o 2 -r 0 $ACARS_FREQS ;;
        5) # shellcheck disable=SC2086
           run_exclusive_tool "VDL Mode 2" dumpvdl2 --rtlsdr 0 $VDL2_FREQS ;;
        6) run_exclusive_tool "rtl_adsb (raw)" rtl_adsb ;;
        7) run_kismet ;;
        8) gps_menu ;;
        9) rails_menu ;;
        f|F) freq_menu ;;
        s|S) echo; aiov2_ctl --status | sed 's/^/  /'; pause ;;
        q|Q) clear; echo "bye."; exit 0 ;;
        *) ;;
    esac
done
