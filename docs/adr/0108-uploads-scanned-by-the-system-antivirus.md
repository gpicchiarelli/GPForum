# ADR 0108: Uploads Are Scanned by the Operating System's Free Antivirus

## Status

Accepted. Implements ADR 0053's "Uploads MUST support antivirus scanning",
which was unmet.

## Context

ADR 0053 requires that uploads support antivirus scanning. Nothing in GPForum
did: `scan_status` was a content-consistency check -- the stored bytes still
sniff to the declared media type -- and its `infected` value meant a media
mismatch, not malware. A valid PDF carrying an exploit passed, because its
format was right. Worse, the upload marked every file `clean` synchronously,
so the attachment worker that was meant to re-check the stored bytes found a
finished verdict and never ran.

The owner's decision on how to meet the MUST: assume a free antivirus that the
operating system's package manager installs, and bundle or install nothing.
ClamAV (GPL) is the mature free engine and is packaged by every system
GPForum supports; the other free tools either use it underneath (Linux
Malware Detect) or are rule engines without their own signatures (YARA).

## Decision

**The system's antivirus decides, and no new upload is served until something has.**

- `GPFORUM_ANTIVIRUS` names the engine: `clamd` (default in staging and
  production), `command`, or `none` (default in development and test).
- `clamd` is the daemon of the operating system's ClamAV package, reached on
  the local socket that package declares. The OS layer knows where each
  package puts it; `GPFORUM_ANTIVIRUS_SOCKET` overrides it:

  | System | Packages | Socket |
  | --- | --- | --- |
  | Debian, Ubuntu | `clamav-daemon`, `clamav-freshclam` | `/var/run/clamav/clamd.ctl` |
  | FreeBSD | `clamav` (`clamav_clamd`, `clamav_freshclam`) | `/var/run/clamav/clamd.sock` |
  | macOS (MacPorts) | `clamav`, `clamav-server` | `/opt/local/var/run/clamav/clamd.socket` |

  Content is streamed with `INSTREAM`, so clamd needs no access to GPForum's
  storage.
- `command` runs a scanner the system installed, once per file, without a
  shell, on a private copy, reading ClamAV's exit convention (0 clean,
  1 found, other error): `clamdscan --fdpass`, or `clamscan` on a server that
  will not keep a resident daemon.
- `none` is an explicit choice. The media type check is then the whole
  verdict, and the row records `scan_engine = 'format-check'` rather than
  implying a malware scan.

The flow:

1. The upload validates and stores the file as before.
2. A fast scanner (`clamd`) scans it inside the request. `clean` is served;
   `infected` is quarantined, with the signature recorded.
3. A slow scanner, or one that cannot answer, leaves the file `pending`. The
   attachment worker scans it: the stored bytes must still sniff to the
   declared type (otherwise `failed`, reason `media mismatch` -- not
   `infected`, because it is not malware), then the antivirus decides. When
   the antivirus cannot answer, or the stored object cannot be read, the
   worker dies on purpose: the outbox retries with backoff and records a dead
   letter after its last attempt, and the hourly `attachment_scans` job scans
   whatever is still pending once the antivirus answers. The file stays
   `pending` throughout, and `pending` is never served.
4. Files served before scanning existed, or while it was off, are put through
   the antivirus by the hourly `attachment_backfill` job, oldest first. They
   stay served until it reaches them: withdrawing every existing attachment
   at once would take the forum's history offline for however long the
   backfill takes. What it finds is quarantined.

**Verdicts only tighten.** A verdict is written in the same `UPDATE` that
checks it may be: any verdict over `pending`, `infected` or `failed` over
`clean`, never `clean` over `infected` or `failed`, and never over a deleted
file. When two scans race -- the outbox retry and the hourly rescan -- the
database decides and the loser replays the verdict that stands.

**An error is never a verdict.** A scanner that cannot connect, times out,
exits with an unexpected status or is killed by a signal (the OOM killer, a
crash on a crafted file) produces an error, which leaves the file pending.
Every wait on clamd's socket counts down to one deadline per scan, and the
scanner command's timeout covers its whole run. The timeout defaults to 30 s
for clamd and 120 s for a scanner command, which loads its signatures per
file.

Every verdict records `scan_engine` (for example `ClamAV 1.4.1/27400`) and,
for a detection, `scan_signature` (migration 043). The `attachment.scanned`
and `attachment.quarantined` payloads carry both; ADR 0071 has consumers
ignore unknown fields, so the payload version is unchanged.

Readiness reports the antivirus as `degraded`, never `fail`: an antivirus that
cannot scan holds uploads back, and the rest of the forum works. Signatures
older than three days also degrade it. `bin/gpforum-antivirus-check` proves
detection by scanning the EICAR test file, which readiness does not.

## Consequences

- Uploads are scanned for known malware on every supported system, with the
  engine that decided on record.
- An operator must install and run the system's ClamAV in staging and
  production, or set `GPFORUM_ANTIVIRUS=none` and accept format checking only.
  A resident clamd with the full signature set needs about 1–1.5 GB of RAM;
  `command` with `clamscan` avoids that at the cost of a slow scan per file.
- An antivirus detects known threats. It reduces the risk of a malicious
  upload; it does not remove it.
- A file uploaded while clamd is down becomes available only once clamd is
  back and the worker, or the hourly rescan, has scanned it.
- Files from before this ADR remain served until the backfill has scanned
  them. On a forum with many attachments, run it by hand with a large
  `--limit` right after enabling the antivirus.
- The stored-bytes check runs for uploads the request could not decide. An
  upload decided in the request was scanned from the same bytes it wrote.

## Alignment

- ADR 0053 — the MUST this implements.
- ADR 0071 — the event contract the new payload fields respect.
- ADR 0107 — the layering: the clients live in `Infrastructure`, the per-OS
  knowledge in `OS`.
- `lib/GPForum/Infrastructure/Antivirus*.pm`, `lib/GPForum/OS/*.pm`
  (`antivirus_packaging`), `Service::Attachment::UploadPipeline`,
  `Worker::Handler::AttachmentScanning`, `Service::Operations::AntivirusCheck`.
- `t/193`–`t/197`, `t/integration/clamav.t`; `docs/ops/antivirus.md`.
