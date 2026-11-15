# Restico

CLI wrapper around [restic](https://restic.net/) with logging, ntfy notifications, and
automation support (cron / systemd).

## Prerequisites

- [restic](https://restic.net/)
- [curl](https://curl.se/) – only needed for ntfy notifications
- [jq](https://jqlang.github.io/jq/) – only needed for ntfy stats
- cron or systemd – for automated backups

## Quick Start

```bash
# Clone the repo
git clone git@github.com:dottmp/restico.git
cd restico

# Install the restico command
make install-cli

# Create your config directory and .env file
mkdir ~/.config/restico
cp .env.example ~/.config/restico/.env && cp restic-password.template ~/.config/restico/restic-password
# Tighten security of your .env and restic password file
chown youruser:yourrole .env && chmod 700 .env && chown youruser:yourrole restic-password && chmod 700 restic-password
# Add excludes
cp excludes.txt.template ~/.config/restico/excludes.txt
# Edit ~/.config/restico/.env with your settings

# Initialize the repository
restico init

# Run your first backup
restico backup
```

## Environment Variables

### Required

| Variable               | Description                                                                       |
| ---------------------- | --------------------------------------------------------------------------------- |
| `RESTICO_REPOSITORY`   | Restic repository URL                                                             |
| `RESTICO_PASSWORD`     | Repository password (or use `RESTICO_PASSWORD_FILE` / `RESTICO_PASSWORD_COMMAND`) |
| `RESTICO_HOSTNAME`     | Hostname used for backup tags                                                     |
| `RESTICO_BACKUP_PATHS` | Path(s) to back up                                                                |

### Optional

| Variable               | Default                        | Description                                    |
| ---------------------- | ------------------------------ | ---------------------------------------------- |
| `RESTICO_EXCLUDE_FILE` | –                              | Path to exclude patterns file                  |
| `RESTICO_NTFY_URL`     | –                              | ntfy topic URL (set with `RESTICO_NTFY_TOKEN`) |
| `RESTICO_NTFY_TOKEN`   | –                              | ntfy auth token (set with `RESTICO_NTFY_URL`)  |
| `RESTICO_LOG_FILE`     | `~/.cache/restico/restico.log` | Log file path                                  |
| `RESTICO_CONFIG_DIR`   | `~/.config/restico`            | Config directory                               |
| `RESTICO_CACHE_DIR`    | `~/.cache/restico`             | Cache / log directory                          |

## Commands

```bash
restico backup               Run backup
restico backup --prune       Run backup, then apply retention policy
restico forget               Apply retention policy and prune
restico init                 Initialize repository
restico check                Validate environment and repository
restico verify               Check repository integrity
restico snapshots            List snapshots
restico restore              Restore files
restico logs                 View backup logs
restico exec <restic-cmd>    Run any restic command
restico help                 Show usage
```

Extra flags are passed through to restic:

```bash
restico backup --dry-run
restico backup --prune --dry-run
restico forget --dry-run
restico snapshots --latest 3
restico restore latest --target /tmp/restore
restico exec unlock
restico exec check --with-cache
```

## Automation

### Cron

```
crontab -e
```

Add:

```crontab
0 4 * * * /home/USER/.local/bin/restico backup --tag scheduled --prune
```

### Systemd

```bash
make systemd-install      # Copy service files and enable timers
make systemd-status       # Verify timers are active
make systemd-force        # Trigger backup immediately
```

This installs three timers (staggered so they never hit the repo at the same time):

- `restico-backup.timer` – runs `restico backup` daily at 03:30
- `restico-prune.timer` – runs `restico forget` on the 1st of the month at 04:30
- `restico-verify.timer` – runs `restico verify` on Sunday at 05:30

## Restoring Files

```bash
# List snapshots
restico snapshots

# Restore latest snapshot
restico restore latest --target /tmp/restore

# Restore a specific snapshot
restico restore <snapshot-id> --target /tmp/restore
```
