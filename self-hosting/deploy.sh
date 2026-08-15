#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

CONF=.deploy.conf
LOCAL_ENV=env.local
STACK_DIR=/opt/stack
SKIP_UPGRADE=0

for a in "$@"; do
  case $a in
    --fast)   SKIP_UPGRADE=1 ;;
    --rotate) ROTATE=1 ;;
    -h|--help)
      cat <<'EOF'
usage: ./deploy.sh [--fast] [--rotate]
  --fast     skip apt full-upgrade on the remote
  --rotate   force re-prompt for all passwords
EOF
      exit 0 ;;
    *) echo "unknown flag: $a" >&2; exit 1 ;;
  esac
done
ROTATE="${ROTATE:-0}"

c()   { printf '\n\033[1;36m%s\033[0m\n' "$*"; }
ok()  { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
inf() { printf '\033[0;90m  · %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ host
[[ -f $CONF ]] && source "$CONF"

read -rp "Server IP or hostname [${HOST:-}]: " in_host
HOST="${in_host:-${HOST:-}}"
[[ -n $HOST ]] || die "need a host"
read -rp "SSH user [${SSH_USER:-root}]: " in_user
SSH_USER="${in_user:-${SSH_USER:-root}}"
printf 'HOST=%q\nSSH_USER=%q\n' "$HOST" "$SSH_USER" > "$CONF"
TARGET="$SSH_USER@$HOST"

# ------------------------------------------------------------------ checks
c "Preflight"

missing_cmds=()
for cmd in ssh scp openssl grep sed cut dirname; do
  command -v "$cmd" >/dev/null || missing_cmds+=("$cmd")
done
if [[ ${#missing_cmds[@]} -gt 0 ]]; then
  printf '\033[1;31m  ✗ missing commands: %s\033[0m\n' "${missing_cmds[*]}" >&2
  echo >&2
  echo "  On NixOS, drop into a shell that has them:" >&2
  echo "      nix-shell -p openssh openssl coreutils gnused gnugrep \\" >&2
  echo "        --run './deploy.sh${*:+ $*}'" >&2
  echo >&2
  echo "  Or add them to your devShell / systemPackages." >&2
  exit 1
fi
ok "required commands present"

for f in bootstrap.sh compose.yaml "$LOCAL_ENV"; do
  [[ -f $f ]] || die "missing $f  (cp env.sample $LOCAL_ENV and edit it)"
done

for k in ACME_EMAIL AIOSTREAMS_HOST AIOMETADATA_HOST BESZEL_HOST; do
  v=$(grep -E "^${k}=" "$LOCAL_ENV" | cut -d= -f2- || true)
  [[ -n $v && $v != *yourdomain* && $v != *example.com* ]] \
    || die "$LOCAL_ENV: $k not filled in"
done
ok "$LOCAL_ENV looks filled in"

# apr1 is an OpenSSL build option, not universal. Fail here rather than
# halfway through prompting for passwords.
openssl passwd -apr1 -salt test test >/dev/null 2>&1 \
  || die "this openssl build does not support 'passwd -apr1'"
ok "openssl supports apr1 hashing"

ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" true 2>/dev/null \
  || die "key auth to $TARGET failed. Run: ssh-copy-id $TARGET"
ok "key auth works"

# --------------------------------------------------------------- secrets
# Read back whatever already exists on the server so we don't clobber it.
c "Secrets"
remote_env=$(ssh "$TARGET" "cat $STACK_DIR/.env 2>/dev/null" || true)
get_remote() { grep -E "^$1=" <<<"$remote_env" | head -1 | cut -d= -f2- || true; }

SECRET_KEY=$(get_remote SECRET_KEY)
STACK_USER=$(get_remote STACK_USER)
AIOSTREAMS_AUTH=$(get_remote AIOSTREAMS_AUTH)
AIOSTREAMS_BASICAUTH=$(get_remote AIOSTREAMS_BASICAUTH)
AIOMETADATA_AUTH=$(get_remote AIOMETADATA_AUTH)
BESZEL_KEY=$(get_remote BESZEL_KEY)
BESZEL_TOKEN=$(get_remote BESZEL_TOKEN)
CF_DNS_API_TOKEN=$(get_remote CF_DNS_API_TOKEN)

if [[ -z $SECRET_KEY ]]; then
  SECRET_KEY=$(openssl rand -hex 32)
  ok "generated SECRET_KEY"
else
  inf "SECRET_KEY kept (rotating it would orphan every saved config)"
fi

# One login for the whole stack: AIOStreams' operator account and the Traefik
# gates in front of both addons. Asked once, expanded into the plaintext and
# apr1-hashed forms each service needs.
if [[ -n $AIOSTREAMS_AUTH && $ROTATE == 0 ]]; then
  inf "stack login kept (--rotate to change)"
else
  echo
  inf "One login for AIOStreams and AIOMetadata"
  read -rp "  username: " _u
  [[ -n $_u ]] || die "username cannot be empty"
  read -rsp "  password: " _p; echo
  read -rsp "  confirm:  " _p2; echo
  [[ $_p == "$_p2" ]] || die "passwords do not match"
  [[ -n $_p ]] || die "password cannot be empty"

  # apr1 for Traefik basic auth; $ doubled so compose does not eat it.
  _h=$(openssl passwd -apr1 "$_p" | sed 's/\$/\$\$/g')

  STACK_USER="$_u"
  AIOSTREAMS_AUTH="$_u:$_p"        # app-level operator login (plaintext)
  AIOSTREAMS_BASICAUTH="$_u:$_h"   # proxy gate
  AIOMETADATA_AUTH="$_u:$_h"       # proxy gate
  unset _u _p _p2 _h
  ok "stack login set"
fi

# Older deployments stored only the AIOStreams login; backfill the rest.
if [[ -n $AIOSTREAMS_AUTH && -z $AIOMETADATA_AUTH ]]; then
  inf "backfilling proxy gate hashes from the existing login"
  _u=${AIOSTREAMS_AUTH%%:*}
  _p=${AIOSTREAMS_AUTH#*:}
  _h=$(openssl passwd -apr1 "$_p" | sed 's/\$/\$\$/g')
  STACK_USER="$_u"
  AIOSTREAMS_BASICAUTH="$_u:$_h"
  AIOMETADATA_AUTH="$_u:$_h"
  unset _u _p _h
  ok "backfilled"
fi

# Beszel's agent credentials come from the hub's "Add System" dialog, which
# only exists after the hub is running. First deploy leaves these blank; the
# second picks them up. Not secret enough to hide from the terminal.
if [[ -n $BESZEL_KEY && $ROTATE == 0 ]]; then
  inf "Beszel agent already registered"
else
  echo
  inf "Beszel agent (leave blank to skip - the hub must be running first)"
  read -rp "  Beszel public key: " in_bkey
  if [[ -n $in_bkey ]]; then
    read -rp "  Beszel token:      " in_btoken
    [[ -n $in_btoken ]] || die "token cannot be empty when a key is given"
    BESZEL_KEY=$in_bkey
    BESZEL_TOKEN=$in_btoken
    ok "Beszel agent credentials set"
  else
    inf "skipped - re-run deploy after adding the system in Beszel"
  fi
fi

# Cloudflare token for the DNS-01 challenge. Needed because the domain is
# proxied (orange cloud); HTTP-01 cannot reach the origin.
if [[ -n $CF_DNS_API_TOKEN && $ROTATE == 0 ]]; then
  inf "Cloudflare DNS token kept"
else
  echo
  inf "Cloudflare API token (Edit zone DNS, scoped to your zone)"
  read -rsp "  CF_DNS_API_TOKEN: " in_cf; echo
  [[ -n $in_cf ]] || die "token required for the DNS-01 challenge"
  CF_DNS_API_TOKEN=$in_cf
  unset in_cf
  ok "Cloudflare token set"
fi

# ------------------------------------------------------------------ run
c "Bootstrapping host"
ssh "$TARGET" "SKIP_UPGRADE=$SKIP_UPGRADE bash -s" < bootstrap.sh

c "Writing config"
ssh "$TARGET" "mkdir -p $STACK_DIR"
scp -q compose.yaml "$TARGET:$STACK_DIR/compose.yaml"

# Assemble the remote .env: non-secret config + secrets, piped over stdin so
# it is never written to a local file.
{
  grep -vE '^(SECRET_KEY|AIOSTREAMS_AUTH|AIOSTREAMS_BASICAUTH|AIOMETADATA_AUTH|STACK_USER|BESZEL_KEY|BESZEL_TOKEN|CF_DNS_API_TOKEN)=' "$LOCAL_ENV"
  echo
  echo "SECRET_KEY=$SECRET_KEY"
  echo "STACK_USER=$STACK_USER"
  echo "AIOSTREAMS_AUTH=$AIOSTREAMS_AUTH"
  echo "AIOSTREAMS_BASICAUTH=$AIOSTREAMS_BASICAUTH"
  echo "AIOMETADATA_AUTH=$AIOMETADATA_AUTH"
  echo "BESZEL_KEY=$BESZEL_KEY"
  echo "BESZEL_TOKEN=$BESZEL_TOKEN"
  echo "CF_DNS_API_TOKEN=$CF_DNS_API_TOKEN"
} | ssh "$TARGET" "umask 077 && cat > $STACK_DIR/.env"
ok "compose.yaml + .env written (.env is 600, server-only)"

c "Starting containers"
ssh "$TARGET" "cd $STACK_DIR && docker compose pull -q && docker compose up -d"

c "Status"
ssh "$TARGET" "cd $STACK_DIR && docker compose ps"

# ------------------------------------------------------------------ done
source <(grep -E '^(AIOSTREAMS_HOST|AIOMETADATA_HOST|BESZEL_HOST)=' "$LOCAL_ENV")

cat <<EOF

$(c "Done")

  AIOStreams    https://$AIOSTREAMS_HOST/stremio/configure
  AIOMetadata   https://$AIOMETADATA_HOST/configure
  Beszel        https://$BESZEL_HOST

  Both addon configure pages now require the logins you just set.
  Manifest URLs stay open so Nuvio can fetch them.

  Certs take ~30s on first boot. If a host fails:
      ssh $TARGET 'cd $STACK_DIR && docker compose logs -f traefik'

EOF

if [[ -z $BESZEL_KEY ]]; then
  cat <<EOF
  Beszel is not registered yet. Open the URL above, create the admin
  account, click Add System (host: localhost, port: 45876), then re-run
  ./deploy.sh and paste the key and token when prompted.

EOF
fi
