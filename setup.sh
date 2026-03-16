#!/data/data/com.termux/files/usr/bin/bash
# DroidMC setup / update script for Termux

set -euo pipefail

G='\033[0;32m'
A='\033[1;33m'
R='\033[0;31m'
B='\033[0;34m'
D='\033[2m'
N='\033[0m'

log()  { echo -e "${G}[OK]${N} $1"; }
warn() { echo -e "${A}[!]${N} $1"; }
err()  { echo -e "${R}[X]${N} $1"; exit 1; }
info() { echo -e "${B}[i]${N} $1"; }
step() {
  echo ""
  echo -e "${G}----------------------------------------${N}"
  echo -e "  $1"
  echo -e "${G}----------------------------------------${N}"
}

DROIDMC_VERSION="3.3.2-beta.1"
REPO_RAW="https://raw.githubusercontent.com/wafflebyte8-hue/Droidmc-Beta/main"
UI_DIR="$HOME/DroidMC"
MC_DIR="$HOME/minecraft"
BACKUP_ROOT="$UI_DIR/.backup"
TMP_DIR="$HOME/.droidmc-install.$$"
KEEP_CONFIG=0
KEEP_AUTH=0
CHANGE_AUTH=0

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

stop_running_instances() {
  local stopped=0

  if command -v tmux >/dev/null 2>&1 && tmux has-session -t mc 2>/dev/null; then
    tmux kill-session -t mc || true
    stopped=1
    log "Stopped tmux session 'mc'"
  fi

  if command -v pkill >/dev/null 2>&1; then
    if pkill -f "$UI_DIR/server.js" 2>/dev/null; then
      stopped=1
      log "Stopped running DroidMC panel"
    fi
  fi

  if [ "$stopped" -eq 0 ]; then
    info "No running DroidMC panel detected"
  fi
}

clear
echo ""
echo -e "${G}  DroidMC Setup${N}"
echo -e "${D}  Minecraft server panel for Termux${N}"
echo ""

if [ ! -d "/data/data/com.termux" ]; then
  warn "This does not look like Termux."
  read -r -p "  Continue anyway? [y/N]: " cont
  [[ "$cont" =~ ^[Yy]$ ]] || exit 1
fi

step "Downloading panel files"

mkdir -p "$TMP_DIR" || err "Could not create temp directory"

FILES=(
  "server.js"
  "package.json"
  "package-lock.json"
  "index.html"
  "style.css"
  "app.js"
  "uninstall.sh"
  "checksums.sha256"
)

for file in "${FILES[@]}"; do
  info "Downloading $file..."
  curl -fsSL "$REPO_RAW/$file" -o "$TMP_DIR/$file" || err "Failed to download $file"
done

if command -v sha256sum >/dev/null 2>&1; then
  info "Verifying downloads..."
  if (
    cd "$TMP_DIR"
    sha256sum -c checksums.sha256 >/dev/null
  ); then
    log "Downloads verified"
  else
    warn "Checksum verification failed. Continuing install with unverified files."
  fi
else
  warn "sha256sum not found, skipping checksum verification"
fi


if [ -f "$UI_DIR/.version" ]; then
  INSTALLED_VER="$(cat "$UI_DIR/.version")"
  echo ""
  echo -e "  ${A}DroidMC $INSTALLED_VER is already installed.${N}"
  echo -e "  Existing world data will be preserved."
  echo ""
  read -r -p "  Keep existing panel settings and schedules? [Y/n]: " keep_cfg
  if [[ ! "$keep_cfg" =~ ^[Nn]$ ]]; then
    KEEP_CONFIG=1
  fi
  if [ -f "$UI_DIR/auth.json" ]; then
    read -r -p "  Keep existing web panel username/password? [Y/n]: " keep_auth
    if [[ ! "$keep_auth" =~ ^[Nn]$ ]]; then
      KEEP_AUTH=1
    else
      CHANGE_AUTH=1
    fi
  else
    CHANGE_AUTH=1
  fi

  step "Backing up current panel files"
  TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo backup)"
  PANEL_BACKUP="$BACKUP_ROOT/$TS"
  mkdir -p "$PANEL_BACKUP"
  cp -r "$UI_DIR/server.js" "$UI_DIR/package.json" "$UI_DIR/package-lock.json" "$UI_DIR/public" "$UI_DIR/.version" "$UI_DIR/.checksums" "$PANEL_BACKUP/" 2>/dev/null || true
  log "Panel backup saved to $PANEL_BACKUP"
else
  CHANGE_AUTH=1
fi

step "Installing packages"

