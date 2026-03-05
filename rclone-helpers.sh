# --- BEGIN RCLONE HELPERS ---
# Ensure rclone is in PATH even in non-login shells
export PATH="/usr/bin:/usr/local/bin:$PATH"

# Where to drop logs
export RCLONE_LOGDIR="$HOME"

# Where to store queue state
export RCLONE_QUEUEDIR="$HOME/.rclone-queue"

# Queue lock helpers (BusyBox-safe)
_queue_lock() {
  # Acquire exclusive lock on queue file using mkdir (atomic on most filesystems)
  local lockdir="$RCLONE_QUEUEDIR/.lock"
  local waited=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    if [ $waited -ge 100 ]; then
      echo "Warning: Queue lock timeout after 10s" >&2
      return 1
    fi
  done
  return 0
}

_queue_unlock() {
  # Release queue lock
  rmdir "$RCLONE_QUEUEDIR/.lock" 2>/dev/null || true
}

rcp_help() {
  # Display help and usage examples for all rcp_* commands
  cat << EOF
╭─────────────────────────────────────────────────────────────────────╮
│                    RCLONE HELPERS - QUICK REFERENCE                 │
╰─────────────────────────────────────────────────────────────────────╯

MAIN COMMANDS:
  rcp_tv <seedbox_subpath> "<Show/Season XX>"
    Copy TV show from seedbox to /volume1/Media/TV
    Optimized for multiple files: 3 parallel transfers, 4 streams each
    Performance: ~75-90MB/s sustained
    Example: rcp_tv "Show.S01.1080p" "Breaking Bad/Season 01"

  rcp_movie <seedbox_subpath> "<Title (Year)>"
    Copy movie from seedbox to /volume1/Media/Movies
    Optimized for single large files: 1 transfer, 8 streams, only chunks >1GB
    Performance: ~90MB/s+ for large movies, skips NFO/subtitle chunking
    Example: rcp_movie "Movie.2024.1080p" "Inception (2010)"

  rcp_audiobook <seedbox_subpath> "<Author/Title>"
    Copy audiobook from seedbox to /volume1/Media/Audiobooks
    Optimized for small/medium files: 4 parallel transfers, no chunking
    Performance: ~80-120MB/s with minimal CPU overhead
    Example: rcp_audiobook "Sanderson.Brandon" "Brandon Sanderson/Mistborn"

  rcp_verify <seedbox_subpath> "<local_path>"
    Verify copied files match remote (size comparison)
    Local path can be relative to MEDIA_BASE or absolute
    Example: rcp_verify "Show.S01.1080p" "TV/Breaking Bad/Season 01"
    Example: rcp_verify "Movie.2024.1080p" "/volume1/Media/Movies/Inception (2010)"

MONITORING:
  rcp_progress [--follow|-f] [needle|path]
    Monitor transfer progress with colored output
    Default: auto-exits at 100% completion
    --follow/-f: stays open in less (Ctrl-C then q to exit)
    Example: rcp_progress
    Example: rcp_progress Breaking_Bad
    Example: rcp_progress -f

  rcp_jobs
    List all currently running rclone processes
    Example: rcp_jobs

  rcp_done [needle]
    Show completion summary of most recent transfer
    Example: rcp_done
    Example: rcp_done Breaking_Bad

MANAGEMENT:
  rcp_stop <PID>
    Stop a running rclone process by PID (use rcp_jobs to find PID)
    Example: rcp_stop 12345

  rcp_logs
    List 20 most recent rclone log files
    Example: rcp_logs

  rcp_last [needle]
    Find and show info about the most recent log file
    Example: rcp_last
    Example: rcp_last Breaking_Bad

  rcp_cleanlogs [days]
    Delete log files older than N days (default: 14)
    Example: rcp_cleanlogs
    Example: rcp_cleanlogs 30

  rcp_flushlogs
    Delete ALL logs except the most recent one (aggressive cleanup)
    Safe to run anytime - preserves the newest log
    Example: rcp_flushlogs

QUEUE SYSTEM:
  rcp_queue <rcp_tv|rcp_movie|rcp_audiobook|rcp_verify> <args...>
    Add a transfer to the queue (run sequentially)
    Example: rcp_queue rcp_tv "Show.S01.1080p" "Breaking Bad/Season 01"
    Example: rcp_queue rcp_movie "Movie.2024.1080p" "Inception (2010)"
    Example: rcp_queue rcp_audiobook "Author.Book" "Author Name/Book Title"

  rcp_worker
    Start background worker to process queue one at a time
    Worker exits automatically when queue is empty
    Example: rcp_worker

  rcp_qstatus
    Show queue contents and worker status
    Example: rcp_qstatus

  rcp_qclear
    Clear all pending items from queue
    Example: rcp_qclear

  WORKFLOW:
    1. Queue up multiple transfers: rcp_queue rcp_tv "..." "..."
    2. Start worker: rcp_worker
    3. Monitor: rcp_qstatus, rcp_progress
    4. Worker auto-exits when queue is empty

ENVIRONMENT:
  SEEDBOX_BASE="$SEEDBOX_BASE"
  RCLONE_REMOTE="$RCLONE_REMOTE"
  MEDIA_BASE="$MEDIA_BASE"
  RCLONE_LOGDIR="$RCLONE_LOGDIR"
  RCLONE_QUEUEDIR="$RCLONE_QUEUEDIR"

TIPS:
  • Use 'cdm' alias to jump to $MEDIA_BASE
  • Relative paths in rcp_verify are relative to MEDIA_BASE
  • Log files are named: rclone_<tag>_<timestamp>.log
  • Use rcp_progress without args to monitor the newest transfer
  • Queue allows you to batch transfers without CPU thrashing
  • Transfer modes: TV (3×4), Movie (1×8 for >1GB), Audiobook (4×1, no chunking)
  • Movie mode won't chunk small files (<1GB) like NFOs, subtitles, or samples
  • Audiobook mode never chunks (files 15-500MB don't benefit, saves CPU)
  • All transfers use 8MB buffers and retry up to 5 times with 60s delay

TRANSFER SETTINGS:
  TV Mode (rcp_tv):
    • --transfers=3 --checkers=3 (3 files in parallel)
    • --multi-thread-streams=4 --multi-thread-cutoff=250M
    • Optimized for multiple episodes/files
  
  Movie Mode (rcp_movie):
    • --transfers=1 --checkers=1 (single file focus)
    • --multi-thread-streams=8 --multi-thread-cutoff=1G
    • Optimized for single large files, skips chunking small files
  
  Audiobook Mode (rcp_audiobook):
    • --transfers=4 --checkers=4 (4 files in parallel)
    • --multi-thread-streams=1 --multi-thread-cutoff=10G
    • No chunking (15-500MB files too small to benefit), minimal CPU usage

For detailed help on a specific command, check the comments in rclone-helpers.sh
EOF
}

_sanitize() {
  # Make a safe tag from a dest subpath (for filenames)
  # - replace / and space with double-underscore
  # - drop everything not alnum / underscore / dash / dot
  printf '%s' "$1" \
    | tr '/ ' '__' \
    | tr -cd 'A-Za-z0-9_.-'
}

_rcp_copy() {
  # Internal helper: start an rclone copy in the background
  # Usage: _rcp_copy <seedbox_path> <dest_root> "<dest_rel>" [mode]
  # mode: "movie" for single-file movie optimization, "audiobook" for no-chunk multi-transfer, otherwise TV/multi-file mode
  # Can be called with RCLONE_PIDFILE env var to track PID
  local src="$1" dest_root="$2" dest_rel="$3" mode="${4:-tv}"
  if [ -z "$src" ] || [ -z "$dest_root" ] || [ -z "$dest_rel" ]; then
    echo "Usage: _rcp_copy <seedbox_path> <dest_root> \"<dest_rel>\" [mode]" >&2
    return 1
  fi

  local dest="${dest_root%/}/$dest_rel/"
  mkdir -p "$dest" || return 1

  local stamp tag log nhout
  stamp="$(date +%Y%m%d-%H%M%S)"
  tag="$(_sanitize "$dest_rel")"
  log="$RCLONE_LOGDIR/rclone_${tag}_${stamp}.log"
  nhout="$RCLONE_LOGDIR/rclone_${tag}_${stamp}.nohup.out"

  echo "→ Starting rclone:"
  echo "   src : $RCLONE_REMOTE:$src"
  echo "   dest: $dest"
  echo "   log : $log"

  # Fire-and-forget (background) or blocking (foreground for worker)
  # Foreground if RCP_FOREGROUND=1 (for the worker), else background (CLI)
  # NOTE:
  #  - --stats-log-level writes stats lines into the log file
  #  - Mode-specific optimizations:
  #    * TV/multi-file mode:
  #      - transfers=3: 3 files in parallel (reduced to prevent buffer bloat)
  #      - checkers=3: Moderate checking overhead
  #      - multi-thread-streams=4: 4 chunks per large file
  #      - multi-thread-cutoff=250M: Only chunk very large files (4K episodes)
  #      - Gives ~3 files × 25-30MB/s = 75-90MB/s sustained
  #    * Movie mode (single large file):
  #      - transfers=1: Only 1 file at a time (movies are usually single files)
  #      - checkers=1: Minimal overhead for single file
  #      - multi-thread-streams=8: More aggressive chunking for large file
  #      - multi-thread-cutoff=1G: Only chunk files over 1GB (skip NFOs/subs/samples)
  #      - Gives 1 file × 8 streams = ~90MB/s+ for large movies
  #    * Audiobook mode (mixed small/medium files):
  #      - transfers=4: 4 files in parallel (good for multiple small files)
  #      - checkers=4: Match transfer count
  #      - multi-thread-streams=1: No chunking (files too small to benefit)
  #      - multi-thread-cutoff=10G: Effectively disables chunking (files never this large)
  #      - Gives 4 files × ~20-30MB/s = 80-120MB/s with no CPU overhead
  #  - buffer-size=8M: Smaller buffer to match disk write speed better
  #  - NO use-mmap: Removed to prevent excessive RAM buffering
  
  local transfers checkers streams cutoff
  if [ "$mode" = "movie" ]; then
    transfers=1
    checkers=1
    streams=8
    cutoff="1G"
  elif [ "$mode" = "audiobook" ]; then
    transfers=4
    checkers=4
    streams=1
    cutoff="10G"
  else
    transfers=3
    checkers=3
    streams=4
    cutoff="250M"
  fi
  
  if [ "${RCP_FOREGROUND:-0}" = "1" ]; then
    # Foreground mode (for queue worker) - blocks until complete
    rclone copy \
      "$RCLONE_REMOTE:$src" \
      "$dest" \
      --stats 10s \
      --stats-log-level NOTICE \
      --transfers="$transfers" --checkers="$checkers" \
      --multi-thread-streams="$streams" --multi-thread-cutoff="$cutoff" \
      --buffer-size=8M \
      --retries=5 --retries-sleep=60s \
      --log-file "$log" --log-level NOTICE
  else
    # Background mode (for CLI usage) - fire and forget
    nohup rclone copy \
      "$RCLONE_REMOTE:$src" \
      "$dest" \
      --stats 10s \
      --stats-log-level NOTICE \
      --transfers="$transfers" --checkers="$checkers" \
      --multi-thread-streams="$streams" --multi-thread-cutoff="$cutoff" \
      --buffer-size=8M \
      --retries=5 --retries-sleep=60s \
      --log-file "$log" --log-level NOTICE \
      > "$nhout" 2>&1 & disown

    echo
    echo "Tip 1: rcp_progress $tag"
    echo "Tip 2: tail -f \"$nhout\"   # raw stream if you prefer"
  fi
}

# Seedbox base path — update this to match your seedbox mount/path
export SEEDBOX_BASE="/path/to/your/seedbox/files"

# Rclone remote name
export RCLONE_REMOTE="seedboxSFTP"

# Local media base path on NAS
export MEDIA_BASE="/volume1/Media"

# Convenience alias to jump to media directory
alias cdm='cd "$MEDIA_BASE"'

# Public commands

rcp_tv() {
  # Copy TV show from seedbox to local NAS
  # Usage: rcp_tv <seedbox_subpath> "<Show Name/Season 0X>"
  local subpath="$1" dest_rel="$2"
  if [ -z "$subpath" ] || [ -z "$dest_rel" ]; then
    echo 'Usage: rcp_tv <seedbox_subpath> "<Show Name/Season 0X">' >&2
    return 1
  fi
  local full_src="${SEEDBOX_BASE%/}/${subpath#/}"
  _rcp_copy "$full_src" "$MEDIA_BASE/TV" "$dest_rel"
}

rcp_movie() {
  # Copy movie from seedbox to local NAS
  # Usage: rcp_movie <seedbox_subpath> "<Title (Year)>"
  # Optimized for single large files: 1 transfer with 8 streams, only chunks files >1GB
  local subpath="$1" dest_rel="$2"
  if [ -z "$subpath" ] || [ -z "$dest_rel" ]; then
    echo 'Usage: rcp_movie <seedbox_subpath> "<Title (Year)>"' >&2
    return 1
  fi
  local full_src="${SEEDBOX_BASE%/}/${subpath#/}"
  _rcp_copy "$full_src" "$MEDIA_BASE/Movies" "$dest_rel" "movie"
}

rcp_audiobook() {
  # Copy audiobook from seedbox to local NAS
  # Usage: rcp_audiobook <seedbox_subpath> "<Author/Title>"
  # Optimized for small-to-medium files: 4 parallel transfers, no chunking (files too small)
  local subpath="$1" dest_rel="$2"
  if [ -z "$subpath" ] || [ -z "$dest_rel" ]; then
    echo 'Usage: rcp_audiobook <seedbox_subpath> "<Author/Title>"' >&2
    return 1
  fi
  local full_src="${SEEDBOX_BASE%/}/${subpath#/}"
  _rcp_copy "$full_src" "$MEDIA_BASE/Audiobooks" "$dest_rel" "audiobook"
}

rcp_verify() {
  # Verify copied files match remote by comparing sizes
  # Usage: rcp_verify <seedbox_subpath> "<local_path>"
  # Local path can be relative to MEDIA_BASE or absolute
  # Examples:
  #   rcp_verify "Show.S01.1080p" "TV/Show Name/Season 01"
  #   rcp_verify "Movie.2024.1080p" "Movies/Movie Title (2024)"
  #   rcp_verify "Show.S01.1080p" "/volume1/Media/TV/Show Name/Season 01"  (absolute still works)
  local subpath="$1" local_path="$2"
  if [ -z "$subpath" ] || [ -z "$local_path" ]; then
    echo 'Usage: rcp_verify <seedbox_subpath> "<local_path>"' >&2
    echo '  Local path can be relative to MEDIA_BASE or absolute.' >&2
    return 1
  fi
  
  local full_src="${SEEDBOX_BASE%/}/${subpath#/}"
  
  # If local_path doesn't start with /, prepend MEDIA_BASE
  case "$local_path" in
    /*) local full_local="$local_path" ;;
    *)  local full_local="${MEDIA_BASE%/}/$local_path" ;;
  esac
  
  echo "→ Checking sizes between:"
  echo "   Remote: $RCLONE_REMOTE:$full_src"
  echo "   Local : $full_local"
  rclone check "$RCLONE_REMOTE:$full_src" "$full_local" --one-way --size-only
}

rcp_done() {
  # Show completion summary of most recent transfer
  # Usage: rcp_done [needle]
  local f
  f="$(rcp_last "${1:-}" | head -n1)" || return 1
  [ "${f##*.}" = "log" ] || { echo "Newest is nohup; pick a .log"; return 1; }
  echo "→ ${f##*/}"
  awk '
    /Transferred:.*100%/     { last=$0 }
    /Elapsed time/           { et=$0 }
    END { if (last!="") print last; if (et!="") print et }
  ' "$f"
}

