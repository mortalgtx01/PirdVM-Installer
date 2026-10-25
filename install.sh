
#!/usr/bin/env bash
# PirdVM Panel V1.0 - Direct Installer
set -Eeuo pipefail

RED='\033[1;31m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
NC='\033[0m'

INSTALL_DIR="/opt/gkvm"
SERVICE_NAME="gkvm"
SERVICE_USER="gkvm"
PANEL_PORT="${PANEL_PORT:-8080}"

LICENSE_SERVER_URL="https://arinjay01.pythonanywhere.com"
PANEL_DOWNLOAD_URL="${LICENSE_SERVER_URL}/download/gkvm-panel.tar.gz"

TMP_DIR="$(mktemp -d /tmp/pirdvm.XXXXXX)"
ARCHIVE="$TMP_DIR/pirdvm-panel.tar.gz"

trap 'rm -rf "$TMP_DIR"' EXIT

info() {
    echo -e "${CYAN}[INFO] $*${NC}"
}

success() {
    echo -e "${GREEN}[OK] $*${NC}"
}

error() {
    echo -e "${RED}[ERROR] $*${NC}" >&2
    exit 1
}

[[ "$EUID" -eq 0 ]] || error "Run as root: sudo bash install.sh"

command -v apt-get >/dev/null 2>&1 || \
    error "Ubuntu/Debian required."

command -v systemctl >/dev/null 2>&1 || \
    error "Systemd VPS required."

[[ "$(uname -m)" == "x86_64" ]] || \
    error "x86_64 architecture required."

cat <<'BANNER'

  ██████╗ ██╗██████╗ ██████╗ ██╗   ██╗███╗   ███╗
  ██╔══██╗██║██╔══██╗██╔══██╗██║   ██║████╗ ████║
  ██████╔╝██║██████╔╝██║  ██║██║   ██║██╔████╔██║
  ██╔═══╝ ██║██╔══██╗██║  ██║╚██╗ ██╔╝██║╚██╔╝██║
  ██║     ██║██║  ██║██████╔╝ ╚████╔╝ ██║ ╚╝ ██║
  ╚═╝     ╚═╝╚═╝  ╚═╝╚═════╝   ╚═══╝  ╚═╝     ╚═╝

                  PIRDVM PANEL V1.0

BANNER

info "Starting PirdVM installation..."

export DEBIAN_FRONTEND=noninteractive

# ============================================================
# SYSTEM PACKAGES
# ============================================================

info "Updating packages..."

apt-get update -y

info "Installing dependencies..."

apt-get install -y \
    curl \
    ca-certificates \
    gnupg \
    build-essential \
    python3 \
    sqlite3 \
    libsqlite3-dev \
    qemu-system-x86 \
    qemu-utils \
    cloud-image-utils \
    genisoimage \
    xorriso \
    bridge-utils \
    net-tools \
    unzip \
    rsync \
    lsof \
    procps \
    iproute2 \
    sudo

success "Dependencies installed."

# ============================================================
# NODE.JS
# ============================================================

NEED_NODE=1

if command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
    if [[ "$NODE_MAJOR" -ge 22 ]]; then
        NEED_NODE=0
    fi
fi

if [[ "$NEED_NODE" -eq 1 ]]; then
    info "Installing Node.js 22..."

    curl -fsSL \
        https://deb.nodesource.com/setup_22.x \
        -o "$TMP_DIR/nodesource.sh"

    bash "$TMP_DIR/nodesource.sh"
    apt-get install -y nodejs
fi

success "Node.js $(node -v)"

# ============================================================
# DIRECT PANEL DOWNLOAD - NO ARTIFACT KEY
# ============================================================

info "Downloading PirdVM Panel directly..."

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --connect-timeout 20 \
    --max-time 600 \
    "$PANEL_DOWNLOAD_URL" \
    -o "$ARCHIVE" || \
    error "Panel download failed."

[[ -s "$ARCHIVE" ]] || \
    error "Downloaded archive is empty."

tar -tzf "$ARCHIVE" >/dev/null 2>&1 || \
    error "Invalid panel archive."

success "Panel downloaded."

# ============================================================
# EXTRACT PANEL
# ============================================================

info "Extracting panel..."

mkdir -p "$TMP_DIR/extracted"

tar -xzf "$ARCHIVE" -C "$TMP_DIR/extracted" \
    --no-same-owner \
    --no-same-permissions

SOURCE_DIR="$TMP_DIR/extracted"

if [[ ! -f "$SOURCE_DIR/package.json" ]]; then
    PACKAGE_FILE="$(
        find "$SOURCE_DIR" \
            -maxdepth 3 \
            -type f \
            -name package.json \
            -not -path '*/node_modules/*' \
            -print -quit
    )"

    [[ -n "$PACKAGE_FILE" ]] || \
        error "package.json missing from panel archive."

    SOURCE_DIR="$(dirname "$PACKAGE_FILE")"
fi

[[ -f "$SOURCE_DIR/app.js" ]] || \
    error "app.js missing from panel archive."

