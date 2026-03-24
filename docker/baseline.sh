#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Docker Setup Script
# - Moves Docker data to a second disk
# - Sets restart policies on existing containers
# - Installs lazydocker, dry, lazyjournal, oxker
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

ADMIN_USER="${SUDO_USER:-ubuntu}"

# ----------------------------
# Configurable variables
# ----------------------------
DOCKER_DISK="${DOCKER_DISK:-/dev/sdb}"
DOCKER_MOUNT="${DOCKER_MOUNT:-/mnt/docker}"
DOCKER_DATA_DIR="${DOCKER_MOUNT}/lib/docker"
DOCKER_COMPOSE_DIR="${DOCKER_MOUNT}/compose"
DOCKER_VOLUMES_DIR="${DOCKER_MOUNT}/volumes"
DOCKER_LOG_MAX_SIZE="${DOCKER_LOG_MAX_SIZE:-10m}"
DOCKER_LOG_MAX_FILE="${DOCKER_LOG_MAX_FILE:-3}"
SETUP_SECOND_DISK="${SETUP_SECOND_DISK:-true}"

# ----------------------------
# Logging
# ----------------------------
log()  { printf "\n[+] %s\n" "$*"; }
warn() { printf "\n[!] %s\n" "$*" >&2; }
ok()   { printf "\n[✓] %s\n" "$*"; }

# ----------------------------
# Prechecks
# ----------------------------
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  warn "User '$ADMIN_USER' not found, falling back to root"
  ADMIN_USER="root"
fi

ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"

run_as_admin() {
  su - "$ADMIN_USER" -c "$1"
}

# ============================================================
# PART 1 — Second disk setup
# ============================================================
if [[ "$SETUP_SECOND_DISK" == "true" ]]; then
  log "Setting up second disk for Docker data"

  # Detect partition
  if lsblk "${DOCKER_DISK}1" >/dev/null 2>&1; then
    PARTITION="${DOCKER_DISK}1"
  else
    PARTITION="$DOCKER_DISK"
  fi

  if ! lsblk "$PARTITION" >/dev/null 2>&1; then
    warn "Disk $PARTITION not found, skipping second disk setup"
  elif ! blkid "$PARTITION" >/dev/null 2>&1; then
    warn "No filesystem on $PARTITION — format it first with: mkfs.ext4 $PARTITION"
  else
    FS_TYPE="$(blkid -o value -s TYPE "$PARTITION")"
    UUID="$(blkid -o value -s UUID "$PARTITION")"

    # Mount
    mkdir -p "$DOCKER_MOUNT"
    if mountpoint -q "$DOCKER_MOUNT"; then
      warn "$DOCKER_MOUNT already mounted, skipping"
    else
      mount "$PARTITION" "$DOCKER_MOUNT"
      ok "Mounted $PARTITION at $DOCKER_MOUNT"
    fi

    # Directory structure
    mkdir -p "$DOCKER_DATA_DIR" "$DOCKER_COMPOSE_DIR" "$DOCKER_VOLUMES_DIR"

    # fstab persistent mount
    FSTAB_ENTRY="UUID=${UUID}  ${DOCKER_MOUNT}  ${FS_TYPE}  defaults,nofail  0  2"
    if grep -q "$UUID" /etc/fstab 2>/dev/null; then
      warn "fstab entry already exists for UUID $UUID, skipping"
    else
      cp /etc/fstab /etc/fstab.bak
      echo "$FSTAB_ENTRY" >> /etc/fstab
      mount -a && ok "fstab updated and verified" || warn "fstab verification failed — check /etc/fstab"
    fi

    # Stop Docker and migrate data
    log "Stopping Docker for data migration"
    systemctl stop docker docker.socket || true

    if [[ -d /var/lib/docker ]] && [[ "$(ls -A /var/lib/docker 2>/dev/null)" ]]; then
      log "Migrating /var/lib/docker to $DOCKER_DATA_DIR"
      rsync -aH --progress /var/lib/docker/ "$DOCKER_DATA_DIR/" \
        || { warn "rsync failed — Docker data NOT moved"; systemctl start docker; exit 1; }
      mv /var/lib/docker /var/lib/docker.bak
      ok "Docker data migrated (backup at /var/lib/docker.bak)"
    else
      warn "/var/lib/docker empty or missing, nothing to migrate"
    fi
  fi
fi

# ============================================================
# PART 2 — Docker daemon best practices
# ============================================================
log "Writing Docker daemon configuration"
mkdir -p /etc/docker

# Use second disk data root if setup, otherwise default
if [[ "$SETUP_SECOND_DISK" == "true" ]] && mountpoint -q "$DOCKER_MOUNT" 2>/dev/null; then
  DATA_ROOT="$DOCKER_DATA_DIR"
else
  DATA_ROOT="/var/lib/docker"
fi

cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "${DATA_ROOT}",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${DOCKER_LOG_MAX_SIZE}",
    "max-file": "${DOCKER_LOG_MAX_FILE}"
  },
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64000,
      "Soft": 64000
    }
  }
}
EOF
ok "daemon.json written"

# Start Docker
log "Starting Docker"
systemctl start docker

# Verify data root
DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo 'unknown')"
if [[ "$DOCKER_ROOT" == "$DATA_ROOT" ]]; then
  ok "Docker is using $DATA_ROOT"
else
  warn "Docker root is $DOCKER_ROOT (expected $DATA_ROOT) — check /etc/docker/daemon.json"
