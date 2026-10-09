# Upload antivirus

GPForum scans every upload with the free antivirus the operating system's
package manager installs — ClamAV — and serves no new upload until something
has decided it is clean ([ADR 0108](../adr/0108-uploads-scanned-by-the-system-antivirus.md)).
GPForum installs and bundles none of it: the operator installs the system
package, and GPForum finds its daemon where that package puts the socket.

Staging and production scan with `clamd` by default. Development and test do
not assume an antivirus is installed.

## Install and start the system ClamAV

### Debian and Ubuntu

```sh
apt install clamav-daemon clamav-freshclam
systemctl enable --now clamav-freshclam clamav-daemon
```

Socket: `/var/run/clamav/clamd.ctl`. The GPForum units start after
`clamav-daemon.service` when it is enabled, and do not start it themselves: an
operator who disabled it on purpose keeps it disabled.

### FreeBSD

```sh
pkg install clamav
sysrc clamav_freshclam_enable=YES clamav_clamd_enable=YES
service clamav_freshclam start
service clamav_clamd start
```

Socket: `/var/run/clamav/clamd.sock`. The `gpforum` rc.d script requires
`clamav_clamd`.

### macOS (Homebrew)

```sh
brew install clamav
etc="$(brew --prefix)/etc/clamav"
cp "$etc/freshclam.conf.sample" "$etc/freshclam.conf"
cp "$etc/clamd.conf.sample" "$etc/clamd.conf"
sed -i '' 's/^Example/#Example/' "$etc/freshclam.conf" "$etc/clamd.conf"
mkdir -p "$(brew --prefix)/var/run/clamav"
printf 'LocalSocket %s\nStreamMaxLength 26M\n' \
    "$(brew --prefix)/var/run/clamav/clamd.sock" >> "$etc/clamd.conf"
freshclam
sudo brew services start clamav
```

The formula ships both configuration files only as samples, each with an
`Example` line that stops the daemon until it is removed, and `clamd.conf`
declares no socket; the lines above give it the one GPForum expects.
`brew services` runs clamd; freshclam has no service of its own, so schedule
it (for example `0 */4 * * * $(brew --prefix)/bin/freshclam --quiet` in the
crontab of the user that owns Homebrew).

Socket: `/opt/homebrew/var/run/clamav/clamd.sock` (on an Intel Mac Homebrew
lives under `/usr/local`: set `GPFORUM_ANTIVIRUS_SOCKET` to
`/usr/local/var/run/clamav/clamd.sock`).

### Other systems

Install the system's ClamAV package and set `GPFORUM_ANTIVIRUS_SOCKET` to the
`LocalSocket` its `clamd.conf` declares.

## Two settings to check in clamd.conf

- **`StreamMaxLength`** must exceed GPForum's largest upload (25 MB): set
  `StreamMaxLength 26M`. A file above the limit is not scanned, is not
  served, and the check below reports clamd's own `size limit` error.
- **The socket must admit the `gpforum` user.** If it cannot connect,
  `bin/gpforum-antivirus-check` says `Permission denied`. Give the socket a
  group the `gpforum` user belongs to (`LocalSocketGroup`, `LocalSocketMode`)
  or add the user to the socket's group.

## Verify it works

