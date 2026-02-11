#!/bin/bash
# geodata-update.sh Adapted for Debian 13
# Debian 13: download and convert geoip.dat/geosite.dat → SRS for sing-box
# Data stored in /etc/sing-box/geodata

set -euo pipefail

# ===== CONFIGURATION =====
OUTPUT_DIR="/etc/sing-box/geodata"
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
GEODAT2SRS_REPO="https://github.com/runetfreedom/geodat2srs.git"
GEODAT2SRS_BIN="/usr/local/bin/geodat2srs"
TEMP_DIR="$(mktemp -d)"

QUIET=false
LOG_FILE="/var/log/sing-box/geodata-update.log"

# ===== FUNCTIONS =====
log() {
    local msg="[+] $(date '+%Y-%m-%d %H:%M:%S') $1"
    $QUIET || echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

error() {
    local msg="[!] $(date '+%Y-%m-%d %H:%M:%S') $1"
    echo "$msg" >&2
    echo "$msg" >> "$LOG_FILE"
    exit 1
}

cleanup() {
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# ===== CHECK ROOT ACCESS =====
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Script requires root. Run with sudo or under the root account: $0"
    fi

    # Create directories for logs
    install -d -m 755 -o root -g root "/var/log/sing-box"
    install -d -m 755 -o root -g root "/etc/sing-box"
}

# ===== DEPENDENCIES =====
install_dependencies() {
    local missing=()

    command -v curl &>/dev/null || missing+=("curl")
    command -v git &>/dev/null || missing+=("git")
    command -v sing-box &>/dev/null || missing+=("sing-box")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "Installing required dependencies: ${missing[*]}"
        apt-get update -qq
        apt-get install -y -qq "${missing[@]}" || error "Failed to install dependencies"
    fi

    # Install Go to build geodat2srs
    if [[ ! -x "$GEODAT2SRS_BIN" ]] && ! command -v go &>/dev/null; then
        log "Installing Go to build geodat2srs..."
        apt-get install -y -qq golang-go || error "Failed to install golang-go"
    fi
}

# ===== Installing geodat2srs =====
install_geodat2srs() {
    if [[ -x "$GEODAT2SRS_BIN" ]]; then
        log "geodat2srs is already installed: $GEODAT2SRS_BIN"
        return 0
    fi

    log "Building geodat2srs from $GEODAT2SRS_REPO..."

    git clone --depth=1 "$GEODAT2SRS_REPO" "$TEMP_DIR/geodat2srs-src"
    cd "$TEMP_DIR/geodat2srs-src"

    go build -o "$GEODAT2SRS_BIN" . || error "Error while building geodat2srs"
    chmod 755 "$GEODAT2SRS_BIN"

    log "geodat2srs installed: $GEODAT2SRS_BIN"
}

# ===== DOWNLOAD GEODATA =====
download_geodata() {
    log "Downloading geodata..."

    curl -fsSL --connect-timeout 30 -o "$TEMP_DIR/geoip.dat" "$GEOIP_URL" \
        || error "Failed to download geoip.dat"

    curl -fsSL --connect-timeout 30 -o "$TEMP_DIR/geosite.dat" "$GEOSITE_URL" \
        || error "Failed to download geosite.dat"

    log "Geodata downloaded: $(du -h "$TEMP_DIR"/*.dat | awk '{print $1}' | paste -sd ' ')"
}

# ===== CONVERSION =====
convert_to_srs() {
    log "Converting to SRS format..."
    install -d -m 755 -o root -g root "$OUTPUT_DIR"

    # Convert geoip
    "$GEODAT2SRS_BIN" geoip \
        -i "$TEMP_DIR/geoip.dat" \
        -o "$OUTPUT_DIR" \
        --prefix "geoip-" \
        || error "Error while converting geoip.dat"

    # Convert geosite
    "$GEODAT2SRS_BIN" geosite \
        -i "$TEMP_DIR/geosite.dat" \
        -o "$OUTPUT_DIR" \
        --prefix "geosite-" \
        || error "Error while converting geosite.dat"

    # Set access rules
    chown -R root:root "$OUTPUT_DIR"
    chmod -R 644 "$OUTPUT_DIR"/*.srs
    chmod 755 "$OUTPUT_DIR"

    local count=$(find "$OUTPUT_DIR" -name '*.srs' | wc -l)
    log "Created $count SRS files in $OUTPUT_DIR"
}

# ===== ARGUMENTS PARSING =====
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -q|--quiet) QUIET=true; shift ;;
            *) shift ;;
        esac
    done
}

# ===== RESTART SING-BOX =====
reload_singbox() {
    if ! systemctl is-active --quiet sing-box 2>/dev/null; then
        log "sing-box is not running — skipping restart step..."
        return 0
    fi

    log "Reloading geodata with systemctl reload..."
    if systemctl reload sing-box 2>>"$LOG_FILE"; then
        log "✅ sing-box successfully reloaded geodata files"
    else
        log "systemctl reload failed, trying with SIGHUP"
        local pid
        pid=$(pidof sing-box) || error "sing-box process not found"
        kill -HUP "$pid" 2>>"$LOG_FILE" || error "Failed to send SIGHUP"
        log "✅ sing-box successfully reloaded geodata after SIGHUP"
    fi
}

# ===== MAIN WORKFLOW =====
main() {
    parse_args "$@"
    check_root
    install_dependencies
    install_geodat2srs
    download_geodata
    convert_to_srs

    log "✅ Geodata update complete"
    reload_singbox

    # Print statistics if not in quiet mode
    if ! $QUIET; then
        echo -e "\nContent of $OUTPUT_DIR:"
        ls -lh "$OUTPUT_DIR" | head -15 | awk 'NR==1 || /srs$/ {printf "  %s %s %s\n", $5, $6, $9}'
        echo -e "\nConnection example for /etc/sing-box/config.json:"
        echo '  "route": {'
        echo '    "rule_set": ['
        echo '      {'
        echo '        "tag": "geoip-ru",'
        echo '        "type": "local",'
        echo '        "path": "/etc/sing-box/geodata/geoip-ru.srs"'
        echo '      },'
        echo '      {'
        echo '        "tag": "geosite-ru",'
        echo '        "type": "local",'
        echo '        "path": "/etc/sing-box/geodata/geosite-ru.srs"'
        echo '      }'
        echo '    ],'
        echo '    "rules": ['
        echo '      {'
        echo '        "rule_set": ["geoip-ru", "geosite-ru"],'
        echo '        "outbound": "direct"'
        echo '      }'
        echo '    ]'
        echo '  }'
    fi
}

main "$@"