fi

# ============================================================
# PART 3 — Set restart policy on existing containers
# ============================================================
log "Setting restart policy on existing containers"
CONTAINERS="$(docker ps -aq 2>/dev/null || true)"
if [[ -n "$CONTAINERS" ]]; then
  while IFS= read -r container; do
    NAME="$(docker inspect --format '{{.Name}}' "$container" | tr -d '/')"
    POLICY="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$container")"
    if [[ "$POLICY" != "always" && "$POLICY" != "unless-stopped" ]]; then
      docker update --restart unless-stopped "$container"
      ok "Set restart policy on $NAME (was: ${POLICY:-none})"
    else
      warn "$NAME already has restart policy: $POLICY, skipping"
    fi
  done <<< "$CONTAINERS"
else
  warn "No existing containers found"
fi

# ============================================================
# PART 4 — Docker tools
# ============================================================

# --- lazydocker ---
log "Installing lazydocker"
if command -v lazydocker >/dev/null 2>&1; then
  warn "lazydocker already installed, skipping"
else
  curl -sSfL https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | \
    DIR="${ADMIN_HOME}/.local/bin" bash \
    || warn "lazydocker install failed"
  ok "lazydocker installed"
fi

# --- dry ---
log "Installing dry"
if command -v dry >/dev/null 2>&1; then
  warn "dry already installed, skipping"
else
  curl -sSf https://moncho.github.io/dry/dryup.sh | sh \
    || warn "dry install failed"
  chmod 755 /usr/local/bin/dry 2>/dev/null || true
  ok "dry installed"
fi

# --- lazyjournal (via Homebrew) ---
log "Installing lazyjournal via Homebrew"
if run_as_admin 'command -v lazyjournal >/dev/null 2>&1'; then
  warn "lazyjournal already installed, skipping"
else
  run_as_admin '
    if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
      eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    elif [ -x "$HOME/.linuxbrew/bin/brew" ]; then
      eval "$($HOME/.linuxbrew/bin/brew shellenv)"
    else
      echo "[!] Homebrew not found, skipping lazyjournal"
      exit 0
    fi
    brew install lazyjournal || echo "[!] lazyjournal install failed"
  ' || warn "lazyjournal install failed"
  ok "lazyjournal installed"
fi

# --- oxker ---
log "Installing oxker"
if command -v oxker >/dev/null 2>&1 || [[ -f "${ADMIN_HOME}/.local/bin/oxker" ]]; then
  warn "oxker already installed, skipping"
else
  OXKER_TMP="$(mktemp -d)"
  curl -fsSL "https://github.com/mrjackwills/oxker/releases/latest/download/oxker_linux_x86_64.tar.gz" \
    -o "${OXKER_TMP}/oxker.tar.gz" \
    || warn "Failed to download oxker"
  tar xzvf "${OXKER_TMP}/oxker.tar.gz" -C "$OXKER_TMP" oxker
  mkdir -p "${ADMIN_HOME}/.local/bin"
  install -Dm 755 "${OXKER_TMP}/oxker" "${ADMIN_HOME}/.local/bin/oxker"
  chown "$ADMIN_USER":"$ADMIN_USER" "${ADMIN_HOME}/.local/bin/oxker"
  rm -rf "$OXKER_TMP"
  ok "oxker installed"
fi

# ============================================================
# PART 5 — Ensure ~/.local/bin in PATH
# ============================================================
BASHRC="${ADMIN_HOME}/.bashrc"
LOCAL_BIN_LINE='export PATH="$HOME/.local/bin:$PATH"'
if ! grep -Fq "$LOCAL_BIN_LINE" "$BASHRC" 2>/dev/null; then
  echo "$LOCAL_BIN_LINE" >> "$BASHRC"
  log "Added ~/.local/bin to PATH in .bashrc"
fi

# ============================================================
# Done
# ============================================================
ok "Docker setup complete"

cat <<EOF

Disk layout:
  ${DOCKER_DATA_DIR}     ← Docker images, containers, networks
  ${DOCKER_COMPOSE_DIR}  ← Put compose project folders here
  ${DOCKER_VOLUMES_DIR}  ← Named volumes reference

Docker daemon best practices applied:
  - Log rotation (${DOCKER_LOG_MAX_SIZE} / ${DOCKER_LOG_MAX_FILE} files)
  - live-restore   (containers keep running during Docker daemon restarts)
  - no-new-privileges (containers cannot gain new privileges)
  - userland-proxy disabled (better performance)
  - ulimits set (nofile 64000)

Installed tools:
  lazydocker   ~/.local/bin/lazydocker  (run: lazydocker)
  dry          /usr/local/bin/dry       (run: dry)
  lazyjournal  via Homebrew             (run: lazyjournal)
  oxker        ~/.local/bin/oxker       (run: oxker)

Next steps:
  - Run 'source ~/.bashrc' or re-login to apply PATH changes
  - Check containers:  docker ps
  - Remove backup:     sudo rm -rf /var/lib/docker.bak  (once verified)
  - Disk usage:        df -h ${DOCKER_MOUNT}

Examples:
  sudo bash docker-setup.sh
  sudo SETUP_SECOND_DISK=false bash docker-setup.sh
  sudo DOCKER_DISK=/dev/sdc DOCKER_MOUNT=/mnt/docker bash docker-setup.sh
EOF
