#!/usr/bin/env bash
# PirdVM Panel - direct installer with one-time admin credentials
set -Eeuo pipefail
RED='\033[1;31m'; GREEN='\033[1;32m'; CYAN='\033[1;36m'; NC='\033[0m'
INSTALL_DIR=/opt/gkvm
SERVICE_NAME=gkvm
SERVICE_USER=gkvm
PANEL_PORT="${PANEL_PORT:-8080}"
LICENSE_SERVER_URL=https://arinjay01.pythonanywhere.com
PANEL_DOWNLOAD_URL="$LICENSE_SERVER_URL/download/gkvm-panel.tar.gz"
TMP_DIR="$(mktemp -d /tmp/pirdvm.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
info(){ echo -e "${CYAN}[INFO] $*${NC}"; }
ok(){ echo -e "${GREEN}[OK] $*${NC}"; }
die(){ echo -e "${RED}[ERROR] $*${NC}" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run as root.'
command -v apt-get >/dev/null || die 'Ubuntu/Debian required.'
command -v systemctl >/dev/null || die 'systemd required.'
[[ $(uname -m) == x86_64 ]] || die 'x86_64 required.'
cat <<'BANNER'
==================================================
             PIRDVM PANEL V1.0
==================================================
BANNER
export DEBIAN_FRONTEND=noninteractive
info 'Installing system dependencies...'
apt-get update -y
apt-get install -y curl ca-certificates gnupg build-essential python3 sqlite3 libsqlite3-dev qemu-system-x86 qemu-utils cloud-image-utils genisoimage xorriso bridge-utils net-tools unzip rsync lsof procps iproute2 sudo
if ! command -v node >/dev/null 2>&1 || [[ $(node -p 'Number(process.versions.node.split(".")[0])') -lt 22 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x -o "$TMP_DIR/nodesource.sh"
  bash "$TMP_DIR/nodesource.sh"
  apt-get install -y nodejs
fi
info 'Downloading PirdVM panel (no artifact key)...'
curl -fsSL --retry 3 --connect-timeout 20 --max-time 600 "$PANEL_DOWNLOAD_URL" -o "$TMP_DIR/panel.tar.gz" || die 'Panel download failed.'
tar -tzf "$TMP_DIR/panel.tar.gz" >/dev/null || die 'Invalid TAR archive.'
mkdir -p "$TMP_DIR/extracted"
tar -xzf "$TMP_DIR/panel.tar.gz" -C "$TMP_DIR/extracted" --no-same-owner --no-same-permissions
SOURCE_DIR="$TMP_DIR/extracted"
if [[ ! -f "$SOURCE_DIR/package.json" ]]; then
  PACKAGE_FILE="$(find "$SOURCE_DIR" -maxdepth 3 -type f -name package.json -not -path '*/node_modules/*' -print -quit)"
  [[ -n "$PACKAGE_FILE" ]] || die 'package.json missing.'
  SOURCE_DIR="$(dirname "$PACKAGE_FILE")"
fi
[[ -f "$SOURCE_DIR/app.js" ]] || die 'app.js missing.'
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi
if getent group kvm >/dev/null; then usermod -aG kvm "$SERVICE_USER"; fi
# Detect existing installation before changing anything.
EXISTING=0
if [[ -f "$INSTALL_DIR/app.js" || -f "$INSTALL_DIR/.env" ]]; then EXISTING=1; fi
if [[ $EXISTING -eq 1 ]]; then
  BACKUP_DIR="/opt/pirdvm-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  [[ ! -f "$INSTALL_DIR/.env" ]] || cp -a "$INSTALL_DIR/.env" "$BACKUP_DIR/"
  [[ ! -d "$INSTALL_DIR/data" ]] || cp -a "$INSTALL_DIR/data" "$BACKUP_DIR/"
  info "Existing configuration/data backed up: $BACKUP_DIR"
fi
systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
mkdir -p "$INSTALL_DIR/data"
rsync -a --exclude='.env' --exclude='data/' --exclude='node_modules/' --exclude='.git/' "$SOURCE_DIR/" "$INSTALL_DIR/"
ENV_FILE="$INSTALL_DIR/.env"
ADMIN_USERNAME=''
ADMIN_PASSWORD=''
CREATED_CREDENTIALS=0
# app.js uses DEFAULT_ADMIN_USERNAME and DEFAULT_ADMIN_PASSWORD only
# when it creates the first admin user. Never change credentials on reinstall.
if [[ $EXISTING -eq 0 ]]; then
  ADMIN_USERNAME='admin@pirdvm.local'
  ADMIN_PASSWORD="$(node -e "process.stdout.write(require('crypto').randomBytes(18).toString('base64url'))")"
  SESSION_SECRET="$(node -e "process.stdout.write(require('crypto').randomBytes(32).toString('hex'))")"
  cat > "$ENV_FILE" <<CONFIG
PORT=$PANEL_PORT
NODE_ENV=production
PANEL_NAME=PirdVM Panel
PANEL_VERSION=V1.0
VNM_DATA_DIR=$INSTALL_DIR/data
SESSION_SECRET=$SESSION_SECRET
LICENSE_SERVER_URL=$LICENSE_SERVER_URL
LICENSE_PRODUCT=PIRDVM-PANEL
LICENSE_GRACE_PERIOD=86400
DEFAULT_ADMIN_USERNAME=$ADMIN_USERNAME
DEFAULT_ADMIN_PASSWORD=$ADMIN_PASSWORD
CONFIG
  CREATED_CREDENTIALS=1
else
  [[ -f "$ENV_FILE" ]] || die 'Existing panel has no .env; refusing to reset admin credentials automatically.'
  python3 - "$ENV_FILE" "$PANEL_PORT" <<'PYENV'
from pathlib import Path
import sys
p=Path(sys.argv[1]); port=sys.argv[2]
values={'PORT':port,'NODE_ENV':'production','PANEL_NAME':'PirdVM Panel','PANEL_VERSION':'V1.0','LICENSE_SERVER_URL':'https://arinjay01.pythonanywhere.com','LICENSE_PRODUCT':'PIRDVM-PANEL','LICENSE_GRACE_PERIOD':'86400'}
lines=p.read_text().splitlines()
for k,v in values.items():
    lines=[f'{k}={v}' if x.startswith(k+'=') else x for x in lines]
    if not any(x.startswith(k+'=') for x in lines): lines.append(f'{k}={v}')
p.write_text('\n'.join(lines)+'\n')
PYENV
fi
chmod 600 "$ENV_FILE"
info 'Installing npm dependencies...'
cd "$INSTALL_DIR"
if [[ -f package-lock.json ]]; then npm ci --omit=dev; else npm install --omit=dev; fi
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
chmod 600 "$ENV_FILE"
NODE_BIN="$(command -v node)"
cat > "/etc/systemd/system/$SERVICE_NAME.service" <<SERVICE
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
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"
sleep 3
if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true
  die 'Panel service failed to start.'
fi
if command -v ufw >/dev/null 2>&1; then ufw allow "$PANEL_PORT/tcp" >/dev/null 2>&1 || true; fi
PUBLIC_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
PUBLIC_IP="${PUBLIC_IP:-YOUR_SERVER_IP}"
echo
printf '%s\n' '==================================================' '         PIRDVM PANEL INSTALLED' '=================================================='
echo "Panel URL : http://$PUBLIC_IP:$PANEL_PORT"
if [[ $CREATED_CREDENTIALS -eq 1 ]]; then
  echo "Username  : $ADMIN_USERNAME"
  echo "Password  : $ADMIN_PASSWORD"
  echo 'Save these credentials securely; change the password after login.'
else
  echo 'Username  : Existing admin (unchanged)'
  echo 'Password  : Existing password (unchanged; cannot be recovered from its hash)'
fi
printf '%s\n' '=================================================='
