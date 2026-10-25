#!/usr/bin/env bash
# PIRDVM PANEL V1.0 - Customer Installer
set -Eeuo pipefail

RED='\e[1;31m'
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
CYAN='\e[1;36m'
MAGENTA='\e[1;35m'
NC='\e[0m'

APP_NAME='PirdVM Panel V1.0'
SERVICE_NAME='gkvm'
INSTALL_DIR='/opt/gkvm'
SERVICE_USER='gkvm'
PANEL_PORT="${PANEL_PORT:-8080}"
NODE_MAJOR=22

LICENSE_SERVER_URL='https://arinjay01.pythonanywhere.com'
LICENSE_PRODUCT='PIRDVM-PANEL'
LICENSE_GRACE_PERIOD=86400

ARTIFACT_URL="${ARTIFACT_URL:-https://arinjay01.pythonanywhere.com/download/gkvm-panel.tar.gz}"
ARTIFACT_KEY="${ARTIFACT_KEY:-}"

TMP_DIR="$(mktemp -d /tmp/pirdvm-install.XXXXXX)"
ARCHIVE="${TMP_DIR}/pirdvm-panel.tar.gz"
LOG_FILE='/var/log/gkvm.log'
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

die() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

info() {
    echo -e "${CYAN}[INFO]${NC} $*"
}

ok() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

line() {
    echo -e "${MAGENTA}============================================================${NC}"
}

# ============================================================
# BASIC CHECKS
# ============================================================

[[ $EUID -eq 0 ]] || die 'Please run as root.'

command -v systemctl >/dev/null 2>&1 || \
    die 'This installer requires a VPS with systemd.'

[[ -f /etc/os-release ]] || die 'Unsupported operating system.'
source /etc/os-release

ARCH="$(uname -m)"

case "$ARCH" in
    x86_64|amd64)
        ;;
    *)
        die "Unsupported architecture for this KVM panel: $ARCH"
        ;;
esac

# ============================================================
# BANNER
# ============================================================

printf '%b' "$CYAN"

cat <<'BANNER'

  ██████╗ ██╗██████╗ ██████╗ ██╗   ██╗███╗   ███╗
  ██╔══██╗██║██╔══██╗██╔══██╗██║   ██║████╗ ████║
  ██████╔╝██║██████╔╝██║  ██║██║   ██║██╔████╔██║
  ██╔═══╝ ██║██╔══██╗██║  ██║╚██╗ ██╔╝██║╚██╔╝██║
  ██║     ██║██║  ██║██████╔╝ ╚████╔╝ ██║ ╚═╝ ██║
  ╚═╝     ╚═╝╚═╝  ╚═╝╚═════╝   ╚═══╝  ╚═╝     ╚═╝

                  PIRDVM PANEL V1.0

BANNER

printf '%b\n' "$NC"
line

info "OS: ${PRETTY_NAME:-$ID}"
info "Architecture: $ARCH"
info "Panel Port: $PANEL_PORT"
info "License Server: $LICENSE_SERVER_URL"

# ============================================================
# ARTIFACT AUTHENTICATION
# ============================================================

if [[ -z "$ARTIFACT_KEY" ]]; then
    if [[ -t 0 ]]; then
        read -r -s -p 'Enter PirdVM artifact key: ' ARTIFACT_KEY
        echo
    else
        die 'Set ARTIFACT_KEY before running non-interactively.'
    fi
fi

[[ -n "$ARTIFACT_KEY" ]] || die 'Artifact key is required.'

# ============================================================
# SYSTEM DEPENDENCIES
# ============================================================

export DEBIAN_FRONTEND=noninteractive

if command -v apt-get >/dev/null 2>&1; then

    apt-get update -y

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

elif command -v dnf >/dev/null 2>&1; then

    dnf -y install \
        curl \
        ca-certificates \
        gcc \
        gcc-c++ \
        make \
        python3 \
        sqlite \
        sqlite-devel \
        qemu-system-x86-core \
        qemu-img \
        genisoimage \
        xorriso \
        bridge-utils \
        net-tools \
        unzip \
        rsync \
        lsof \
        procps-ng \
        iproute \
        sudo

else
    die 'Unsupported package manager. Use Ubuntu, Debian or a compatible Linux VPS.'
fi

ok 'System dependencies installed.'

# ============================================================
# NODE.JS INSTALLATION
# ============================================================

if ! command -v node >/dev/null 2>&1 || \
   [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt "$NODE_MAJOR" ]]; then

    info "Installing Node.js ${NODE_MAJOR}..."

    if command -v apt-get >/dev/null 2>&1; then

        curl -fsSL \
            "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" \
            -o "$TMP_DIR/nodesource.sh"

        bash "$TMP_DIR/nodesource.sh"
        apt-get install -y nodejs

    else

        curl -fsSL \
            "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" \
            -o "$TMP_DIR/nodesource.sh"

        bash "$TMP_DIR/nodesource.sh"
        dnf install -y nodejs

    fi