pkg update -y 2>/dev/null || warn "pkg update reported warnings"
pkg install -y openjdk-21 nodejs curl openssl-tool || err "Failed to install Java / Node.js / curl / openssl"
log "Java ready: $(java -version 2>&1 | head -1)"
log "Node.js $(node --version) / npm $(npm --version)"
if command -v openssl >/dev/null 2>&1; then
  log "OpenSSL ready: $(openssl version | head -1)"
else
  warn "OpenSSL is not available. HTTPS certificate generation will be skipped."
fi

echo ""
echo -e "  ${A}Android 12+ may kill background processes.${N}"
echo -e "  ${G}termux-wake-lock${N} helps keep Termux alive."
echo ""

if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock || true
  log "Wake lock enabled"
else
  warn "termux-wake-lock not available."
  warn "Install Termux:API from F-Droid, then run: pkg install termux-api"
fi

if ! command -v tmux >/dev/null 2>&1; then
  echo ""
  read -r -p "  Install tmux for background sessions? [Y/n]: " dotmux
  if [[ ! "$dotmux" =~ ^[Nn]$ ]]; then
    pkg install -y tmux >/dev/null || warn "tmux install failed"
    command -v tmux >/dev/null 2>&1 && log "tmux installed"
  fi
fi

if [ "$KEEP_CONFIG" -eq 0 ]; then
  step "Choosing server memory"
  TOTAL_MB="$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print int($2/1024)}')"
  if [ -n "$TOTAL_MB" ] && [ "$TOTAL_MB" -gt 0 ]; then
    SUGGESTED_MB=$((TOTAL_MB / 2))
    SUGGESTED_MB=$(((SUGGESTED_MB / 512) * 512))
    [ "$SUGGESTED_MB" -lt 512 ] && SUGGESTED_MB=512
    SUGGESTED="${SUGGESTED_MB}M"
    info "Detected ${TOTAL_MB}MB total RAM. Suggested allocation: $SUGGESTED"
  else
    SUGGESTED="1G"
    info "Could not detect RAM. Suggested default: $SUGGESTED"
  fi
  echo ""
  read -r -p "  How much RAM for the Minecraft server? [default: $SUGGESTED]: " ram_input
  ram_input="${ram_input:-$SUGGESTED}"
  if [[ "$ram_input" =~ ^[0-9]+[MmGg]$ ]]; then
    MC_RAM="${ram_input^^}"
  else
    warn "Invalid format '$ram_input', falling back to $SUGGESTED"
    MC_RAM="${SUGGESTED^^}"
  fi
  log "Server RAM set to $MC_RAM"
fi

if [ "$CHANGE_AUTH" -eq 1 ]; then
  step "Creating panel login"
  while :; do
    read -r -p "  Web panel username: " ADMIN_USER
    [ -n "$ADMIN_USER" ] && break
    warn "Username cannot be empty"
  done
  while :; do
    read -r -s -p "  Web panel password: " ADMIN_PASS
    echo ""
    read -r -s -p "  Confirm password: " ADMIN_PASS_CONFIRM
    echo ""
    [ -n "$ADMIN_PASS" ] || { warn "Password cannot be empty"; continue; }
    [ "$ADMIN_PASS" = "$ADMIN_PASS_CONFIRM" ] && break
    warn "Passwords did not match"
  done
fi

ENABLE_HTTPS=0
HTTPS_PORT="8443"
HTTPS_CERT_DIR="$UI_DIR/certs"
HTTPS_CERT_PATH="$HTTPS_CERT_DIR/cert.pem"
HTTPS_KEY_PATH="$HTTPS_CERT_DIR/key.pem"

if [ "$KEEP_CONFIG" -eq 0 ]; then
  step "HTTPS certificate"
  read -r -p "  Enable HTTPS for the web panel with a self-signed certificate? [Y/n]: " https_ans
  if [[ ! "$https_ans" =~ ^[Nn]$ ]]; then
    ENABLE_HTTPS=1
    read -r -p "  HTTPS port [default: 8443]: " https_port_input
    HTTPS_PORT="${https_port_input:-8443}"
  fi
else
  ENABLE_HTTPS="$(node -e "try{const fs=require('fs');const j=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.stdout.write(j.httpsEnabled?'1':'0')}catch{process.stdout.write('0')}" "$UI_DIR/config.json")"
  HTTPS_PORT="$(node -e "try{const fs=require('fs');const j=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.stdout.write(String(j.httpsPort||8443))}catch{process.stdout.write('8443')}" "$UI_DIR/config.json")"
  info "Keeping existing HTTPS configuration"
fi

step "Installing files"