rcp_progress() {
  # Monitor rclone transfer progress with colored output
  # Usage: rcp_progress [--follow|-f] [needle|full_path]
  # Default: auto-exits at 100% or Elapsed time
  # With --follow/-f: stays open in less; Ctrl-C to stop following, then 'q' to exit
  local follow_mode=0 needle=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --follow|-f) follow_mode=1; shift ;;
      *) needle="$1"; shift ;;
    esac
  done

  local log="" nhout=""
  
  # Check if needle is a direct file path
  if [ -n "$needle" ] && [ -f "$needle" ]; then
    case "$needle" in
      *.log)       log="$needle" ;;
      *.nohup.out) nhout="$needle" ;;
      *)           log="$needle" ;;
    esac
  fi

  # Find newest matching log file if not direct
  if [ -z "$log" ] && [ -z "$nhout" ]; then
    if [ -n "$needle" ]; then
      local sane="$(_sanitize "$needle")"
      local wild="${needle// /*}"
      log="$(ls -1t "$RCLONE_LOGDIR"/rclone_*"$needle"*.log \
                    "$RCLONE_LOGDIR"/rclone_*"$sane"*.log \
                    "$RCLONE_LOGDIR"/rclone_*"$wild"*.log 2>/dev/null | head -n1)"
      nhout="$(ls -1t "$RCLONE_LOGDIR"/rclone_*"$needle"*.nohup.out \
                      "$RCLONE_LOGDIR"/rclone_*"$sane"*.nohup.out \
                      "$RCLONE_LOGDIR"/rclone_*"$wild"*.nohup.out 2>/dev/null | head -n1)"
    else
      log="$(ls -1t "$RCLONE_LOGDIR"/rclone_*.log 2>/dev/null | head -n1)"
      nhout="$(ls -1t "$RCLONE_LOGDIR"/rclone_*.nohup.out 2>/dev/null | head -n1)"
    fi
  fi

  # If we only found nohup, wait for the corresponding .log to be created
  if [ -z "$log" ] && [ -n "$nhout" ]; then
    local expected_log="${nhout%.nohup.out}.log"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ -s "$expected_log" ] && { log="$expected_log"; break; }
      sleep 2
    done
  fi

  if [ -z "$log" ]; then
    echo "No rclone logs found (yet)." >&2
    return 1
  fi

  # Fallback if less is not available (older/bare Synology boxes)
  if [ $follow_mode -eq 1 ] && ! command -v less >/dev/null 2>&1; then
    echo "less not found; falling back to auto-exit mode." >&2
    follow_mode=0
  fi

  echo "Tailing (log): $log"
  
  # Check if another tail is already following this log
  if ps -w 2>/dev/null | grep -v grep | grep -q "tail.*$log"; then
    echo "Note: another rcp_progress is already following this log." >&2
  fi
  
  # Check if the associated rclone process is still running
  local log_basename="${log##*/}"
  local log_tag="${log_basename#rclone_}"
  log_tag="${log_tag%%_[0-9]*}"
  if ! ps -ef 2>/dev/null | grep -v grep | grep -q "rclone.*${log_tag}"; then
    echo "Warning: No rclone process found matching this log. Transfer may have already completed." >&2
  fi
  
  [ $follow_mode -eq 1 ] \
    && echo "(Follow mode via less: Ctrl-C to stop following, then 'q' to exit)" \
    || echo "(Will auto-exit at completion)"

  # Colour setup (disable via: export RCP_NO_COLOR=1)
  local C_RESET C_CYAN C_YELLOW C_GREEN C_MAGENTA
  if [ -n "${RCP_NO_COLOR:-}" ]; then
    C_RESET= C_CYAN= C_YELLOW= C_GREEN= C_MAGENTA=
  else
    C_RESET="$(printf '\033[0m')"
    C_CYAN="$(printf '\033[1;36m')"
    C_YELLOW="$(printf '\033[1;33m')"
    C_GREEN="$(printf '\033[1;32m')"
    C_MAGENTA="$(printf '\033[1;35m')"
  fi

  # One colourizing awk script to use in both modes
  local AWK_COLOR='
    # Size-progress line (e.g., "771.500 MiB / 32.152 GiB, 2%, ...")
    /Transferred:[[:space:]]+[0-9.]+[[:space:]]+(MiB|GiB)[[:space:]]+\/[[:space:]]+[0-9.]+[[:space:]]+(MiB|GiB)/ {
      line=$0
      gsub(/\r/, "\n", line)
      gsub(/Transferred:/,            cyan "Transferred:" reset, line)
      gsub(/[0-9]+\.[0-9]+ (MiB|GiB)/, yellow "&"        reset, line)
      gsub(/[0-9]+%/,                 green  "&"         reset, line)
      gsub(/ETA [0-9msh-]+s?/,        magenta "&"        reset, line)
      print line
      fflush()
      next
    }

    # Count-progress line (e.g., "Transferred:  5 / 8, 62%")
    # We only exit when this exact line reports 100% of files.
    /Transferred:[[:space:]]+[0-9]+[[:space:]]*\/[[:space:]]*[0-9]+,[[:space:]]*100%/ {
      line=$0
      gsub(/\r/, "\n", line)
      gsub(/Transferred:/, cyan "Transferred:" reset, line)
      gsub(/100%/,        green "100%" reset,   line)
      print line
      print green "✓ Transfer complete!" reset
      fflush()
      if (exit_on_done) exit 0
      next
    }

    # Pretty-print (but DO NOT exit) on periodic elapsed-time lines
    /Elapsed time:/ {
      print green $0 reset
      fflush()
      next
    }
  '

  if [ $follow_mode -eq 1 ]; then
    # Follow in less; Ctrl-C exits follow mode, q exits less
    # -R: pass raw ANSI color codes; +F: follow mode (like tail -f)
    tail -f -n 10 "$log" 2>/dev/null \
    | awk -v cyan="$C_CYAN" -v yellow="$C_YELLOW" -v green="$C_GREEN" -v magenta="$C_MAGENTA" -v reset="$C_RESET" -v exit_on_done=0 "$AWK_COLOR" \
    | less -R +F
  else
    # Auto-exit mode: exits when transfer reaches 100%
    # Start from end to only watch NEW lines (avoids old completion messages)
    tail -f -n 0 "$log" 2>/dev/null \
    | awk -v cyan="$C_CYAN" -v yellow="$C_YELLOW" -v green="$C_GREEN" -v magenta="$C_MAGENTA" -v reset="$C_RESET" -v exit_on_done=1 "$AWK_COLOR"
  fi
}

