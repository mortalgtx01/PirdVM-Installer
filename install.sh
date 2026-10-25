#!/usr/bin/env bash
# GKVM PANEL V1.0 - customer installer
set -Eeuo pipefail

RED='\e[1;31m'
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
CYAN='\e[1;36m'
MAGENTA='\e[1;35m'
NC='\e[0m'

APP_NAME='GKVM Panel V1.0'
SERVICE_NAME='gkvm'
INSTALL_DIR='/opt/gkvm'
SERVICE_USER='gkvm'
PANEL_PORT="${PANEL_PORT:-8080}"
NODE_MAJOR=20

# ============================================================
# GKVM PRIVATE ARTIFACT
# ============================================================

ARTIFACT_URL="${ARTIFACT_URL:-https://arinjay01.pythonanywhere.com/download/gkvm-panel.tar.gz}"
ARTIFACT_KEY="${ARTIFACT_KEY:-ILoveYouHitakshi}"

# ============================================================
# TEMP / LOG
# ============================================================

TMP_DIR="$(mktemp -d /tmp/gkvm-install.XXXXXX)"
ARCHIVE="${TMP_DIR}/gkvm-panel.tar.gz"
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

[[ $EUID -eq 0 ]] || die 'Run as root.'

[[ "$ARTIFACT_URL" != *'YOUR-DOWNLOAD-HOST'* ]] || \
    die 'Set ARTIFACT_URL in install.sh before publishing.'

[[ "$ARTIFACT_KEY" != 'CHANGE_ME' ]] || \
    die 'Set ARTIFACT_KEY in install.sh before publishing.'

command -v systemctl >/dev/null 2>&1 || \
    die 'systemd is required.'

source /etc/os-release

ARCH="$(uname -m)"

case "$ARCH" in
    x86_64|amd64|aarch64|arm64)
        ;;
    *)
        die "Unsupported architecture: $ARCH"
        ;;
esac


# ============================================================
# BANNER
# ============================================================

printf '%b' "$CYAN"

cat <<'BANNER'
   ██████╗ ██╗  ██╗██╗   ██╗███╗   ███╗
  ██╔════╝ ██║ ██╔╝██║   ██║████╗ ████║
  ██║  ███╗█████╔╝ ██║   ██║██╔████╔██║
  ██║   ██║██╔═██╗ ╚██╗ ██╔╝██║╚██╔╝██║
  ╚██████╔╝██║  ██╗ ╚████╔╝ ██║ ╚═╝ ██║
   ╚═════╝ ╚═╝  ╚═╝  ╚═══╝  ╚═╝     ╚═╝
                 GKVM PANEL V1.0
BANNER

printf '%b\n' "$NC"

line

info "OS: ${PRETTY_NAME:-$ID} | Arch: $ARCH | Port: $PANEL_PORT"


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

elif command -v yum >/dev/null 2>&1; then

    yum -y install \
        curl \
        ca-certificates \
        gcc \
        gcc-c++ \
        make \
        python3 \
        sqlite \
        sqlite-devel \
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

    die 'Unsupported package manager.'

fi

ok 'System dependencies installed.'


# ============================================================
# NODE.JS
# ============================================================

if ! command -v node >/dev/null 2>&1 || \
   [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt "$NODE_MAJOR" ]]; then

    if command -v apt-get >/dev/null 2>&1; then

        curl -fsSL \
            "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -

        apt-get install -y nodejs

    elif command -v dnf >/dev/null 2>&1; then

        curl -fsSL \
            "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash -

        dnf install -y nodejs

    else

        curl -fsSL \
            "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash -

        yum install -y nodejs

    fi

fi

ok "Node $(node -v), npm $(npm -v)"


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

getent group kvm >/dev/null 2>&1 && \
    usermod -aG kvm "$SERVICE_USER" || true


# ============================================================
# PORT CHECK
# ============================================================

if ss -ltn 2>/dev/null | \
    grep -qE ":${PANEL_PORT}[[:space:]]"; then

    die "Port ${PANEL_PORT} is already in use. Set PANEL_PORT before running the installer."

fi


# ============================================================
# DOWNLOAD ARTIFACT
# ============================================================

info 'Downloading GKVM Panel artifact...'

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --connect-timeout 10 \
    -H "X-Artifact-Key: ${ARTIFACT_KEY}" \
    "$ARTIFACT_URL" \
    -o "$ARCHIVE"

[[ -s "$ARCHIVE" ]] || \
    die 'Artifact download was empty.'

ok 'Panel artifact downloaded.'


# ============================================================
# VALIDATE ARTIFACT
# ============================================================

info 'Validating artifact...'

tar -tzf "$ARCHIVE" >/dev/null || \
    die 'Downloaded artifact is not a valid gzip tar archive.'