fi

ok "Node: $(node -v)"
ok "NPM: $(npm -v)"

# ============================================================
# SERVICE USER
# ============================================================

if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then

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
# PORT CHECK
# ============================================================

if ! systemctl is-active --quiet "$SERVICE_NAME"; then

    if ss -ltn 2>/dev/null | \
        grep -qE ":${PANEL_PORT}[[:space:]]"; then

        die "Port ${PANEL_PORT} is already in use."
    fi
fi

# ============================================================
# DOWNLOAD PIRDVM ARTIFACT
# ============================================================

info 'Downloading PirdVM Panel...'

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --connect-timeout 15 \
    --max-time 300 \
    -H "X-Artifact-Key: ${ARTIFACT_KEY}" \
    "$ARTIFACT_URL" \
    -o "$ARCHIVE"

[[ -s "$ARCHIVE" ]] || die 'Artifact download is empty.'

ok 'PirdVM artifact downloaded.'

# ============================================================
# VALIDATE ARTIFACT
# ============================================================

info 'Validating PirdVM package...'

tar -tzf "$ARCHIVE" >/dev/null || \
    die 'Invalid panel archive.'

mkdir -p "$TMP_DIR/panel"

tar -xzf "$ARCHIVE" -C "$TMP_DIR/panel"

SOURCE_DIR="$TMP_DIR/panel"