rcp_jobs() {
  # List all currently running rclone copy/move processes
  ps -ef | grep -v grep | grep -E 'rclone (copy|move)' || true
}

rcp_stop() {
  # Stop an rclone process by PID and clean up its log files
  # Usage: rcp_stop <PID>
  
  if [ -z "$1" ]; then
    echo "Usage: rcp_stop <PID>" >&2
    return 1
  fi
  
  local pid="$1"
  
  # Get the full command line to find log file path
  local cmdline logfile nhoutfile
  cmdline=$(ps -p "$pid" -o args= 2>/dev/null)
  
  if [ -z "$cmdline" ]; then
    echo "Error: No process found with PID $pid" >&2
    return 1
  fi
  
  # Extract log file path from --log-file argument
  logfile=$(echo "$cmdline" | grep -o -- '--log-file [^ ]*' | cut -d' ' -f2)
  
  # Derive nohup file (same name but .nohup.out extension)
  if [ -n "$logfile" ]; then
    nhoutfile="${logfile%.log}.nohup.out"
  fi
  
  # Kill the process
  echo "Stopping rclone process (PID: $pid)..."
  if kill "$pid" 2>/dev/null; then
    echo "✓ Process stopped"
    
    # Clean up log files
    if [ -n "$logfile" ] && [ -f "$logfile" ]; then
      rm -f "$logfile"
      echo "✓ Removed incomplete log: ${logfile##*/}"
    fi
    
    if [ -n "$nhoutfile" ] && [ -f "$nhoutfile" ]; then
      rm -f "$nhoutfile"
      echo "✓ Removed nohup output: ${nhoutfile##*/}"
    fi
  else
    echo "Error: Failed to stop process $pid" >&2
    return 1
  fi
}

