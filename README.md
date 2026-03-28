# pdf-backup

Suspend/resume rsync replication of the RAID0 PDF archive to a dedicated backup drive,
with live monitoring, ETA, and post-transfer verification.

## System

| Role | Path | Device | Size |
|------|------|--------|------|
| Source | `/mnt/raid0/monolithic_pdf_folder` | `md0` (RAID0: sdc2+sdg2) | 4.7T, ~2.5M files |
| Destination | `/mnt/pdf_backup` | `/dev/sda1` (WDC WD4005FZBX) | 3.5T usable |

Because the full archive (4.7T) exceeds the destination (3.5T), files over `MAX_FILE_SIZE`
are excluded. The threshold was determined by size-distribution analysis:

| Max file size | Files | Size | Fits? |
|--------------|-------|------|-------|
| **10M** | **2,400,204** | **2.6 TiB** | **Yes — selected** |
| 25M | 2,478,432 | 3.6 TiB | No |
| 50M+ | 2.5M+ | 4.1–4.4 TiB | No |

67.5% of all PDFs are under 1MB. The ~100K excluded files (>10M) are large scans/books.

## Quick start

```bash
# 1. edit thresholds if needed
nano config.env

# 2. dry run first — see what would transfer, no writes
sudo ./pdf-backup.sh --dry-run 2>&1 | tee dryrun.log

# 3. start the real transfer (safe to run in tmux or leave terminal open)
sudo ./pdf-backup.sh

# 4. monitor from a second terminal (live ETA + throughput + iostat)
./watch-backup.sh          # refreshes every 10s
./watch-backup.sh 5        # faster, every 5s

# 5. or use the log-based status snapshot
./status.sh
tail -f /var/log/pdf-backup/rsync.log

# 6. stop safely — partial files kept, next run resumes
sudo ./stop.sh

# 7. resume — just re-run
sudo ./pdf-backup.sh

# 8. verify after completion
sudo ./verify.sh
sudo ./verify.sh --spot-check 500   # MD5 check 500 random files
```

## Scripts

| Script | Purpose |
|--------|---------|
| `pdf-backup.sh` | Main runner. Idempotent — safe to kill and re-run. |
| `stop.sh` | Graceful SIGTERM to rsync. Partial files preserved for resume. |
| `watch-backup.sh` | **Live monitor** — progress bar, ETA, throughput, kernel I/O stats. Run in a second terminal. No root required. |
| `status.sh` | Snapshot: process state, disk usage, file count, recent log lines. |
| `verify.sh` | Post-run verification. Counts files/bytes; optional MD5 spot-check. |
| `config.env` | All tunable parameters (source, dest, max size, log path). |

## watch-backup.sh

Passive monitor that shows at a glance:
- Progress bar vs expected 2.93T transfer total
- PDF count accumulating at destination
- Current write throughput and ETA (with avg-rate fallback)
- 1-second kernel I/O sample for `sda` (dest) and `md0` (source RAID)
- Elapsed runtime

```
╔══════════════════════════════════════════════════╗
║           pdf-backup live monitor                ║
╚══════════════════════════════════════════════════╝
 Updated:    22:16:49  (every 10s)
 rsync:      RUNNING (PID 43038)

 ── Progress ────────────────────────────────────
 Written:    22.22 GiB / 2.66 TiB  (0%)
 [█░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]
 PDFs:       27491 files
 Avail left: 3.20 TiB

 ── Throughput ──────────────────────────────────
 Current:    4.27 MiB/s
 Runtime:    8m 12s
 ETA:        9h 43m

 ── I/O (kernel, 1s sample) ─────────────────────
md0 (src):   read 2675.4 KB/s  write    0.0 KB/s
sda (dest):  read 28921.1 KB/s  write 4362.7 KB/s
```

## Resume behaviour

rsync is invoked with:
- `--partial` — interrupted partial files kept in-place at destination
- `--append-verify` — on resume, appends remaining bytes then checksums the whole file

