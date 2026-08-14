## Usage

Get your SSH key onto the box first - `bootstrap.sh` disables password auth

```bash
ssh-copy-id root@HOST
```

Create your local config. Holds **no secrets** - hostnames and an email only:

```bash
cp env.sample env.local
$EDITOR env.local
```

Then deploy:

```bash
./deploy.sh
```

It prompts for the host (remembered in `.deploy.conf`), then for the
AIOStreams and AIOMetadata logins. The AIOMetadata password is hashed with
`openssl passwd -apr1` before it leaves your machine. `SECRET_KEY` is
generated on first deploy.

```bash
./deploy.sh --fast      # skip the remote apt full-upgrade
./deploy.sh --rotate    # re-prompt for passwords (otherwise reused)
```
