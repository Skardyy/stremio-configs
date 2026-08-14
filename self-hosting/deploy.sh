#!/usr/bin/env bash
# deploy.sh - run this on YOUR machine, not the server.
# Prompts for the host, runs bootstrap.sh remotely, then ships the stack.
# Idempotent: safe to re-run after editing compose.yaml or .env.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

CONF=.deploy.conf          # gitignored, remembers your answers
STACK_DIR=/opt/stack
SKIP_UPGRADE=0

for a in "$@"; do
  case $a in
    --fast) SKIP_UPGRADE=1 ;;   # skip apt upgrade on the remote
    -h|--help)
      echo "usage: ./deploy.sh [--fast]"
      echo "  --fast   skip apt full-upgrade (quicker re-deploys)"
      exit 0 ;;
    *) echo "unknown flag: $a" >&2; exit 1 ;;
  esac
done

c()    { printf '\033[1;36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ inputs
[[ -f $CONF ]] && source "$CONF"

read -rp "Server IP or hostname [${HOST:-}]: " in_host
HOST="${in_host:-${HOST:-}}"
[[ -n $HOST ]] || die "need a host"

read -rp "SSH user [${USER_:-root}]: " in_user
USER_="${in_user:-${USER_:-root}}"

printf 'HOST=%q\nUSER_=%q\n' "$HOST" "$USER_" > "$CONF"
TARGET="$USER_@$HOST"

# ------------------------------------------------------------------ checks
c "Preflight"

for f in bootstrap.sh compose.yaml; do
  [[ -f $f ]] || die "missing $f"
done

if [[ ! -f .env ]]; then
  echo
  echo "  No .env found. Create one from the sample:"
  echo "      cp env.sample .env && \$EDITOR .env"
  echo "      openssl rand -hex 32   # for SECRET_KEY"
  echo
  die "missing .env"
fi

# Fail early on placeholders rather than after a 5-minute apt upgrade.
missing=()
for k in ACME_EMAIL AIOSTREAMS_HOST AIOMETADATA_HOST BESZEL_HOST SECRET_KEY; do
  v=$(grep -E "^${k}=" .env | cut -d= -f2- || true)
  [[ -n $v && $v != *example.com* && $v != *yourdomain* ]] || missing+=("$k")
done
[[ ${#missing[@]} -eq 0 ]] || die ".env not filled in: ${missing[*]}"
ok ".env looks filled in"

ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" true 2>/dev/null \
  || die "key auth to $TARGET failed. Run: ssh-copy-id $TARGET"
ok "key auth to $TARGET works"

# ------------------------------------------------------------------ run
c "Bootstrapping host"
# --fast skips apt full-upgrade; use when you're only pushing a stack change.
ssh "$TARGET" "SKIP_UPGRADE=${SKIP_UPGRADE:-0} bash -s" < bootstrap.sh

c "Copying stack to $STACK_DIR"
ssh "$TARGET" "mkdir -p $STACK_DIR"
scp -q compose.yaml "$TARGET:$STACK_DIR/compose.yaml"
scp -q .env         "$TARGET:$STACK_DIR/.env"
ssh "$TARGET" "chmod 600 $STACK_DIR/.env"
ok "compose.yaml + .env copied"

c "Starting containers"
ssh "$TARGET" "cd $STACK_DIR && docker compose pull -q && docker compose up -d"

c "Status"
ssh "$TARGET" "cd $STACK_DIR && docker compose ps"

# ------------------------------------------------------------------ done
source <(grep -E '^(AIOSTREAMS_HOST|AIOMETADATA_HOST|BESZEL_HOST)=' .env)

cat <<EOF

$(c "Done")

  AIOStreams    https://$AIOSTREAMS_HOST/stremio/configure
  AIOMetadata   https://$AIOMETADATA_HOST/configure
  Beszel        https://$BESZEL_HOST

  DNS: all three need A records -> $HOST, proxy OFF (grey cloud),
       or Let's Encrypt can't complete the HTTP-01 challenge.

  Certs take ~30s on first boot. If a host 404s, check:
      ssh $TARGET 'cd $STACK_DIR && docker compose logs -f traefik'

  Beszel: create the admin account, Add System, then put the KEY and
  TOKEN into .env and re-run this script.

EOF
