# rclone-nas-helper

Shell functions for copying media from a remote seedbox to a Synology NAS using rclone. Designed to be BusyBox-compatible (Synology DSM ships with BusyBox ash, not bash).

Features:
- Three transfer modes tuned for TV, movies, and audiobooks
- Background transfers with log files
- Queue system for sequential, no-thrash batching
- Progress monitoring with colour output
- Log management helpers

## Requirements

- [rclone](https://rclone.org/) installed and in `PATH` (`/usr/bin` or `/usr/local/bin`)
- A configured rclone remote pointing at your seedbox (SFTP or similar)
- Synology DSM (BusyBox ash) or any POSIX shell with `awk`, `ls`, `ps`, `find`
- `less` is optional — used by `rcp_progress --follow`; falls back gracefully if absent

## Setup

### 1. Configure rclone

Create a remote named `seedboxSFTP` (or whatever you prefer — update `RCLONE_REMOTE` below):

```sh
rclone config
```

### 2. Source the helpers

Add to your shell profile (e.g. `~/.profile` on Synology):

```sh
. /path/to/rclone-helpers.sh
```

### 3. Set environment variables

Edit the top of `rclone-helpers.sh` (or override in your profile after sourcing):

| Variable | Default | Description |
|---|---|---|
| `SEEDBOX_BASE` | `/path/to/your/seedbox/files` | **Required.** Base path on your seedbox remote. |
| `RCLONE_REMOTE` | `seedboxSFTP` | rclone remote name from `rclone config`. |
| `MEDIA_BASE` | `/volume1/Media` | Local media root on the NAS. |
| `RCLONE_LOGDIR` | `$HOME` | Where log files are written. |
| `RCLONE_QUEUEDIR` | `$HOME/.rclone-queue` | Queue state directory. |

Example override in `~/.profile`:

```sh
export SEEDBOX_BASE="/mnt/yourslot/files"
export RCLONE_REMOTE="mySeedbox"
. /volume1/homes/youruser/rclone-helpers.sh
```

## Deploying to your NAS

`deploy.sh` pushes `rclone-helpers.sh` to the remote host over SSH, creating a timestamped backup of any existing file and keeping only the 10 most recent backups.

```sh
# Default host alias is "synology"
bash deploy.sh

# Or pass a hostname / SSH alias
bash deploy.sh nas.local
```

Then add this line to `~/.profile` on the NAS if it isn't there already:

```sh
. ~/.rclone-helpers
```

**BusyBox note:** If you find sourcing a separate file unreliable at login (a known BusyBox ash quirk), paste the contents of `rclone-helpers.sh` directly into `~/.profile` instead. In that case, update `SRC` and `DEST` at the top of `deploy.sh` to match your local `.profile` and `~/.profile` on the NAS.

## Usage

### Transfer commands

```sh
# Copy a TV season
rcp_tv "Show.S01.1080p.BluRay" "Breaking Bad/Season 01"

# Copy a movie
rcp_movie "Inception.2010.2160p" "Inception (2010)"

# Copy an audiobook
rcp_audiobook "Sanderson.Mistborn" "Brandon Sanderson/Mistborn"
```

Destination layout under `MEDIA_BASE`:

```
/volume1/Media/
  TV/           ← rcp_tv
  Movies/       ← rcp_movie
  Audiobooks/   ← rcp_audiobook
```

### Monitor a transfer

```sh
rcp_progress              # auto-exits at 100%
rcp_progress -f           # stays open (less +F); Ctrl-C then q to exit
rcp_progress Breaking_Bad # filter by name
rcp_jobs                  # list running rclone processes
rcp_done                  # show completion summary of last transfer
```

### Queue multiple transfers

```sh
rcp_queue rcp_tv    "Show.S01.1080p" "Breaking Bad/Season 01"
rcp_queue rcp_movie "Movie.2010.2160p" "Inception (2010)"
rcp_worker          # start background worker; exits when queue is empty
rcp_qstatus         # check queue + worker status
rcp_qclear          # discard all pending items
```

### Verify and manage

```sh
# Size-check remote vs local
rcp_verify "Show.S01.1080p" "TV/Breaking Bad/Season 01"

# Log management
rcp_logs             # list 20 most recent logs
rcp_last             # show newest log path
rcp_cleanlogs        # delete logs older than 14 days
rcp_cleanlogs 30     # delete logs older than 30 days
rcp_flushlogs        # delete all logs except the newest

# Stop a running transfer (get PID from rcp_jobs)
rcp_stop 12345
```

### Full reference

```sh
rcp_help
```

## Transfer mode details

| Mode | Command | Transfers | Streams | Chunk cutoff | Optimised for |
|---|---|---|---|---|---|
| TV | `rcp_tv` | 3 | 4 | 250 MB | Multiple episode files |
| Movie | `rcp_movie` | 1 | 8 | 1 GB | Single large file; skips chunking NFOs/subs |
| Audiobook | `rcp_audiobook` | 4 | 1 | 10 GB (off) | Many small/medium files, low CPU |

All modes use `--buffer-size=8M`, `--retries=5`, `--retries-sleep=60s`.

## License

MIT