rcp_logs() {
  # List the 20 most recent rclone log files
  ls -1t "$RCLONE_LOGDIR"/rclone_*.log 2>/dev/null | head -n 20
}

rcp_last() {
  # Find the most recent rclone log or nohup file, optionally filtered by needle
  # Usage: rcp_last [needle]
  local needle="${1:-}"
  local p
  if [ -n "$needle" ]; then
    p="$(ls -1t "$RCLONE_LOGDIR"/rclone_*"$needle"* 2>/dev/null | head -n1)"
  else
    p="$(ls -1t "$RCLONE_LOGDIR"/rclone_* 2>/dev/null | head -n1)"
  fi
  [ -z "$p" ] && { echo "No logs found." >&2; return 1; }
  echo "$p"
  if echo "$p" | grep -q '\.log$'; then
    grep -m1 -E 'Transferred:|[0-9.]+ [MG]iB / [0-9.]+' "$p" >/dev/null \
      && echo "→ This .log has progress lines." \
      || echo "→ This .log has NO progress lines (older run)."
  else
    echo "→ This is a .nohup.out (older stdout stream)."
  fi
}

rcp_cleanlogs() {
  # Delete old rclone log files
  # Usage: rcp_cleanlogs [days]  (default 14)
  local days="${1:-14}"
  echo "Deleting logs older than $days days in $RCLONE_LOGDIR"
  find "$RCLONE_LOGDIR" -maxdepth 1 -name 'rclone_*.log'       -mtime +"$days" -print -delete 2>/dev/null || true
  find "$RCLONE_LOGDIR" -maxdepth 1 -name 'rclone_*.nohup.out' -mtime +"$days" -print -delete 2>/dev/null || true
}

