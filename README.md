# pdf-backup

Suspend/resume rsync replication of the RAID0 PDF archive to a dedicated backup drive.

## System

| Role | Path | Device | Size |
|------|------|--------|------|
| Source | `/mnt/raid0/monolithic_pdf_folder` | `md0` (RAID0: sdc2+sdg2) | ~4.4T, ~2.4M PDFs |
| Destination | `/mnt/pdf_backup` | `/dev/sda1` | 3.5T usable |

Because the full archive (~4.4T) exceeds the destination (3.5T), files over `MAX_FILE_SIZE`
(default `50M`) are excluded. Adjust this threshold in `config.env` to tune what fits.

## Quick start

```bash
# 1. edit thresholds if needed
nano config.env

# 2. dry run first — see what would transfer, no writes
sudo ./pdf-backup.sh --dry-run 2>&1 | tee dryrun.log

# 3. start the real transfer (safe to run in background or tmux)
sudo ./pdf-backup.sh

# 4. observe from another terminal
./status.sh
# or live tail:
tail -f /var/log/pdf-backup/rsync.log

# 5. stop safely (partial files kept, next run resumes)
sudo ./stop.sh

# 6. resume — just re-run pdf-backup.sh
sudo ./pdf-backup.sh

# 7. verify after completion
sudo ./verify.sh
sudo ./verify.sh --spot-check 500   # MD5 check 500 random files
```

## Scripts

| Script | Purpose |
|--------|---------|
| `pdf-backup.sh` | Main runner. Idempotent — safe to kill and re-run. |
| `stop.sh` | Graceful SIGTERM to rsync. Partial files preserved for resume. |
| `status.sh` | Snapshot: process state, disk usage, file count, recent log lines. |
| `verify.sh` | Post-run verification. Counts files/bytes; optional MD5 spot-check. |
| `config.env` | All tunable parameters (source, dest, max size, log path). |

## Resume behaviour

rsync is invoked with:
- `--partial` + `--partial-dir` — interrupted file chunks saved to `/mnt/pdf_backup/.rsync-partial/`
- `--append-verify` — on resume, appends to the partial chunk then checksums the complete file

Killing the process (Ctrl-C, `./stop.sh`, reboot) is safe. Re-run `pdf-backup.sh` to continue.

## Tuning the size filter

The `MAX_FILE_SIZE` knob in `config.env` controls which PDFs are included:

```bash
# estimate how much data falls under various thresholds:
find /mnt/raid0/monolithic_pdf_folder -name "*.pdf" -size -10M  -printf "%s\n" | awk '{s+=$1} END {printf "Under 10M:  %.1f GB\n", s/1073741824}'
find /mnt/raid0/monolithic_pdf_folder -name "*.pdf" -size -50M  -printf "%s\n" | awk '{s+=$1} END {printf "Under 50M:  %.1f GB\n", s/1073741824}'
find /mnt/raid0/monolithic_pdf_folder -name "*.pdf" -size -100M -printf "%s\n" | awk '{s+=$1} END {printf "Under 100M: %.1f GB\n", s/1073741824}'
```

Run these against the source before starting to pick a threshold that fits in 3.3T.

## Log location

`/var/log/pdf-backup/rsync.log` — append-only; each run adds a timestamped header.

## Host context

- **Host:** worlock (192.168.1.135)
- **Source RAID0:** `md0` — sdc2 + sdg2, 10.9T, 88% full, zero redundancy
- **Dest drive:** WDC WD4005FZBX, serial VBGZSTNF, 4TB 7200rpm
  - Reformatted 2026-03-27 from ext4 (WD_Storage) → ext4 tuned (`-i 4096`, ~977M inodes)
  - UUID: `674dd29f-6ba6-4f0f-80a8-58a0dded2c98`
  - fstab: `defaults,noatime,commit=60,nofail`
- **Kernel note:** Running 6.8.12 (custom) — XFS disabled (`CONFIG_XFS_FS` not set).
  ext4 used instead. If booting into a stock Ubuntu kernel (6.8.0-106-generic), XFS is available.

## Open items

- [ ] Determine correct `MAX_FILE_SIZE` threshold (run size-distribution commands above)
- [ ] First dry run to estimate transfer scope
- [ ] Decide whether to acquire a larger drive (6TB+) to hold the full 4.4T archive
- [ ] Consider periodic re-runs (cron/systemd timer) to sync newly ingested PDFs
