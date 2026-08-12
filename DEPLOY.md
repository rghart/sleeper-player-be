# Deploying

The app runs on a Google Cloud VM (`instance-1`). SSH in with:

```bash
ssh team_assistant
```

Everything below runs as the `rhart` user on that VM.

## The short version

```bash
ssh team_assistant '~/deploy.sh'
```

That does the whole thing: pulls `main` from GitHub, runs the tests, builds a
release, **runs migrations**, boots the new version alongside the old one, flips
traffic to it, and stops the old one. There is no separate migrate command —
migrations are step 6 of the deploy.

## What you need to know before running it

- **It deploys `origin/main`, not your local working copy.** The script does
  `git fetch && git reset --hard origin/main` against the VM's checkout at
  `~/sleeper-player-be`. Push your work to `main` first, and don't leave
  anything uncommitted on the VM — the hard reset discards it.
- **The test suite gates the deploy.** `CI=true mix test` runs before anything
  changes, and the script is `set -e`, so failing tests abort before the release
  is built or migrations run.
- **Migrations run against production with no backup step.** If a migration is
  destructive, snapshot the database yourself first. Check what's pending with
  `mix ecto.migrations` (see below).
- **`config/prod.secret.exs` only exists on the VM** — it's gitignored and holds
  the DB credentials. Don't `git clean` that checkout.
- **Step 2 fetches *all* deps, not just prod.** It was `mix deps.get --only prod`
  until 2026-08-06, which was fine only because the test suite happened to have
  no test-only dependencies. Adding one (`bypass`, for the Sleeper client tests)
  broke every deploy at step 3 with "Unchecked dependencies for environment
  test". Changed to plain `mix deps.get`, since a script that runs the tests has
  to install what the tests need. Previous version backed up on the VM at
  `~/deploy.sh.bak-20260806`.

## How `~/deploy.sh` works

The script lives at `/home/rhart/deploy.sh` on the VM — it is *not* in this
repo. It's a blue/green deploy over two port pairs.

1. `cd ~/sleeper-player-be`, `git fetch`, `git reset --hard origin/main`
2. `mix deps.get`
3. `CI=true mix test`
4. `export MIX_ENV=prod`; build a release into `~/releases/<unix-timestamp>/`
5. Read the running release's `env.sh` and pick the *other* port pair, so the
   new version can boot next to the old one:
   - if currently on HTTP 4000 → new version gets 4000→4001, HTTPS 4040→4041
   - otherwise → new version gets 4001→4000, HTTPS 4041→4040
   The chosen ports are appended to the new release's `env.sh`, along with
   `RELEASE_NAME` (set to the http port, to avoid a node-name clash).
6. Write `RELEASE=<timestamp>` to `~/env_vars` — this is what tells systemd
   which release directory to boot.
7. `mix ecto.migrate` (still `MIX_ENV=prod`, run from the source checkout)
8. `sudo systemctl start sleeper-player-be@<new-http-port>`, then poll
   `localhost:<port>/api/v1/players/3992` until it responds
9. Rewrite the two iptables NAT rules so `:80` → new http port and `:443` →
   new https port
10. `sudo systemctl stop sleeper-player-be@<old-http-port>`, and also stop
    `sleeper-player-be@server_reboot` (the instance systemd starts after a VM
    reboot)

## The systemd unit

`/etc/systemd/system/sleeper-player-be@.service` — a template unit,
instantiated per http port (`sleeper-player-be@4000`, `@4001`, and
`@server_reboot`).

```ini
[Service]
Type=simple
Restart=always
RestartSec=1
User=rhart
EnvironmentFile=/home/rhart/env_vars
ExecStart=/bin/bash -c '/home/rhart/releases/${RELEASE}/bin/sleeper_player_api start'
```

Note that `RELEASE` comes from `~/env_vars`, so every instance boots whichever
release the last deploy wrote there.

## Checking state

```bash
ssh team_assistant 'systemctl list-units "sleeper*" --all --no-pager; cat ~/env_vars'
```

```bash
ssh team_assistant 'sudo iptables -t nat -L PREROUTING --line-numbers -n'
```

Healthy state is one active `sleeper-player-be@<port>.service`, an `env_vars`
`RELEASE` matching a directory in `~/releases/`, and the two PREROUTING rules
pointing at that instance's port pair.

Pending migrations:

```bash
ssh team_assistant 'cd ~/sleeper-player-be && MIX_ENV=prod mix ecto.migrations'
```

## Ports

| Slot | HTTP | HTTPS |
|------|------|-------|
| A    | 4000 | 4040  |
| B    | 4001 | 4041  |

Public `:80` and `:443` are redirected to the active slot by the iptables NAT
rules; the app itself never binds the privileged ports. `config/runtime.exs`
reads `HTTP_PORT` / `HTTPS_PORT` out of the release's `env.sh` to decide what
to listen on.

## Toolchain

Managed by asdf on the VM (`~/.tool-versions`):

```
erlang 25.3
elixir 1.14.3-otp-25
```

## Housekeeping

- `~/releases/` is never pruned — old release directories accumulate, one per
  deploy. Safe to delete any directory that isn't the current `RELEASE`.
- Non-interactive ssh prints `/home/rhart/.asdf/asdf.sh: line 145: .bashrc:
  command not found`. It's a broken line in `~/.bashrc`; harmless, just noisy.
