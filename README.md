
# Breaking out of the digital prison 🌩️

<center>
    <img src="https://media.tenor.com/BFpd4oyeH_IAAAAM/mickey-mouse-black-and-white.gif" alt="mickey-mouse-bw" />
</center>

This repository contains instructions for configuring sing-box in http/sock5 proxy mode with traffic separation according to SRS rules. Use it as a starting point for configuring sing-box to suit your needs. The repository includes scripts and configurations for Debian/Ubuntu operating systems.

![GitHub forks](https://img.shields.io/github/forks/maxqwars/debian13-sing-box-proxy-with-routing-setup)
![GitHub Repo stars](https://img.shields.io/github/stars/maxqwars/debian13-sing-box-proxy-with-routing-setup)

## Notice

This repository does not contain ready-made configurations for outbounds, you must configure them yourself or adapt the ones you have. Please adapt the configurations from the examples to your tasks, copy-paste does not work with the configurations from the examples.

## About 📦 sing-box

Sing-box is a universal, open-source proxy platform (written in Go) designed for high-performance network traffic routing, bypassing restrictions, and enhancing privacy. It supports numerous protocols—including VLESS, VMess, Trojan, and WireGuard—and functions as a client or server across multiple platforms, featuring advanced routing capabilities and TUN-based transparent proxying. [website](https://sing-box.sagernet.org/)

## Installing sing-box

Download the latest .deb package from the [official releases](https://github.com/SagerNet/sing-box/releases).

```bash
$ wget https://github.com/SagerNet/sing-box/releases/download/v1.12.21/sing-box_1.12.21_linux_amd64.deb
$ sudo dpkg -i ./sing-box_1.12.21_linux_amd64.deb
```

## Quick setup of scripts from this repository

### Clone repo

```bash
$ git clone https://github.com/maxqwars/debian13-sing-box-proxy-with-routing-setup
$ sudo cd debian13-sing-box-proxy-with-routing-setup
```

### Install geodata-update.sh

```bash
$ sudo install -m 755 <repo>/scripts/geodata-update.sh /usr/local/bin/geodata-update
```

### Install sing-box-geodata.service

```bash
$ sudo cp ./systemd/sing-box-geodata.service /etc/systemd/system/sing-box-geodata.service
```

### Install sing-box-geodata.timer

```bash
$ sudo cp ./systemd/sing-box-geodata.timer /etc/systemd/system/sing-box-geodata.timer
```

### Enable service and timer

```bash
$ sudo systemctl daemon-reload
$ sudo systemctl enable --now sing-box-geodata.timer
```

### Check geodata update

```bash
$ sudo systemctl list-timers sing-box-geodata.timer # Next timer run time
$ sudo journalctl -u sing-box-geodata.service -n 50 --no-pager # Latest update log
```

### Copy sing-box config for adaptation

```bash
$ sudo cp ./configs/config.example.json /etc/sing-box/config.json
```

- ⚠️ **This file does not initially contain settings for outbounds. Add them yourself before launching sing-box.**
- ⚠️ **Always back up your working configuration.**
- ⚠️ **Always verify the correctness of your configuration using sing-box check -c <path_to_config>**

## Special thanks / Useful links

- Documentation sing-box [Link](https://sing-box.sagernet.org/)
- v2ray-rules-dat [Link](https://github.com/Loyalsoldier/v2ray-rules-dat/)
- geodat2srs converter [Link](https://github.com/runetfreedom/geodat2srs)

# How it works, more details about this project

A brief introduction to project files with a description of their contents.

## Getting / Updating rules files

A special shell script is used to obtain and update geodat files. It downloads and converts geodat files from the Loyalsoldier/v2ray-rules-dat repository.

For your convenience and automation, we recommend creating a systemd timer to periodically update geodat files. This script will also restart the sing-box after updating the data.

Below is a list of files that implement this workflow.

### Content of geodata-update.sh

The geodata-update.sh file is needed to automate the process of downloading and converting .dat files for sing-box. Since sing-box itself works with rule sets in .src format, .dat files from other proxy solutions cannot be used with it.

This script downloads geoip and geosite lists so that you can configure routes as you need. This script installs Golang on your system and uses a converter from [runetfreedom](https://github.com/runetfreedom) to adapt them for use. Below is the file content.

```bash
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
```

### Content of sing-box-geodata.service

```
[Unit]
Description=Update sing-box geodata SRS files
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/geodata-update --quiet
User=root
Group=root
StandardOutput=journal
StandardError=journal
```

### Content of sing-box-geodata.timer

```
[Unit]
Description=Weekly update of sing-box geodata
Requires=sing-box-geodata.service

[Timer]
OnCalendar=Sun 04:00
Persistent=true
RandomizedDelaySec=3600

[Install]
WantedBy=timers.target
```