success "Panel extracted."

# ============================================================
# PANEL USER
# ============================================================

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd \
        --system \
        --create-home \
        --shell /usr/sbin/nologin \
        "$SERVICE_USER"
fi

if getent group kvm >/dev/null 2>&1; then
    usermod -aG kvm "$SERVICE_USER"
fi

# ============================================================
# BACKUP OLD INSTALLATION
# ============================================================

if [[ -f "$INSTALL_DIR/app.js" ]]; then
    info "Backing up existing panel data..."

    BACKUP_DIR="/opt/pirdvm-backup-$(date +%Y%m%d-%H%M%S)"

    mkdir -p "$BACKUP_DIR"

    if [[ -f "$INSTALL_DIR/.env" ]]; then
        cp -a "$INSTALL_DIR/.env" "$BACKUP_DIR/"
    fi

    if [[ -d "$INSTALL_DIR/data" ]]; then
        cp -a "$INSTALL_DIR/data" "$BACKUP_DIR/"
    fi

    success "Backup: $BACKUP_DIR"
fi

# ============================================================
# INSTALL PANEL
# ============================================================

info "Installing panel..."

systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

mkdir -p "$INSTALL_DIR/data"

rsync -a \
    --exclude='.env' \
    --exclude='data/' \
    --exclude='node_modules/' \
    --exclude='.git/' \
    "$SOURCE_DIR/" \
    "$INSTALL_DIR/"

success "Panel files installed."

# ============================================================
# ENVIRONMENT
# ============================================================

ENV_FILE="$INSTALL_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    SESSION_SECRET="$(
        node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
    )"

    cat > "$ENV_FILE" <<EOF
PORT=$PANEL_PORT
NODE_ENV=production
PANEL_NAME=PirdVM Panel
PANEL_VERSION=V1.0
VNM_DATA_DIR=$INSTALL_DIR/data
SESSION_SECRET=$SESSION_SECRET
LICENSE_SERVER_URL=$LICENSE_SERVER_URL
LICENSE_PRODUCT=PIRDVM-PANEL
LICENSE_GRACE_PERIOD=86400
EOF

else
    info "Updating existing panel configuration..."

    python3 - "$ENV_FILE" "$PANEL_PORT" <<'PYENV'
from pathlib import Path
import sys

p = Path(sys.argv[1])
port = sys.argv[2]

values = {
    "PORT": port,
    "NODE_ENV": "production",
    "PANEL_NAME": "PirdVM Panel",
    "PANEL_VERSION": "V1.0",
    "LICENSE_SERVER_URL": "https://arinjay01.pythonanywhere.com",
    "LICENSE_PRODUCT": "PIRDVM-PANEL",
    "LICENSE_GRACE_PERIOD": "86400",
}

lines = p.read_text().splitlines()

for key, value in values.items():
    found = False
    updated = []

    for line in lines:
        if line.startswith(key + "="):
            updated.append(f"{key}={value}")
            found = True
        else:
            updated.append(line)

    if not found:
        updated.append(f"{key}={value}")

    lines = updated

p.write_text("\n".join(lines) + "\n")
PYENV
fi

chmod 600 "$ENV_FILE"

# ============================================================
# NPM DEPENDENCIES
# ============================================================

info "Installing Node.js dependencies..."

cd "$INSTALL_DIR"

if [[ -f package-lock.json ]]; then
    npm ci --omit=dev
else
    npm install --omit=dev
fi

success "NPM dependencies installed."

# ============================================================
# PERMISSIONS
# ============================================================

chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
chmod 600 "$ENV_FILE"

# ============================================================
# SYSTEMD SERVICE
# ============================================================

info "Creating systemd service..."

NODE_BIN="$(command -v node)"

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=PirdVM Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$NODE_BIN $INSTALL_DIR/app.js
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

sleep 3

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true
    error "PirdVM service failed to start."
fi

success "PirdVM service started."

# ============================================================
# FIREWALL
# ============================================================

if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
fi

if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd \
        --permanent \
        --add-port="${PANEL_PORT}/tcp" \
        >/dev/null 2>&1 || true

    firewall-cmd --reload >/dev/null 2>&1 || true
fi

# ============================================================
# DONE
# ============================================================

PUBLIC_IP="$(
    curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null ||
    hostname -I 2>/dev/null | awk '{print $1}'
)"

PUBLIC_IP="${PUBLIC_IP:-YOUR_SERVER_IP}"

echo
echo "============================================================"
echo -e "${GREEN}      PIRDVM PANEL INSTALLATION COMPLETE${NC}"
echo "============================================================"
echo
echo "Panel URL: http://${PUBLIC_IP}:${PANEL_PORT}"
echo "Install:   $INSTALL_DIR"
echo "Service:   $SERVICE_NAME"
echo
echo "Useful commands:"
echo "  systemctl status $SERVICE_NAME"
echo "  systemctl restart $SERVICE_NAME"
echo "  journalctl -u $SERVICE_NAME -f"
echo
echo "============================================================"
