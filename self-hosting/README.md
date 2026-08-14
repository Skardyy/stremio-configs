## Usage

Get your SSH key onto the box first - `bootstrap.sh` disables password auth

```bash
ssh-copy-id root@HOST
```

Create your `.env`:

```bash
cp env.sample .env
openssl rand -hex 32     # -> SECRET_KEY
$EDITOR .env
```

Then, from your local machine:

```bash
./deploy.sh
```

It prompts for the host (remembered in `.deploy.conf` for next time), validates
your `.env`, checks key auth, runs `bootstrap.sh` on the server, copies
`compose.yaml` and `.env` to `/opt/stack`, and brings the stack up.

Re-run it any time you change `compose.yaml` or `.env`. Use `--fast` to skip
the remote `apt full-upgrade`:

```bash
./deploy.sh --fast
```