Killing the process (Ctrl-C, `./stop.sh`, reboot) is safe. Re-run `pdf-backup.sh` to continue
exactly where it left off.

## Tuning the size filter

The `MAX_FILE_SIZE` knob in `config.env` controls which files are included.
To re-evaluate thresholds:

```bash
for t in 10M 25M 50M 100M; do
  c=$(sudo find /mnt/raid0/monolithic_pdf_folder -name "*.pdf" -size -${t} 2>/dev/null | wc -l)
  b=$(sudo find /mnt/raid0/monolithic_pdf_folder -name "*.pdf" -size -${t} -printf "%s\n" 2>/dev/null | awk '{s+=$1} END {print s+0}')
  printf "Under %5s: %7d files, %s\n" "$t" "$c" "$(numfmt --to=iec-i --suffix=B $b)"
done
```

## Log location

`/var/log/pdf-backup/rsync.log` — append-only; each run adds a timestamped header.

## Host context

- **Host:** worlock (192.168.1.135)
- **Source RAID0:** `md0` — sdc2 + sdg2, 10.9T total, 88% full, **zero redundancy**
- **Dest drive:** WDC WD4005FZBX, serial VBGZSTNF, 4TB 7200rpm
  - SMART: PASSED, 0 reallocated sectors, 20,763 power-on hours at time of setup
  - Reformatted 2026-03-27: wiped old ext4 (WD_Storage label), new GPT, single ext4 partition
  - Format flags: `mkfs.ext4 -L pdf_backup -i 4096` (~977M inodes, tuned for millions of small files)
  - UUID: `674dd29f-6ba6-4f0f-80a8-58a0dded2c98`
  - fstab: `defaults,noatime,commit=60,nofail`
  - Mount: `/mnt/pdf_backup`
- **Kernel note:** Running 6.8.12 (custom, `CONFIG_XFS_FS` not set). ext4 used.
  Stock Ubuntu kernels (6.8.0-106-generic) have XFS available if needed.

## Supporting infrastructure

### logrotate
`/etc/logrotate.d/pdf-backup` — rotates at 500M, 4 compressed generations, `copytruncate`
(safe to rotate while rsync is writing). Prevents `/var/log` filling during a 2.4M-file run.

### smartd
`smartmontools.service` enabled and running. `/etc/smartd.conf` monitors all drives with
temperature alerting (`-W DIFF,INFO,CRIT`) and scheduled self-tests:

| Drive | Role | Temp alerts | Note |
|-------|------|-------------|------|
| sda (WDC WD4005FZBX) | pdf_backup | 4°/45°/52° | Short daily 2am, long Sat 3am |
| sdc (IronWolf ZL2PLEG9) | RAID0 | 4°/44°/50° | Short daily 2am, long Sat 3am |
| sdg (IronWolf ZLW2HXSN) | RAID0 | 3°/43°/48° | **⚠ attr 190 hit threshold (max 47°C)** |

**sdg warning:** Airflow_Temperature hit its manufacturer threshold in the past. Alerting
tightened — sdg is the most likely failure point on this array.

### sdc1
5.5T ext4 on same physical disk as RAID member sdc2. Investigated 2026-03-27:
- 4.4T used / 918G free (83% full), fsck clean
- `files/` (4.2T) is the dominant unknown; rest is ML models, LLM WebUI, media, CAD, text archives
- Only 918G free — not viable for PDF overflow without clearing `files/`
- Leave as-is; revisit if `files/` contents can be moved or deleted

## Open items

- [ ] Monitor initial transfer to completion; run `verify.sh` when done
- [ ] Set up systemd timer for periodic re-sync as new PDFs land on RAID0
- [ ] Acquire 6TB+ drive to capture excluded large files (>10M, ~100K files)
- [ ] **Urgent:** Investigate sdg thermals — airflow, drive placement, possible replacement
- [ ] Consider RAID0 → redundant array — zero fault tolerance on 4.7T archive
