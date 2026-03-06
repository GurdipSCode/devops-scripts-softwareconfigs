
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Ubuntu DevOps Bootstrap v3
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ----------------------------
# Configurable variables
# ----------------------------
SSH_PORT="${SSH_PORT:-22}"
ADMIN_USER="${SUDO_USER:-ubuntu}"
ALLOW_TCP_PORTS="${ALLOW_TCP_PORTS:-$SSH_PORT}"
TIMEZONE="${TIMEZONE:-Etc/UTC}"
LOCALE="${LOCALE:-en_GB.UTF-8}"

INSTALL_HOMEBREW="${INSTALL_HOMEBREW:-true}"
INSTALL_STARSHIP="${INSTALL_STARSHIP:-true}"
ENABLE_CIS_USG="${ENABLE_CIS_USG:-false}"
USG_PROFILE="${USG_PROFILE:-cis_level1_server}"

ACTION1_AGENT_URL="${ACTION1_AGENT_URL:-}"
PDQ_AGENT_URL="${PDQ_AGENT_URL:-}"

TMP_INSTALL_DIR="${TMP_INSTALL_DIR:-/tmp/ubuntu-bootstrap}"
mkdir -p "$TMP_INSTALL_DIR"

# ----------------------------
# Logging
# ----------------------------
log()  { printf "\n[+] %s\n" "$*"; }
warn() { printf "\n[!] %s\n" "$*" >&2; }
ok()   { printf "\n[✓] %s\n" "$*"; }

# ----------------------------
# Helpers
# ----------------------------
backup_file() {
  local file="$1"
  if [[ -f "$file" && ! -f "${file}.bak" ]]; then
    cp -a "$file" "${file}.bak"
  fi
}

append_if_missing() {
  local file="$1"
  local line="$2"
  touch "$file"
  grep -Fqx "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

replace_or_add_sshd() {
  local key="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config"

  if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -ri "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|g" "$file"
  else
    echo "${key} ${value}" >> "$file"
  fi
}

download_file() {
  local url="$1"
  local output="$2"
  curl -fL --retry 3 --connect-timeout 10 "$url" -o "$output"
}

brew_shellenv_line() {
  cat <<'EOF'
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
elif [ -x "$HOME/.linuxbrew/bin/brew" ]; then
  eval "$($HOME/.linuxbrew/bin/brew shellenv)"
fi
EOF
}

run_brew_as_admin() {
  local cmd="$1"
  su - "$ADMIN_USER" -c "
$(brew_shellenv_line)
$cmd
"
}

# ----------------------------
# Prechecks
# ----------------------------
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  warn "Admin user '$ADMIN_USER' not found, falling back to root"
  ADMIN_USER="root"
fi

if [[ "$SSH_PORT" != "22" ]]; then
  case ",$ALLOW_TCP_PORTS," in
    *,"$SSH_PORT",*) ;;
    *)
      warn "SSH_PORT=$SSH_PORT is not in ALLOW_TCP_PORTS. Adding it."
      ALLOW_TCP_PORTS="${ALLOW_TCP_PORTS},${SSH_PORT}"
      ;;
  esac
fi

# ----------------------------
# Base packages
# ----------------------------
log "Updating apt metadata and upgrading packages"
apt-get update -y
apt-get upgrade -y

log "Installing base Ubuntu packages"
apt-get install -y \
  bash-completion \
  ca-certificates \
  curl \
  wget \
  git \
  vim \
  nano \
  tmux \
  jq \
  unzip \
  zip \
  tree \
  ncdu \
  ripgrep \
  fd-find \
  bat \
  fzf \
  zoxide \
  eza \
  rsync \
  socat \
  dnsutils \
  net-tools \
  traceroute \
  tcpdump \
  lsof \
  strace \
  plocate \
  acl \
  attr \
  sudo \
  gnupg \
  software-properties-common \
  build-essential \
  make \
  gcc \
  file \
  procps \
  apt-transport-https \
  ufw \
  fail2ban \
  unattended-upgrades \
  apt-listchanges \
  needrestart \
  auditd \
  audispd-plugins \
  aide \
  apparmor \
  apparmor-utils \
  glances \
  chrony \
  btop \
  htop \
  iftop \
  iotop \
  sysstat \
  mtr-tiny \
  locales