Run it as the service user, so it connects to clamd's socket as the service
does; `gpforum` reads the service's environment file itself
([DEPLOYMENT.md](../DEPLOYMENT.md#install-on-debian-or-ubuntu), step 4):

```sh
sudo -u gpforum gpforum antivirus-check
```

(`bin/gpforum-antivirus-check` and `make antivirus-check` run the same check
in whatever environment they are given.)

```text
✓ antivirus: ClamAV 1.4.1/27400 finds the test file and lets an ordinary one through

Nothing to fix.
```

A clamd that does not answer is said once, with what to do: install it,
start it, or set `GPFORUM_ANTIVIRUS=none` in the file the command read.

It scans the EICAR test file, which every antivirus must detect, an ordinary
file, which must pass, and a file as large as the upload limit, which must
pass too — a `StreamMaxLength` below 26M fails here. Readiness only asks whether clamd answers;
this proves it scans. Exit status: `0` ok, degraded or disabled, `1` failed (including a
scanner that is misconfigured), `2` misuse, `78` settings GPForum cannot use,
reported as every command reports them. `--json` gives the same evidence as JSON. An
error the check raises instead of reporting exits `1` too, with its reason on
standard error (an inline `password=` shown as `[redacted]`); with `--json`
the evidence still comes, `status` `fail`, the reason in `error`, `problems`
empty.

### From the console

`/admin/settings` has a **Run antivirus check** button that runs the same
check inside the running service, so it sees the service's own environment
and scanner. It shows the report -- engine, health, whether EICAR was
detected, whether the ordinary file and the one at the upload limit passed,
and any problem -- and records it in the audit log
(`admin.antivirus_checked`). With `GPFORUM_ANTIVIRUS=command` the console
offers no button: clamscan loads its signatures for every file, and three
scans outlast a web request. Run the check above instead.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `GPFORUM_ANTIVIRUS` | `clamd` in staging and production, `none` elsewhere | `clamd`, `command` or `none` |
| `GPFORUM_ANTIVIRUS_SOCKET` | the socket the OS package declares | clamd's `LocalSocket` |
| `GPFORUM_ANTIVIRUS_COMMAND` | — | for `command`: the scanner and its options, split on whitespace; the file path is appended |
| `GPFORUM_ANTIVIRUS_TIMEOUT_SECONDS` | `30` for clamd, `120` for a command | bound on every scan by the attachment worker and the scheduled jobs, whole run included |

Inside a web request — the scan at upload, and `/health/ready` — clamd gets at
most three seconds, whatever this setting says. Hypnotoad restarts a worker
that sends no heartbeat for `GPFORUM_RUNTIME_HEARTBEAT_INTERVAL` +
`GPFORUM_RUNTIME_HEARTBEAT_TIMEOUT` (ten seconds as shipped), and a request
waiting on clamd sends none. A scan that does not fit is left pending for the
worker.

**A small server** that will not keep a resident clamd (about 1–1.5 GB of RAM
with the full signature set) can use the scanner command instead:

```sh
GPFORUM_ANTIVIRUS=command
GPFORUM_ANTIVIRUS_COMMAND='/usr/bin/clamscan --no-summary'
```

`clamscan` loads its signatures on every run, so each file takes seconds;
uploads wait `pending` for the attachment worker instead of being scanned in
the request. With a running clamd, prefer `clamdscan --fdpass --no-summary`.

**Turning scanning off** (`GPFORUM_ANTIVIRUS=none`) is an explicit choice.
Uploads are then checked for format only, recorded as
`scan_engine = 'format-check'`, and readiness reports the antivirus as
`degraded` in staging and production.

## What happens when clamd is down

- An upload that cannot be scanned stays `pending` and is **not served**.
- The attachment worker retries it through the outbox with backoff. After
  the last attempt the event becomes a dead letter, which
  `bin/gpforum-dead-letter-check` reports.
- The hourly scheduled jobs (`attachment_scans`) scan whatever is still
  pending, oldest first, so a file uploaded during a long outage becomes
  available within the hour after clamd is back. While clamd is still down
  the job does not start and reports `attachment_scans_error="antivirus
  unavailable"` (`✗ uploads waiting for a scan: antivirus unavailable` by
  hand), and the run exits 1 so the timer unit is marked failed. A file that fails by itself is counted on its row
  (`scan_attempts`, `scan_error`) and skipped; files with fewer attempts come
  first, so failures cannot hold back the rest. To clear the backlog at once:

  ```sh
  gpforum scheduled-jobs --once --job attachment_scans
  ```
- `/health/ready` reports the `antivirus` check as `degraded` — never `fail`,
  because the rest of the forum works and taking the node out of service
  would not help. The check itself is in the full report, which needs the
  metrics token
  ([../DEPLOYMENT.md#health-endpoints](../DEPLOYMENT.md#health-endpoints));
  without it the body says only `degraded`.

## Files uploaded before scanning was enabled

Attachments from before the antivirus — or uploaded while
`GPFORUM_ANTIVIRUS=none` — were checked for format only, and **stay served**
until the hourly `attachment_backfill` job has put them through the antivirus,
oldest first. Withdrawing them all at once would take the forum's history
offline for as long as the backfill takes. What it finds is quarantined; what
passes records the engine that confirmed it and is not scanned again.

Right after enabling the antivirus on a forum with many attachments, run the
backfill by hand in large batches, as the service user with the service's
environment (see above), until a run says **`✓ uploads never scanned: 0
scanned`**. A `✗` line means the antivirus was unreachable, and `not run
(scanning is off)` that scanning was off where it ran:

```sh
gpforum scheduled-jobs --once --job attachment_backfill --limit 5000
```

## What a verdict records

`attachments.scan_status` is `clean`, `infected` (an antivirus found
something), `failed` (the stored bytes no longer match the declared media
type) or `pending`. `scan_engine` names what decided — `ClamAV 1.4.1/27400`,
`format-check`, or NULL for a file decided before scanning existed — and
`scan_signature` names what was found. Only `clean` is ever served.

Verdicts only tighten. A clean file may later be quarantined (the backfill, a
newer signature); nothing becomes clean over an infected or failed verdict,
even when two scans race.

An antivirus detects known threats. It lowers the risk of a malicious upload;
it does not remove it.
