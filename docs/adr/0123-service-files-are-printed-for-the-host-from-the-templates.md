# ADR 0123: Service Files Are Printed for the Host, From the Templates

## Status

Accepted (2026-10-09). Implements item C2 of the operator walkthrough
(`docs/ops/evidence/2026-10-07-operator-walkthrough`, section 5.3) under
owner decision D8: GPForum writes the environment file and the database
objects, and the service files are **printed** for the operator to copy.
Builds on ADR 0120 (the front door). Amended for iteration 4 (2026-10-10, last
section): the units run `bin/gpforum` alone, and `--to` the host's own
directory puts the files in place.

## Context

Iteration 2 of the walkthrough (`docs/ops/evidence/2026-10-09-operator-walkthrough-2`)
left the service files to the operator, and ranked what that cost:

- **Debian** copied six units by name, then edited nginx's site with a `sed`
  for the forum's name. Two of the nineteen steps were this copy.
- **macOS** had no working path (friction 4). The plists hard-coded
  `/opt/gpforum` and `/usr/local/var/log`, so a checkout elsewhere, or
  Homebrew on Apple silicon, was copied with the wrong paths. Doctor's fix
  for missing plists was a single `sudo cp` of about 700 characters, with no
  `launchctl bootstrap` after it. Its proxy fix sent a Mac to Debian's
  nginx step.
- **FreeBSD** shipped no file for its hourly and daily jobs: two crontab
  lines lived in two runbooks.
- **Doctor's fixes** repeated the checkout's absolute path for every file
  (friction 5).

The files in `deploy/` are read by `DeployContract`, the deploy checklist
drill and t/18, which hold them to their contract. A second copy, such as
a template language or units generated in code, would drift from them.

## Decision

1. **`gpforum service print [systemd|rc|launchd|nginx|caddy] [FILE...]`**,
   in the Set up group. Without a target it prints the files for the host's
   service manager: systemd on Linux, rc on FreeBSD, launchd on macOS. Every
   OS gets the outbox worker. systemd gets both timers. FreeBSD gets its
   jobs as `deploy/freebsd/gpforum_jobs`, a crontab that cron reads from
   `/usr/local/etc/cron.d/`. The proxies keep the upload limit and
   `/metrics` restricted to the loopback, as their templates do.
2. **The templates are the source.** A file is printed as its template with
   this host's values in place of the ones it was written with, all in one
   pass:
   - the code directory (`/opt/gpforum`, or `/usr/local/www/gpforum` on
     FreeBSD);
   - the environment file;
   - Homebrew's prefix, for the launchd logs;
   - the host named by `GPFORUM_PUBLIC_BASE_URL`, for `forum.example.com`,
     an accented name in its `xn--` form, which nginx, Caddy and certbot
     take;
   - the first address of `GPFORUM_RUNTIME_LISTEN`, for `127.0.0.1:8080`,
     with the UNIX-socket variants when that address is a socket;
   - `GPFORUM_ATTACHMENT_ROOT`, for the nginx alias.

   On the documented layout the output is the template, byte for byte.
   `GPForum::Service::Operations::ServiceFiles` holds the layout: which
   files, where each goes on each operating system, and the commands that
   put them there.
3. **It prints and installs nothing.** The files go to standard output and
   the steps to standard error, so `gpforum service print nginx | sudo tee
   FILE` writes the file alone. One file ends with that `tee`. Several end
   with `--to DIR`, which writes them into a directory for the operator to
   read. The directory must hold nothing else, so `sudo cp DIR/*` copies
   only them. Since `--to` runs through `sudo` on a deployed host, a
   directory another account can change is refused, and a link under one
   of the files' names too; each file is written beside its name and
   renamed onto it, so nothing is written through a link. The steps then
   copy the files, reload the manager and enable what the files run:
   `systemctl enable --now`, `sysrc` and `service start`, or `launchctl
   bootstrap` for each plist, the jobs included. The print step carries
   `sudo` when the environment file is closed to other accounts, as a
   deployed one is. It also carries `--env-file` when the file is not the
   host's own (ADR 0120).
4. **An environment file that is not the host's own** reaches every
   service. systemd and rc already name it, in `EnvironmentFile=` and
   `gpforum_env_file`. The crontab passes `--env-file`. launchd has no
   environment file, so each plist sources it through `/bin/sh` before it
   starts the program.
5. **Doctor compares the installed files with the printed ones.** A unit
   reads as current when it matches the template written for this host, or
   the template as `deploy/` has it, as an install before this change
   copied it. A unit that differs is held to the deploy contract with
   either environment file, the contract's or the one doctor read, so one
   printed for another file reads as changed, not as lacking it. The fixes are `gpforum service print` commands:
   - a missing file is printed into place and started;
   - several missing files are written to a directory first;
   - a drifted file gets a `print | diff -u INSTALLED -` note, a
     reprint and a restart of only the services whose files changed.

   Under launchd that restart is `bootout` followed by `bootstrap`, since a
   kickstart keeps the plist launchd already loaded. The proxy fix is the
   nginx step for this operating system: `sites-available` on Linux,
   `conf.d` on FreeBSD, Homebrew's `servers/` on macOS.