# ----------------------------
# Time and locale
# ----------------------------
log "Configuring timezone and locale"
timedatectl set-timezone "$TIMEZONE" || true
locale-gen "$LOCALE" || true
update-locale LANG="$LOCALE" LC_ALL="$LOCALE" || true

# ----------------------------
# Auto updates
# ----------------------------
log "Enabling unattended upgrades"
dpkg-reconfigure -f noninteractive unattended-upgrades || true
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Verbose "1";
EOF

# ----------------------------
# SSH lockdown
# ----------------------------
log "Applying SSH lockdown"
backup_file /etc/ssh/sshd_config

replace_or_add_sshd "Port" "$SSH_PORT"
replace_or_add_sshd "PermitRootLogin" "no"
replace_or_add_sshd "PasswordAuthentication" "no"
replace_or_add_sshd "KbdInteractiveAuthentication" "no"
replace_or_add_sshd "ChallengeResponseAuthentication" "no"
replace_or_add_sshd "PubkeyAuthentication" "yes"
replace_or_add_sshd "UsePAM" "yes"
replace_or_add_sshd "X11Forwarding" "no"
replace_or_add_sshd "PermitEmptyPasswords" "no"
replace_or_add_sshd "MaxAuthTries" "3"
replace_or_add_sshd "MaxSessions" "4"
replace_or_add_sshd "ClientAliveInterval" "300"
replace_or_add_sshd "ClientAliveCountMax" "2"
replace_or_add_sshd "LoginGraceTime" "30"
replace_or_add_sshd "AllowAgentForwarding" "no"
replace_or_add_sshd "AllowTcpForwarding" "no"
replace_or_add_sshd "TCPKeepAlive" "no"
replace_or_add_sshd "Compression" "no"
replace_or_add_sshd "PermitTunnel" "no"
replace_or_add_sshd "DebianBanner" "no"
replace_or_add_sshd "PrintMotd" "no"
replace_or_add_sshd "LogLevel" "VERBOSE"

sshd -t
systemctl restart ssh || systemctl restart sshd

# ----------------------------
# UFW firewall
# ----------------------------
log "Configuring UFW"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

IFS=',' read -ra PORTS <<< "$ALLOW_TCP_PORTS"
for p in "${PORTS[@]}"; do
  p="$(echo "$p" | xargs)"
  [[ -n "$p" ]] && ufw allow "${p}/tcp"
done

ufw --force enable

# ----------------------------
# Fail2Ban
# ----------------------------
log "Configuring Fail2Ban"
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
banaction = ufw

[sshd]
enabled = true
port = ${SSH_PORT}
logpath = %(sshd_log)s
EOF

systemctl enable --now fail2ban

# ----------------------------
# Kernel / sysctl hardening
# ----------------------------
log "Applying kernel and network hardening"
cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
fs.suid_dumpable = 0
fs.protected_fifos = 2
fs.protected_hardlinks = 1
fs.protected_regular = 2
fs.protected_symlinks = 1

net.ipv4.ip_forward = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

net.core.bpf_jit_harden = 2
EOF

sysctl --system

# ----------------------------
# Cron / at restrictions
# ----------------------------
log "Restricting cron and at"
echo "root" > /etc/cron.allow
chmod 600 /etc/cron.allow
rm -f /etc/cron.deny

echo "root" > /etc/at.allow
chmod 600 /etc/at.allow
rm -f /etc/at.deny