rm -rf "$TMP_DIR/panel"

mkdir -p "$TMP_DIR/panel"

tar -xzf "$ARCHIVE" -C "$TMP_DIR/panel"

# Support either a flat archive or a single top-level directory.

SOURCE_DIR="$TMP_DIR/panel"

shopt -s nullglob dotglob

entries=("$SOURCE_DIR"/*)

if [[ ${#entries[@]} -eq 1 && \
      -d "${entries[0]}" && \
      -f "${entries[0]}/package.json" ]]; then

    SOURCE_DIR="${entries[0]}"

fi

[[ -f "$SOURCE_DIR/package.json" ]] || \
    die 'Artifact does not contain package.json.'

[[ -f "$SOURCE_DIR/package-lock.json" ]] || \
    die 'Artifact does not contain package-lock.json.'

[[ -f "$SOURCE_DIR/app.js" ]] || \
    die 'Artifact does not contain app.js.'

shopt -u nullglob dotglob

ok 'Artifact validated.'


# ============================================================
# INSTALL PANEL
# ============================================================

systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

mkdir -p "$INSTALL_DIR"

rsync -a --delete \
    --exclude '.env' \
    --exclude 'data' \
    --exclude 'node_modules' \
    --exclude '.git' \
    "$SOURCE_DIR/" \
    "$INSTALL_DIR/"

mkdir -p "$INSTALL_DIR/data"


# ============================================================
# CREATE ENV
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
PANEL_NAME=GKVM Panel
PANEL_VERSION=V1.0
DEFAULT_LOGO_URL=https://i.imgur.com/4p7wdYK.png
NODE_ENV=production
SESSION_SECRET=${SESSION_SECRET}

LICENSE_SERVER_URL=https://arinjay01.pythonanywhere.com
LICENSE_PRODUCT=GKVM-PANEL
LICENSE_GRACE_PERIOD=86400

DEFAULT_ADMIN_USERNAME=admin@gkvm.gtx
DEFAULT_ADMIN_PASSWORD=${ADMIN_PASSWORD}
EOF_ENV

    printf '%s\n' "$ADMIN_PASSWORD" > \
        "$TMP_DIR/admin-password"

    chmod 600 "$TMP_DIR/admin-password"

    ok 'Created secure .env.'

else

    warn 'Existing .env preserved.'

fi


# ============================================================
# NPM INSTALL
# ============================================================

cd "$INSTALL_DIR"

npm ci \
    --omit=dev \
    --foreground-scripts

ok 'Node dependencies installed.'


# ============================================================
# PERMISSIONS
# ============================================================

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


# ============================================================
# FIREWALL
# ============================================================

if command -v ufw >/dev/null 2>&1; then

    ufw allow \
        "${PANEL_PORT}/tcp" \
        >/dev/null 2>&1 || true

fi

if command -v firewall-cmd >/dev/null 2>&1; then

    firewall-cmd \
        --permanent \
        --add-port="${PANEL_PORT}/tcp" \
        >/dev/null 2>&1 || true

    firewall-cmd \
        --reload \
        >/dev/null 2>&1 || true

fi


# ============================================================
# SYSTEMD SERVICE
# ============================================================

NODE_BIN="$(command -v node)"

cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=GKVM Panel V1.0
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
# START SERVICE
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

    die 'GKVM Panel failed to start.'

fi


# ============================================================
# FINAL OUTPUT
# ============================================================

PUBLIC_IP="$(
    curl -4 -fsS \
        --max-time 8 \
        https://api.ipify.org \
        2>/dev/null ||
    hostname -I 2>/dev/null | awk '{print $1}'
)"

PUBLIC_IP="${PUBLIC_IP:-YOUR_SERVER_IP}"

line

echo -e "${GREEN}GKVM PANEL V1.0 — INSTALLATION COMPLETE${NC}"

echo "Panel:     http://${PUBLIC_IP}:${PANEL_PORT}"
echo "Directory: ${INSTALL_DIR}"
echo "Service:   ${SERVICE_NAME}"
echo "Logs:      journalctl -u ${SERVICE_NAME} -f"

echo

if [[ ! -f "$INSTALL_DIR/.gkvm-admin-password-shown" ]]; then

    if [[ -f "$TMP_DIR/admin-password" ]]; then

        echo "Initial login:"
        echo "  Username: admin@gkvm.gtx"
        echo "  Password: $(cat "$TMP_DIR/admin-password")"

        touch "$INSTALL_DIR/.gkvm-admin-password-shown"

        chown \
            "$SERVICE_USER:$SERVICE_USER" \
            "$INSTALL_DIR/.gkvm-admin-password-shown"

        chmod 600 \
            "$INSTALL_DIR/.gkvm-admin-password-shown"

    fi

fi

line

ok 'Installation finished.'