stop_running_instances
mkdir -p "$UI_DIR/public" "$MC_DIR" "$UI_DIR/backups" "$BACKUP_ROOT"
cp "$TMP_DIR/server.js" "$UI_DIR/server.js"
cp "$TMP_DIR/package.json" "$UI_DIR/package.json"
cp "$TMP_DIR/package-lock.json" "$UI_DIR/package-lock.json"
cp "$TMP_DIR/index.html" "$UI_DIR/public/index.html"
cp "$TMP_DIR/style.css" "$UI_DIR/public/style.css"
cp "$TMP_DIR/app.js" "$UI_DIR/public/app.js"
cp "$TMP_DIR/checksums.sha256" "$UI_DIR/.checksums"
cp "$TMP_DIR/uninstall.sh" "$HOME/uninstall-mc.sh"
chmod +x "$HOME/uninstall-mc.sh"
log "Panel files copied to $UI_DIR"

if [ "$KEEP_CONFIG" -eq 0 ]; then
  if [ "$ENABLE_HTTPS" -eq 1 ]; then
    if ! command -v openssl >/dev/null 2>&1; then
      warn "OpenSSL is not installed. Continuing with HTTP instead of HTTPS."
      ENABLE_HTTPS=0
    else
      mkdir -p "$HTTPS_CERT_DIR"
      if openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$HTTPS_KEY_PATH" \
        -out "$HTTPS_CERT_PATH" \
        -days 3650 \
        -subj "/CN=DroidMC"; then
        log "Self-signed HTTPS certificate generated"
      else
        warn "Failed to generate HTTPS certificate. Continuing with HTTP instead of HTTPS."
        ENABLE_HTTPS=0
      fi
    fi
  fi
  cat > "$UI_DIR/config.json" <<EOF
{
  "serverJar": "server.jar",
  "serverDir": "$MC_DIR",
  "memory": "$MC_RAM",
  "javaPath": "java",
  "uiPort": 8080,
  "httpsEnabled": $( [ "$ENABLE_HTTPS" -eq 1 ] && echo "true" || echo "false" ),
  "httpsPort": $HTTPS_PORT,
  "httpsCertPath": "$HTTPS_CERT_PATH",
  "httpsKeyPath": "$HTTPS_KEY_PATH",
  "serverType": "",
  "serverVersion": "",
  "preset": "balanced",
  "autoRestart": true,
  "autoRestartDelaySec": 10,
  "backupRetention": 5,
  "scheduleBackupMinutes": 0,
  "scheduleBroadcastMinutes": 0,
  "scheduleBroadcastMessage": "Scheduled notice from DroidMC.",
  "scheduleRestartTime": "",
  "motd": "A DroidMC Minecraft Server",
  "lastDownloadedChecksum": "",
  "lastDownloadedChecksumType": ""
}
EOF
  log "config.json written"
else
  info "Keeping existing config.json"
fi

if [ "$CHANGE_AUTH" -eq 1 ]; then
  ADMIN_USER="$ADMIN_USER" ADMIN_PASS="$ADMIN_PASS" node <<'EOF' > "$UI_DIR/auth.json"
const crypto = require('crypto');
const username = process.env.ADMIN_USER || 'admin';
const password = process.env.ADMIN_PASS || 'changeme';
const salt = crypto.randomBytes(16).toString('hex');
const passwordHash = crypto.scryptSync(password, salt, 64).toString('hex');
process.stdout.write(JSON.stringify({
  authRequired: true,
  username,
  salt,
  passwordHash,
  bootstrap: false,
  updatedAt: new Date().toISOString(),
}, null, 2));
EOF
  log "auth.json written"
else
  info "Keeping existing auth.json"
fi

echo ""
echo -e "  ${A}Minecraft End User License Agreement (EULA)${N}"
echo -e "  ${B}https://aka.ms/MinecraftEULA${N}"
read -r -p "  Do you accept the Minecraft EULA? [Y/n]: " eula_ans
if [[ "$eula_ans" =~ ^[Nn]$ ]]; then
  err "EULA not accepted"
fi
echo "eula=true" > "$MC_DIR/eula.txt"

step "Installing Node.js dependencies"

cd "$UI_DIR"
npm ci --omit=dev >/dev/null || err "npm install failed"
log "Node.js dependencies installed"

echo "$DROIDMC_VERSION" > "$UI_DIR/.version"
log "Version $DROIDMC_VERSION recorded"

step "Creating launch scripts"