# ----------------------------
# Login defaults
# ----------------------------
log "Setting stronger login defaults"
backup_file /etc/login.defs
sed -ri 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/' /etc/login.defs || true
sed -ri 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/' /etc/login.defs || true
sed -ri 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   14/' /etc/login.defs || true
grep -q '^UMASK' /etc/login.defs \
  && sed -ri 's/^UMASK.*/UMASK           027/' /etc/login.defs \
  || echo 'UMASK           027' >> /etc/login.defs

# ----------------------------
# Services
# ----------------------------
log "Enabling auditing and NTP"
systemctl enable --now auditd
systemctl enable --now chrony

# ----------------------------
# AIDE
# ----------------------------
log "Initializing AIDE database if needed"
if [[ ! -f /var/lib/aide/aide.db.gz && ! -f /var/lib/aide/aide.db.new.gz ]]; then
  aideinit || true
  [[ -f /var/lib/aide/aide.db.new.gz ]] && cp /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
fi

# ----------------------------
# Homebrew
# ----------------------------
if [[ "$INSTALL_HOMEBREW" == "true" ]] && ! command -v brew >/dev/null 2>&1; then
  log "Installing Homebrew"
  NONINTERACTIVE=1 su - "$ADMIN_USER" -c 'bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' \
    || warn "Homebrew install failed"
fi

# ----------------------------
# Starship
# ----------------------------
if [[ "$INSTALL_STARSHIP" == "true" ]] && ! command -v starship >/dev/null 2>&1; then
  log "Installing Starship"
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y || warn "Starship install failed"
fi

# ----------------------------
# Brew tools
# ----------------------------
if [[ "$INSTALL_HOMEBREW" == "true" ]]; then
  log "Installing extra CLI tools with Homebrew"
  run_brew_as_admin '
brew install \
  lla \
  dust \
  duf \
  doggo \
  bottom \
  lazygit \
  yq \
  fx \
  procs \
  hyperfine \
  gping \
  xh \
  chezmoi \
  tealdeer \
  cnquery \
  cnspec || true

tldr -u || true
'
fi

# ----------------------------
# Shell config
# ----------------------------
configure_shell_for_user() {
  local user_name="$1"
  local home_dir
  home_dir="$(getent passwd "$user_name" | cut -d: -f6 || true)"
  [[ -n "$home_dir" && -d "$home_dir" ]] || return 0

  local bashrc="${home_dir}/.bashrc"
  touch "$bashrc"
  chown "$user_name":"$user_name" "$bashrc"

  append_if_missing "$bashrc" ""
  append_if_missing "$bashrc" "# --- Ubuntu DevOps Bootstrap ---"
  append_if_missing "$bashrc" "export EDITOR=vim"
  append_if_missing "$bashrc" "export VISUAL=vim"
  append_if_missing "$bashrc" "export PAGER=less"
  append_if_missing "$bashrc" "export LESS='-R'"
  append_if_missing "$bashrc" "export CLICOLOR=1"
  append_if_missing "$bashrc" "alias grep='grep --color=auto'"
  append_if_missing "$bashrc" "alias diff='diff --color=auto'"

  append_if_missing "$bashrc" "[ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && source /usr/share/doc/fzf/examples/key-bindings.bash"
  append_if_missing "$bashrc" "[ -f /usr/share/doc/fzf/examples/completion.bash ] && source /usr/share/doc/fzf/examples/completion.bash"
  append_if_missing "$bashrc" 'command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init bash)"'
  append_if_missing "$bashrc" 'alias cat="batcat --paging=never 2>/dev/null || cat"'
  append_if_missing "$bashrc" 'if command -v lla >/dev/null 2>&1; then alias ls="lla"; alias ll="lla -l"; alias la="lla -a"; alias l="lla"; fi'
  append_if_missing "$bashrc" 'if command -v eza >/dev/null 2>&1; then alias lt="eza -lah --tree --level=2"; fi'
  append_if_missing "$bashrc" 'alias helpme="tldr"'

  while IFS= read -r line; do
    append_if_missing "$bashrc" "$line"
  done < <(brew_shellenv_line)

  if [[ "$INSTALL_STARSHIP" == "true" ]]; then
    append_if_missing "$bashrc" 'command -v starship >/dev/null 2>&1 && eval "$(starship init bash)"'
  fi

  mkdir -p "${home_dir}/.config"
  if [[ ! -f "${home_dir}/.config/starship.toml" ]]; then
    cat > "${home_dir}/.config/starship.toml" <<'EOF'
add_newline = false

[character]
success_symbol = "[➜](green)"
error_symbol = "[➜](red)"

[hostname]
ssh_only = true
format = "[$hostname](bold yellow) "

[username]
show_always = true
format = "[$user](bold blue)@"

[directory]
truncation_length = 3
truncate_to_repo = true

[git_branch]
symbol = " "

[cmd_duration]
min_time = 500
format = "took [$duration](bold yellow) "
EOF
    chown -R "$user_name":"$user_name" "${home_dir}/.config"
  fi
}