rcp_flushlogs() {
  # Delete all rclone logs EXCEPT the most recent one
  # Safe to run anytime - won't delete active logs
  # Usage: rcp_flushlogs
  
  # Find the newest log and nohup files
  local newest_log newest_nohup
  newest_log="$(ls -1t "$RCLONE_LOGDIR"/rclone_*.log 2>/dev/null | head -n1)"
  newest_nohup="$(ls -1t "$RCLONE_LOGDIR"/rclone_*.nohup.out 2>/dev/null | head -n1)"
  
  local count=0 f

  # Delete all .log files except the newest
  if [ -n "$newest_log" ]; then
    echo "Keeping newest log: ${newest_log##*/}"
    for f in "$RCLONE_LOGDIR"/rclone_*.log; do
      [ -f "$f" ] || continue
      if [ "$f" != "$newest_log" ]; then
        rm -f "$f" && count=$((count + 1))
      fi
    done
  fi

  # Delete all .nohup.out files except the newest
  if [ -n "$newest_nohup" ]; then
    echo "Keeping newest nohup: ${newest_nohup##*/}"
    for f in "$RCLONE_LOGDIR"/rclone_*.nohup.out; do
      [ -f "$f" ] || continue
      if [ "$f" != "$newest_nohup" ]; then
        rm -f "$f" && count=$((count + 1))
      fi
    done
  fi

  if [ $count -eq 0 ]; then
    echo "No old logs to delete."
  else
    echo "Deleted $count old log file(s)."
  fi
}