cat > "$HOME/start-mc.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
MC_DIR="${MC_DIR:-$HOME/minecraft}"
UI_DIR="${UI_DIR:-$HOME/DroidMC}"
UI_PORT="8080"
MC_VERBOSE="1"
HTTPS_ENABLED="$(node -e "try{const fs=require('fs');const j=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.stdout.write(j.httpsEnabled?'1':'0')}catch{process.stdout.write('0')}" "$UI_DIR/config.json")"
HTTPS_PORT="$(node -e "try{const fs=require('fs');const j=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.stdout.write(String(j.httpsPort||8443))}catch{process.stdout.write('8443')}" "$UI_DIR/config.json")"
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock
LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo ""
echo "  DroidMC starting..."
if [ "$HTTPS_ENABLED" = "1" ]; then
  echo "  Browser (this phone):  https://localhost:$HTTPS_PORT"
  [ -n "$LOCAL_IP" ] && echo "  Browser (same WiFi):   https://$LOCAL_IP:$HTTPS_PORT"
else
  echo "  Browser (this phone):  http://localhost:$UI_PORT"
  [ -n "$LOCAL_IP" ] && echo "  Browser (same WiFi):   http://$LOCAL_IP:$UI_PORT"
fi
echo ""
cd "$UI_DIR"
MC_VERBOSE=1 node server.js
EOF
chmod +x "$HOME/start-mc.sh"
log "Created ~/start-mc.sh"

if command -v tmux >/dev/null 2>&1; then
cat > "$HOME/start-mc-bg.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
UI_DIR="${UI_DIR:-$HOME/DroidMC}"
UI_PORT="8080"
HTTPS_ENABLED="$(node -e "try{const fs=require('fs');const j=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.stdout.write(j.httpsEnabled?'1':'0')}catch{process.stdout.write('0')}" "$UI_DIR/config.json")"
HTTPS_PORT="$(node -e "try{const fs=require('fs');const j=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.stdout.write(String(j.httpsPort||8443))}catch{process.stdout.write('8443')}" "$UI_DIR/config.json")"
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock
if tmux has-session -t mc 2>/dev/null; then
  echo ""
  echo "  DroidMC is already running."
  echo "  Re-attach: tmux attach -t mc"
  echo ""
else
  tmux new-session -d -s mc "cd $UI_DIR && MC_VERBOSE=1 node server.js"
  LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo ""
  echo "  DroidMC started in background (tmux: mc)"
  if [ "$HTTPS_ENABLED" = "1" ]; then
    echo "  Browser (this phone): https://localhost:$HTTPS_PORT"
    [ -n "$LOCAL_IP" ] && echo "  Browser (WiFi):       https://$LOCAL_IP:$HTTPS_PORT"
  else
    echo "  Browser (this phone): http://localhost:$UI_PORT"
    [ -n "$LOCAL_IP" ] && echo "  Browser (WiFi):       http://$LOCAL_IP:$UI_PORT"
  fi
  echo ""
fi
EOF
  chmod +x "$HOME/start-mc-bg.sh"
  log "Created ~/start-mc-bg.sh"
fi

step "Validation summary"

AUTH_USER="$(node -e "try{const fs=require('fs');const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p,'utf8'));process.stdout.write(j.username||'admin')}catch{process.stdout.write('admin')}" "$UI_DIR/auth.json")"
UI_PORT="$(node -e "try{const fs=require('fs');const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p,'utf8'));process.stdout.write(String(j.uiPort||8080))}catch{process.stdout.write('8080')}" "$UI_DIR/config.json")"
HTTPS_ENABLED_ACTUAL="$(node -e "try{const fs=require('fs');const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p,'utf8'));process.stdout.write(j.httpsEnabled?'1':'0')}catch{process.stdout.write('0')}" "$UI_DIR/config.json")"
HTTPS_PORT_ACTUAL="$(node -e "try{const fs=require('fs');const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p,'utf8'));process.stdout.write(String(j.httpsPort||8443))}catch{process.stdout.write('8443')}" "$UI_DIR/config.json")"
echo -e "  ${D}Panel path:${N}      $UI_DIR"
echo -e "  ${D}Server path:${N}     $MC_DIR"
echo -e "  ${D}Panel login:${N}     $AUTH_USER"
echo -e "  ${D}Backup folder:${N}   $UI_DIR/backups"
if [ "$HTTPS_ENABLED_ACTUAL" = "1" ]; then
  echo -e "  ${D}Panel URL:${N}       https://localhost:$HTTPS_PORT_ACTUAL"
else
  echo -e "  ${D}Panel URL:${N}       http://localhost:$UI_PORT"
fi
echo -e "  ${D}Foreground:${N}      ~/start-mc.sh"
command -v tmux >/dev/null 2>&1 && echo -e "  ${D}Background:${N}      ~/start-mc-bg.sh"
echo ""
echo -e "${G}==============================================${N}"
echo -e "${G}  Setup complete${N}"
echo -e "${G}==============================================${N}"
echo ""