log "Configuring shell for users"
configure_shell_for_user "$ADMIN_USER"
[[ "$ADMIN_USER" != "root" ]] && configure_shell_for_user "root"

# ----------------------------
# Optional CIS / USG
# ----------------------------
if [[ "$ENABLE_CIS_USG" == "true" ]]; then
  log "Attempting CIS hardening via Ubuntu Security Guide"
  if command -v pro >/dev/null 2>&1; then
    pro enable usg || true
    apt-get install -y usg || true

    if command -v usg >/dev/null 2>&1; then
      usg audit "$USG_PROFILE" || true
      usg fix "$USG_PROFILE" || true
    else
      warn "USG install failed, skipping CIS"
    fi
  else
    warn "'pro' command not available, skipping CIS"
  fi
fi

# ----------------------------
# Optional external agents
# ----------------------------
install_action1() {
  if [[ -z "$ACTION1_AGENT_URL" ]]; then
    log "Skipping Action1 agent (URL not provided)"
    return
  fi

  log "Installing Action1 agent"
  local installer="${TMP_INSTALL_DIR}/action1-agent-installer"
  download_file "$ACTION1_AGENT_URL" "$installer"
  chmod +x "$installer"
  bash "$installer" || warn "Action1 agent install failed"
}

install_pdq() {
  if [[ -z "$PDQ_AGENT_URL" ]]; then
    log "Skipping PDQ Deploy agent (URL not provided)"
    return
  fi

  log "Installing PDQ Deploy agent"
  local installer="${TMP_INSTALL_DIR}/pdq-agent-installer"
  download_file "$PDQ_AGENT_URL" "$installer"
  chmod +x "$installer"
  bash "$installer" || warn "PDQ agent install failed"
}

install_action1
install_pdq

# ----------------------------
# Cleanup
# ----------------------------
log "Cleaning up"
apt-get autoremove -y
apt-get autoclean -y
updatedb || true

ok "Bootstrap complete"

cat <<EOF

Examples:
  sudo bash ubuntu-bootstrap.sh

  sudo SSH_PORT=2222 ALLOW_TCP_PORTS=2222,443 bash ubuntu-bootstrap.sh

  sudo ENABLE_CIS_USG=true USG_PROFILE=cis_level1_server bash ubuntu-bootstrap.sh

  sudo ACTION1_AGENT_URL="https://example/action1.sh" \
       PDQ_AGENT_URL="https://example/pdq.sh" \
       bash ubuntu-bootstrap.sh

Installed shell UX:
  - starship
  - zoxide
  - fzf
  - lla
  - bat
  - tldr

Installed admin tools:
  - glances
  - btop
  - dust
  - duf
  - doggo
  - lazygit
  - cnquery
  - cnspec

Important:
  - Make sure your SSH public key is installed before running this remotely.
  - CIS/USG needs Ubuntu Pro support on the target host.
EOF