# ============================================================================
# QUEUE MANAGEMENT SYSTEM
# ============================================================================

rcp_queue() {
  # Add a transfer command to the queue
  # Usage: rcp_queue rcp_tv <args...>
  #        rcp_queue rcp_movie <args...>
  #        rcp_queue rcp_audiobook <args...>
  # Example: rcp_queue rcp_tv "Show.S01.1080p" "Breaking Bad/Season 01"
  
  if [ $# -lt 2 ]; then
    echo "Usage: rcp_queue <rcp_tv|rcp_movie|rcp_audiobook|rcp_verify> <args...>" >&2
    return 1
  fi
  
  local cmd="$1"
  shift
  
  # Validate command
  case "$cmd" in
    rcp_tv|rcp_movie|rcp_audiobook|rcp_verify) ;;
    *)
      echo "Error: Invalid command '$cmd'. Use rcp_tv, rcp_movie, rcp_audiobook, or rcp_verify." >&2
      return 1
      ;;
  esac
  
  # Ensure queue directory exists
  mkdir -p "$RCLONE_QUEUEDIR" || return 1
  
  local qfile="$RCLONE_QUEUEDIR/queue"
  
  # Build command string with proper quoting
  local full_cmd="$cmd"
  for arg in "$@"; do
    # Escape single quotes in arguments
    local escaped="${arg//\'/\'\\\'\'}"
    full_cmd="$full_cmd '$escaped'"
  done
  
  # Acquire lock and append to queue
  if _queue_lock; then
    echo "$full_cmd" >> "$qfile"
    _queue_unlock
    
    # Count items in queue
    local count
    count=$(wc -l < "$qfile" 2>/dev/null || echo 0)
    echo "✓ Queued: $cmd ${1:0:40}..."
    echo "  Position in queue: #$count"
  else
    echo "Error: Could not acquire queue lock" >&2
    return 1
  fi
}