shopt -s nullglob dotglob
entries=("$SOURCE_DIR"/*)

if [[ ${#entries[@]} -eq 1 && \
      -d "${entries[0]}" && \
      -f "${entries[0]}/package.json" ]]; then

    SOURCE_DIR="${entries[0]}"
fi

shopt -u nullglob dotglob

[[ -f "$SOURCE_DIR/package.json" ]] || \
    die 'package.json not found in artifact.'

[[ -f "$SOURCE_DIR/package-lock.json" ]] || \
    die 'package-lock.json not found in artifact.'

[[ -f "$SOURCE_DIR/app.js" ]] || \
    die 'app.js not found in artifact.'

ok 'Panel package validated.'

# ============================================================
# BACKUP EXISTING INSTALLATION
# ============================================================

if [[ -f "$INSTALL_DIR/app.js" ]]; then

    info 'Existing installation detected.'

    BACKUP_DIR="/opt/pirdvm-backup-$(date +%Y%m%d-%H%M%S)"

    mkdir -p "$BACKUP_DIR"

    if [[ -f "$INSTALL_DIR/.env" ]]; then
        cp -a "$INSTALL_DIR/.env" "$BACKUP_DIR/.env"
    fi

    if [[ -d "$INSTALL_DIR/data" ]]; then
        cp -a "$INSTALL_DIR/data" "$BACKUP_DIR/data"
    fi

    ok "Existing configuration and data backed up: $BACKUP_DIR"
fi

# ============================================================
# STOP OLD SERVICE
# ============================================================

systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

# ============================================================
# INSTALL PANEL FILES
# ============================================================

info 'Installing PirdVM Panel...'

mkdir -p "$INSTALL_DIR"

rsync -a --delete \
    --exclude '.env' \
    --exclude 'data/' \
    --exclude 'node_modules/' \
    --exclude '.git/' \
    "$SOURCE_DIR/" \
    "$INSTALL_DIR/"

mkdir -p "$INSTALL_DIR/data"

ok 'Panel files installed.'

# ============================================================
# ENVIRONMENT CONFIGURATION
# ============================================================

ENV_FILE="$INSTALL_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then

    SESSION_SECRET="$(
        node -e \
        "console.log(require('crypto').randomBytes(32).toString('hex'))"
    )"

    ADMIN_PASSWORD="$(
        node -e \
        "console.log(require('crypto').randomBytes(18).toString('base64url'))"
    )"

    cat > "$ENV_FILE" <<EOF_ENV
PORT=${PANEL_PORT}
VNM_DATA_DIR=${INSTALL_DIR}/data
PANEL_NAME=PirdVM Panel
PANEL_VERSION=V1.0
NODE_ENV=production
SESSION_SECRET=${SESSION_SECRET}

LICENSE_SERVER_URL=${LICENSE_SERVER_URL}
LICENSE_PRODUCT=${LICENSE_PRODUCT}
LICENSE_GRACE_PERIOD=${LICENSE_GRACE_PERIOD}

DEFAULT_ADMIN_USERNAME=admin@pirdvm.local
DEFAULT_ADMIN_PASSWORD=${ADMIN_PASSWORD}
EOF_ENV

    chmod 600 "$ENV_FILE"

    printf '%s\n' "$ADMIN_PASSWORD" > \
        "$TMP_DIR/admin-password"

    chmod 600 "$TMP_DIR/admin-password"

    ok 'New PirdVM environment created.'

else

    warn 'Existing .env detected. Preserving credentials and updating branding.'

    python3 - "$ENV_FILE" "$PANEL_PORT" <<'PYENV'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
port = sys.argv[2]

updates = {
    "PORT": port,
    "PANEL_NAME": "PirdVM Panel",
    "PANEL_VERSION": "V1.0",
    "LICENSE_SERVER_URL": "https://arinjay01.pythonanywhere.com",
    "LICENSE_PRODUCT": "PIRDVM-PANEL",
    "LICENSE_GRACE_PERIOD": "86400",
}

lines = path.read_text().splitlines()

for key, value in updates.items():
    found = False
    result = []

    for line in lines:
        if line.startswith(key + "="):
            result.append(f"{key}={value}")
            found = True
        else:
            result.append(line)

    if not found:
        result.append(f"{key}={value}")

    lines = result

path.write_text("\n".join(lines) + "\n")
PYENV

    ok 'Existing environment updated.'
fi

# ============================================================
# INSTALL NODE DEPENDENCIES
# ============================================================

info 'Installing Node.js dependencies...'

cd "$INSTALL_DIR"

npm ci \
    --omit=dev \
    --foreground-scripts

ok 'Node.js dependencies installed.'

# ============================================================
# FILE PERMISSIONS
# ============================================================

info 'Configuring permissions...'

chown -R \
    "${SERVICE_USER}:${SERVICE_USER}" \
    "$INSTALL_DIR"

chmod 600 "$ENV_FILE"

find "$INSTALL_DIR" \
    -type d \
    -exec chmod 755 {} +

touch "$LOG_FILE"

chown \
    "${SERVICE_USER}:${SERVICE_USER}" \
    "$LOG_FILE"

chmod 640 "$LOG_FILE"

ok 'Permissions configured.'

# ============================================================
# FIREWALL
# ============================================================

if command -v ufw >/dev/null 2>&1; then

    ufw allow "${PANEL_PORT}/tcp" \
        >/dev/null 2>&1 || true
fi

if command -v firewall-cmd >/dev/null 2>&1; then

    firewall-cmd \
        --permanent \
        --add-port="${PANEL_PORT}/tcp" \
        >/dev/null 2>&1 || true

    firewall-cmd --reload \
        >/dev/null 2>&1 || true
fi

# ============================================================
# SYSTEMD SERVICE
# ============================================================

info 'Creating PirdVM systemd service...'

NODE_BIN="$(command -v node)"

cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=PirdVM Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${NODE_BIN} ${INSTALL_DIR}/app.js
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
Environment=NODE_ENV=production
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF_SERVICE

# ============================================================
# START PANEL
# ============================================================

systemctl daemon-reload

systemctl enable "$SERVICE_NAME" >/dev/null

systemctl restart "$SERVICE_NAME"

sleep 3

if ! systemctl is-active --quiet "$SERVICE_NAME"; then

    journalctl \
        -u "$SERVICE_NAME" \
        -n 80 \
        --no-pager || true

    die 'PirdVM Panel failed to start.'
fi

ok 'PirdVM service started successfully.'

# ============================================================
# VERIFY PANEL
# ============================================================

info 'Checking local panel response...'

if curl \
    --silent \
    --output /dev/null \
    --max-time 10 \
    "http://127.0.0.1:${PANEL_PORT}/"; then

    ok 'PirdVM Panel is responding.'

else

    warn 'Service is running, but HTTP response could not be confirmed.'
fi

# ============================================================
# PUBLIC IP
# ============================================================

PUBLIC_IP="$(
    curl -4 -fsS \
        --max-time 8 \
        https://api.ipify.org \
        2>/dev/null ||
    hostname -I 2>/dev/null | awk '{print $1}'
)"

PUBLIC_IP="${PUBLIC_IP:-YOUR_SERVER_IP}"

# ============================================================
# INSTALLATION COMPLETE
# ============================================================

echo
line

echo -e "${GREEN}PIRDVM PANEL V1.0 INSTALLED SUCCESSFULLY${NC}"

line

echo
echo "Panel URL:       http://${PUBLIC_IP}:${PANEL_PORT}"
echo "Panel Name:      PirdVM Panel"
echo "Install Path:    ${INSTALL_DIR}"
echo "Service Name:    ${SERVICE_NAME}"
echo "License Server:  ${LICENSE_SERVER_URL}"
echo "License Product: ${LICENSE_PRODUCT}"

echo
echo "Service Commands:"
echo "  systemctl status ${SERVICE_NAME}"
echo "  systemctl restart ${SERVICE_NAME}"
echo "  journalctl -u ${SERVICE_NAME} -f"

echo

if [[ -f "$TMP_DIR/admin-password" ]]; then

    echo -e "${YELLOW}INITIAL ADMIN LOGIN${NC}"
    echo "Username: admin@pirdvm.local"
    echo "Password: $(cat "$TMP_DIR/admin-password")"

    echo
    echo "Save these credentials securely."
    echo "Change your admin password after first login."

else

    echo "Existing admin credentials have been preserved."
fi

echo
line

ok 'PirdVM Panel installation finished.'