## Consequences

- Installing the units on Debian, and the macOS LaunchDaemons, is one
  print and the four commands it ends with. The `sed` on nginx's site is
  gone.
- The service account stays `gpforum`. Every template, the contract and the
  guide name it, and doctor could not tell which account a unit was printed
  for.
- `deploy/` stays what CI parses. It gains one file, `deploy/freebsd/gpforum_jobs`.
- An existing install is not flagged. Its copies match the templates as
  shipped, and doctor still accepts them.
- The certificate lines keep certbot's `/etc/letsencrypt/live/` paths. Only
  the Linux steps take a certificate; on FreeBSD and macOS a note says to
  correct the two lines when the certificate is elsewhere.

## Verification

- `t/540-service-files-rendered.t`: the documented layout renders each
  template unchanged, and another one renders with every path replaced. It
  covers the UNIX-socket variant, the FreeBSD crontab, the launchd account,
  logs and environment-file wrapper, and the nginx and Caddy sites. It
  checks the example-address note and the steps for each operating system.
- `t/541-service-print-command.t`: what the operator reads, on standard
  output and standard error. It covers `--to` and its refusals, misuse,
  Italian, `--json`, and the front door from another directory with
  `--env-file`.
- `t/542-doctor-offers-service-print.t`: printed and pre-existing units read
  as current. A missing plist is loaded, a changed one is booted out and
  loaded again, and the proxy step matches each operating system.
- `t/494`, `t/493`, `t/520`, `t/472` and `t/508` follow the new fixes and
  the guide.
- `t/578-service-print-to-a-directory.t`: `--to` refuses a link under a
  file's name and a directory another account can change, and replaces a
  file rather than writing through it.
- `t/579-service-files-review.t`: a unit printed for another environment
  file, then changed, reads as changed; an accented public name is written
  in its `xn--` form; the nginx site does not call the store the default.

## Amendment: iteration 4 (2026-10-10)

Walkthrough 3 (`docs/ops/evidence/2026-10-10-operator-walkthrough-3`,
section 5) ranked what kept Debian at 15 typed commands and macOS without
TLS. Owner decision D9 keeps `script/` for the maintainers.

1. **The units run `bin/gpforum` alone** (friction 11). `ExecStartPre` is
   `gpforum os-preflight --strict --json`, the web service `gpforum start
   --service`, which runs Hypnotoad from `local/bin` in its own place, with
   `local/` on the `PERL5LIB` Hypnotoad's restarts inherit (`--service
   --foreground` under launchd and daemon(8), which supervise the manager
   in the foreground), and the others the verbs: `gpforum outbox`, `gpforum
   scheduled-jobs`, `gpforum partitions`. `bin/gpforum` finds the Perl and
   the dependencies itself, as it does at a terminal. The rc scripts and
   the crontab put `/usr/local/bin`, where FreeBSD's perl is, on the `PATH`
   rc and cron start with, and pass the environment file they read. A
   systemd unit printed for an environment file that is not the host's
   passes it with `--env-file` too, so the front door reads the file the
   unit gives the service. `DeployContract` accepts these and the
   `script/gpforum-carton exec` lines of a unit copied before, which still
   start; doctor reads such a unit as one that differs from the release's.
   Verified by `t/590-units-run-the-front-door.t`.

2. **`--to` the host's own directory puts the files in place** (friction
   1). When the directory is the one this host reads a target's files from
   (`/etc/systemd/system`, `/usr/local/etc/rc.d`, `/Library/LaunchDaemons`,
   nginx's `sites-enabled`, `conf.d` or Homebrew's `servers/`, Caddy's
   directory), `service print` writes each file there under the name it is
   installed with, renamed onto it as before, and leaves the directory's
   other files alone; only a directory under one of its names is refused. A
   link under one of them is replaced, not followed. Any other directory
   still holds only the target's files, for the operator to read before a
   `cp`. This keeps D8: the operator still names the directory and runs
   the command, and the reload and the start stay the operator's. The
   printed steps are that `print --to`, then the reload and the start:
   `daemon-reload && enable --now` on one line under systemd, and one
   `launchctl bootstrap system` naming every plist.
3. **The proxy's site, after what it needs.** The nginx site goes straight
   into `sites-enabled` on Debian, which includes `sites-enabled/*`; the
   default site stays, since it answers only names no other site claims.
   The site names its certificate, and nginx refuses it while that file is
   missing, so `--to` refuses to put it in place before the certificate is
   there and names the command that takes it. The steps begin with the
   packages when `nginx`, `certbot` or `caddy` is not installed (`apt`,
   `pkg`, `brew`), then the certificate when it is not there yet: certbot's
   nginx plugin on Linux, its standalone server on FreeBSD and macOS, with
   hooks that stop and start nginx for it and its renewals. On FreeBSD the
   site names `/usr/local/etc/letsencrypt`, where the port's certbot keeps
   them; nginx under Homebrew runs as root, which reads them.
   Verified by `t/591-service-print-into-place.t`.