rcp_qstatus() {
  # Show current queue contents and worker status
  # Usage: rcp_qstatus
  
  local qdir="$RCLONE_QUEUEDIR"
  local qfile="$qdir/queue"
  local wpidf="$qdir/worker.pid"
  local wlock="$qdir/.worker.lock"

  # Check worker status
  if [ -d "$wlock" ] && [ -f "$wpidf" ]; then
    local wpid
    wpid="$(cat "$wpidf" 2>/dev/null)"
    if [ -n "$wpid" ] && ps -p "$wpid" -o comm= 2>/dev/null | grep -q 'sh\|bash\|ash'; then
      echo "🔄 Worker is RUNNING (PID: $wpid)"
    else
      echo "⚠️  Worker lock present but PID looks stale"
      echo "   Remove: rm -rf '$wlock' '$wpidf'"
    fi
  else
    echo "⏸️  Worker is NOT running"
    echo "   Start with: rcp_worker"
  fi
  echo

  # Show queue contents
  if [ ! -s "$qfile" ]; then
    echo "Queue is empty."
    return 0
  fi

  echo "Queued transfers:"
  echo "────────────────────────────────────────────────────────────"
  nl -ba "$qfile"
  echo "────────────────────────────────────────────────────────────"
  local count
  count=$(wc -l < "$qfile" 2>/dev/null || echo 0)
  echo "Total: $count item(s) in queue"
}

