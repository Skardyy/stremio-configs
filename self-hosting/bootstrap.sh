#!/usr/bin/env bash
# bootstrap.sh - prepare a Debian 13 VPS for the addon stack.
#
# Idempotent by design: every step checks current state first, and services
# are only restarted when their config actually changed. A second run should
# print all "unchanged" and touch nothing.
#
# Normally invoked by deploy.sh, but standalone works:
#   ssh root@HOST 'bash -s' < bootstrap.sh
#
# Env:
#   SKIP_UPGRADE=1   skip apt full-upgrade (much faster re-runs)

set -euo pipefail

STACK_DIR=/opt/stack
SWAP_SIZE=1G
TIMEZONE=Asia/Jerusalem
SKIP_UPGRADE="${SKIP_UPGRADE:-0}"

log()   { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()    { printf '\033[0;32m    %s\033[0m\n' "$*"; }
same()  { printf '\033[0;90m    %s\033[0m\n' "$*"; }

# Write $2 to file $1 only if the content differs. Returns 0 if it changed,
# 1 if it was already correct. This is what makes restarts conditional.
write_if_changed() {
  local path=$1 content=$2
  if [[ -f $path ]] && printf '%s' "$content" | cmp -s - "$path"; then
    return 1
  fi
  install -D -m "${3:-644}" /dev/null "$path"
  printf '%s' "$content" > "$path"
  return 0
}

main() {

[[ $EUID -eq 0 ]] || { echo "must run as root"; exit 1; }

# ---------------------------------------------------------------- packages
log "Packages"
export DEBIAN_FRONTEND=noninteractive

PKGS=(ca-certificates curl gnupg git fail2ban unattended-upgrades)
missing=()
for p in "${PKGS[@]}"; do
  dpkg -s "$p" &>/dev/null || missing+=("$p")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  apt-get update -qq
  apt-get install -y -qq "${missing[@]}"
  ok "installed: ${missing[*]}"
else
  same "all packages present"
fi

if [[ $SKIP_UPGRADE == 1 ]]; then
  same "apt upgrade skipped (SKIP_UPGRADE=1)"
else
  apt-get update -qq
  held=$(apt-get -s full-upgrade | grep -c '^Inst ' || true)
  if [[ $held -gt 0 ]]; then
    apt-get full-upgrade -y -qq
    ok "upgraded $held package(s)"
  else
    same "system already up to date"
  fi
fi

# ---------------------------------------------------------------- timezone
log "Timezone"
if [[ $(timedatectl show -p Timezone --value) == "$TIMEZONE" ]]; then
  same "already $TIMEZONE"
else
  timedatectl set-timezone "$TIMEZONE"
  ok "set to $TIMEZONE"
fi

# ---------------------------------------------------------------- swap
log "Swap"
if swapon --show=NAME --noheadings | grep -qx '/swapfile'; then
  same "swapfile active ($(swapon --show=SIZE --noheadings | head -1 | tr -d ' '))"
else
  if [[ ! -f /swapfile ]]; then
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
  ok "swapfile enabled ($SWAP_SIZE)"
fi
grep -qE '^/swapfile\s' /etc/fstab \
  || echo '/swapfile none swap sw 0 0' >> /etc/fstab

if write_if_changed /etc/sysctl.d/99-swappiness.conf 'vm.swappiness=20
'; then
  sysctl -qp /etc/sysctl.d/99-swappiness.conf
  ok "vm.swappiness=20"
else
  same "vm.swappiness already set"
fi

# ---------------------------------------------------------------- ssh
log "SSH"
if [[ ! -s /root/.ssh/authorized_keys ]]; then
  printf '\033[1;33m    !! authorized_keys empty - leaving password auth ON.\033[0m\n'
  printf '\033[1;33m    !! run ssh-copy-id, then re-run this script.\033[0m\n'
else
  if write_if_changed /etc/ssh/sshd_config.d/99-hardening.conf \
'PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
MaxAuthTries 3
'; then
    if sshd -t; then
      systemctl restart ssh
      ok "hardened, sshd restarted (key-only auth)"
    else
      rm -f /etc/ssh/sshd_config.d/99-hardening.conf
      echo "    sshd config test failed, reverted" >&2
      exit 1
    fi
  else
    same "already hardened"
  fi
fi

# ---------------------------------------------------------------- fail2ban
log "fail2ban"
if write_if_changed /etc/fail2ban/jail.d/sshd.local \
'[sshd]
enabled = true
backend = systemd
maxretry = 3
bantime = 1h
'; then
  systemctl enable -q --now fail2ban
  systemctl restart fail2ban
  ok "jail configured"
else
  systemctl is-active -q fail2ban && same "already configured" \
    || { systemctl enable -q --now fail2ban; ok "started"; }
fi

# ------------------------------------------------------------ auto-upgrades
log "Unattended upgrades"
if write_if_changed /etc/apt/apt.conf.d/20auto-upgrades \
'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
'; then
  ok "enabled"
else
  same "already enabled"
fi

# ---------------------------------------------------------------- docker
log "Docker"
if command -v docker &>/dev/null; then
  same "already installed ($(docker --version | awk '{print $3}' | tr -d ,))"
else
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  ok "installed"
fi
systemctl enable -q --now docker

# Cap container logs: json-file is unbounded by default and AIOStreams is
# chatty. Only restart docker if this actually changed, since restarting
# docker bounces every running container.
if write_if_changed /etc/docker/daemon.json \
'{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
'; then
  systemctl restart docker
  ok "log rotation set, docker restarted"
else
  same "log rotation already set"
fi

if write_if_changed /etc/systemd/journald.conf.d/size.conf \
'[Journal]
SystemMaxUse=200M
'; then
  systemctl restart systemd-journald
  ok "journal capped at 200M"
else
  same "journal already capped"
fi

# ---------------------------------------------------------------- stack dir
log "Stack directory"
if [[ -d $STACK_DIR ]]; then
  same "$STACK_DIR exists"
else
  ok "created $STACK_DIR"
fi
mkdir -p "$STACK_DIR"/{data,traefik}
chmod 700 "$STACK_DIR"

log "Host ready"

}

# Called last so a truncated transfer cannot execute a partial setup.
main "$@"