rcp_qclear() {
  # Clear all pending items from queue
  # Usage: rcp_qclear
  
  local qfile="$RCLONE_QUEUEDIR/queue"
  
  if [ ! -f "$qfile" ] || [ ! -s "$qfile" ]; then
    echo "Queue is already empty."
    return 0
  fi
  
  local count
  count=$(wc -l < "$qfile" 2>/dev/null || echo 0)
  
  if _queue_lock; then
    > "$qfile"  # Truncate file
    _queue_unlock
    echo "✓ Cleared $count item(s) from queue"
  else
    echo "Error: Could not acquire queue lock" >&2
    return 1
  fi
}

rcp_worker() {
  # Process queue in background (one transfer at a time)
  # Uses singleton lock to prevent multiple workers
  # Runs transfers in foreground (blocking) for true sequential execution
  
  local qdir="$RCLONE_QUEUEDIR"
  local qfile="$qdir/queue"
  local wpidf="$qdir/worker.pid"
  local wlog="$qdir/worker.log"
  local wlock="$qdir/.worker.lock"

  mkdir -p "$qdir" || return 1

  # Acquire singleton lock for the whole worker lifetime
  if ! mkdir "$wlock" 2>/dev/null; then
    echo "Worker already running (lock present). See: $wlog"
    return 1
  fi

  # Start worker in background
  (
    # Ensure lock cleanup on exit
    trap 'rm -f "$wpidf"; rmdir "$wlock" 2>/dev/null || true' EXIT INT TERM

    echo "$$" > "$wpidf"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Worker started (PID: $$)" >> "$wlog"

    while :; do
      # Nothing to do?
      if [ ! -s "$qfile" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Queue empty, worker exiting" >> "$wlog"
        break
      fi

      # Pop the first line atomically
      local line tmp
      tmp="$qfile.tmp.$$"
      
      # Lock the queue just for the pop
      if _queue_lock; then
        line="$(head -n1 "$qfile" 2>/dev/null)"
        tail -n +2 "$qfile" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$qfile"
        _queue_unlock
      else
        sleep 1
        continue
      fi

      [ -z "$line" ] && continue

      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Executing: $line" >> "$wlog"

      # Run the job in FOREGROUND (blocks until done)
      RCP_FOREGROUND=1 eval "$line"
      local ec=$?

      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Finished (exit $ec): $line" >> "$wlog"

      # Optional: brief pause to reduce churn
      sleep 1
    done

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Worker stopped" >> "$wlog"
  ) >/dev/null 2>&1 &

  local wp=$!
  echo "✓ Worker started in background (PID: $wp)"
  echo "  Log: $wlog"
  echo "  Monitor: tail -f '$wlog'"
}

# --- END RCLONE HELPERS ---