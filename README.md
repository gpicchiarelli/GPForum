<p align="center">
  <img src="assets/img/gpforum-hero.png" alt="A dim room with a lit world map on the wall and server racks beyond a doorway" width="100%">
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/img/gpforum-logo-dark.svg">
    <img src="assets/img/gpforum-logo.svg" alt="GPForum" width="128">
  </picture>
</p>

<p align="center">A discussion forum, written in Perl, kept in PostgreSQL.</p>

<p align="center">
  <a href="https://github.com/gpicchiarelli/GPForum/actions/workflows/ci.yml"><img src="https://github.com/gpicchiarelli/GPForum/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="cpanfile"><img src="https://img.shields.io/badge/Perl-5.40%2B-373630" alt="Perl 5.40 or newer"></a>
  <a href="docs/DEPLOYMENT.md"><img src="https://img.shields.io/badge/PostgreSQL-16%E2%80%9318-373630" alt="PostgreSQL 16–18"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-BSD--3--Clause-9B6D32" alt="BSD-3-Clause license"></a>
</p>

<br>

GPForum renders its pages on the server; read routes also answer in JSON when
asked. PostgreSQL holds the data, and search, feeds and caches are derived from
it. It runs under Hypnotoad behind nginx or Caddy, and needs no Redis,
OpenSearch or Kubernetes.

## What it does

- Threads, replies and revisions. Search, bookmarks, follows and notifications.
- Images, PDFs and text attachments up to 25 MiB, scanned before delivery.
- Moderation queues, suspensions and reversible actions with an audit trail.
- Verified accounts, data export and account deletion.
- English and Italian; light, dark and high-contrast themes.
- An admin console and one command, `gpforum`, to run and maintain the forum.

## Requirements

Perl 5.40 or newer as the operating system ships it: the system Perl at
`/usr/bin/perl` on Debian and Ubuntu, `perl5` on FreeBSD, Homebrew's `perl` on
macOS. Version managers and custom builds are not supported. Install the
packages and Carton for that perl.

PostgreSQL 16, 17 or 18. See [deployment](docs/DEPLOYMENT.md) for production.

<details>
<summary>Install host packages</summary>

Debian 13 or Ubuntu 26.04, which also starts a PostgreSQL server:

```sh
sudo apt install perl build-essential cpanminus libpq-dev libssl-dev postgresql postgresql-client
sudo cpanm -M https://cpan.metacpan.org/ Carton
```

FreeBSD, client only:

```sh
sudo pkg install perl5 p5-App-cpanminus postgresql16-client
sudo cpanm -M https://cpan.metacpan.org/ Carton
```

macOS with Homebrew:

```sh
brew install perl cpanminus postgresql@18
brew services start postgresql@18
export PATH="$(brew --prefix postgresql@18)/bin:$PATH"
"$(brew --prefix)/bin/perl" "$(brew --prefix cpanminus)/bin/cpanm" -M https://cpan.metacpan.org/ Carton
```

</details>

## Quick start

From a clone of the repository:

```sh
make system-perl                                    # check the interpreter
make install-deps-postgres                          # carton install --deployment from cpanfile.snapshot
script/system-preflight                             # check the host
sudo ln -s "$PWD/bin/gpforum" /usr/local/bin/gpforum   # once; macOS: ln -s "$PWD/bin/gpforum" "$(brew --prefix)/bin/"
sudo gpforum setup --environment development        # three questions; macOS: without sudo
gpforum admin create --email you@example.com --username you
gpforum start --foreground                          # then open http://127.0.0.1:3000
```

`bin/gpforum` finds its dependencies from any directory, so the link is all
it needs to be on your `PATH`. `gpforum setup` asks three questions, and
Enter takes each suggestion: the address (`http://127.0.0.1:3000`), the
database (it makes `gpforum` on this host as PostgreSQL's superuser -- the
`postgres` account through `sudo`, or on macOS your own role, which
Homebrew's PostgreSQL trusts) and the mail (`log`: in development each
message goes to the terminal). It writes the settings to
`/etc/gpforum/gpforum.env` (`$(brew --prefix)/etc/gpforum/gpforum.env` on
macOS), yours to read, with a database password and secrets nobody has to
type, and brings the schema up to date. Every `gpforum` command reads that
file; run setup again and it changes nothing. Without a system server, a
cluster in your home directory is enough, as
[docs/ops/staging-drills.md](docs/ops/staging-drills.md) shows: answer its
data source to the database question. For a production host, follow
[Production on Debian or Ubuntu](#production-on-debian-or-ubuntu) instead.

`gpforum admin create` asks for a password and creates an active, verified
owner. Open <http://127.0.0.1:3000> to sign in. Run `gpforum` for help, or
`gpforum migrate --plan` to preview migrations. `gpforum doctor` checks the
whole setup, one line each, and says how to fix what is wrong
([docs/ops/doctor.md](docs/ops/doctor.md)).

A member who registers gets a verification mail. In development GPForum
sends none: the outbox worker writes each message, its link included, to the
terminal. Run it once and open the link it prints:

```sh
bin/gpforum outbox --once
```

To deliver real mail, set `GPFORUM_MAIL_TRANSPORT` to `sendmail` or `smtp`,
as [docs/ops/mail-check.md](docs/ops/mail-check.md) describes.

For development: `make check` runs the quality checks; `make integration`
runs the PostgreSQL tests with `GPFORUM_DATABASE_DSN` set. `make fresh-checkout`
verifies a clean clone. Use `script/coverage`, `script/bench-http` and
`script/profile-route` for measurement, and `make help` for the other tasks.

## Production on Debian or Ubuntu

From a bare Debian 13 or Ubuntu 26.04 host to a signed-in owner behind TLS.
First the packages -- PostgreSQL, nginx with certbot, ClamAV for the upload
scan -- and Carton for the system Perl:

```sh
sudo apt install git perl build-essential cpanminus libpq-dev libssl-dev zlib1g-dev \
  postgresql nginx certbot python3-certbot-nginx clamav-daemon clamav-freshclam
sudo cpanm -M https://cpan.metacpan.org/ Carton
```

Then eight commands, with your forum's name for `forum.example.org`:

```sh
sudo git clone https://github.com/gpicchiarelli/GPForum.git /opt/gpforum
sudo /opt/gpforum/bin/gpforum setup
sudo gpforum service print --to /etc/systemd/system
sudo systemctl daemon-reload && sudo systemctl enable --now gpforum gpforum-outbox gpforum-scheduled-jobs.timer gpforum-partition-maintenance.timer
sudo certbot certonly --nginx -d forum.example.org
sudo gpforum service print nginx --to /etc/nginx/sites-enabled
sudo nginx -t && sudo systemctl reload nginx
sudo -u gpforum gpforum admin create --email EMAIL --username NAME
```

`gpforum setup` installs the dependencies, as `make install-deps-production`
does, links `gpforum` into `/usr/local/bin`, and asks three questions:
Enter takes each suggestion, and the address is the one to type. It makes
the account the services run as, writes `/etc/gpforum/gpforum.env` with new
secrets, makes the database as the `postgres` account, and brings the
schema up to date. Each command ends by saying the next one, so after
setup nothing here needs to be read again. `service print --to` writes
GPForum's own files where systemd and nginx read them and touches nothing
else there; Debian's default site stays. Then sign in at
`https://forum.example.org/login`, and run `sudo -u gpforum gpforum doctor`,
which checks everything from the settings to the public address and says
how to fix what is wrong. Mail leaves through the host's `sendmail` unless
you answered `smtp HOST:PORT USER`; the antivirus needs `StreamMaxLength
26M` in `/etc/clamav/clamd.conf`. [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)
explains each step, FreeBSD and macOS.

## How it is built

- Perl 5.40 or newer, Mojolicious, DBIx::Class; PostgreSQL 16, 17 and 18.
- Threads, replies, reports and moderation actions commit their rows, domain event and audit record in one transaction; an outbox carries the events to workers.
- Search is PostgreSQL full-text search with `pg_trgm`. Pagination uses keysets, not offsets.
- A process-local cache, and optionally GlifiStore as a cache shared between hosts. When GlifiStore is unreachable, pages are served from the local cache and PostgreSQL.
- Argon2id passwords, server sessions, CSRF protection and ClamAV upload scanning.

[ARCHITECTURE.md](ARCHITECTURE.md) describes the design, [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)
the deployment, and [docs/README.md](docs/README.md) indexes the rest.
[Architecture decision records](docs/adr/README.md) explain the design choices
and their consequences. [GOVERNANCE.md](GOVERNANCE.md) describes how they change.

<details>
<summary>Architectural decisions</summary>

- PostgreSQL owns canonical state. Caches and projections are disposable and rebuildable.
- Search uses PostgreSQL; Redis, KeyDB and OpenSearch are not required.
- Persistent Perl processes serve bounded request paths; optimization follows measurement.
- Controllers handle HTTP; services own business rules and persistence workflows.
- Writes commit state, events and audit records together; workers handle retries safely.
- Authorization applies to pages, search, feeds, attachments and realtime updates.
- Pages use semantic HTML, keyboard controls and accessible themes, without dark patterns.
- Tests check these rules. Architectural changes update the relevant ADRs and documentation.
- The contributing guide, security policy, issue templates and changelog are kept with the code.

</details>

## Status

Ready for local and personal use. Public production and private beta still
need evidence from a real staging host for TLS, mail delivery and load.
There is no tagged release or independent security review.
[Readiness criteria](docs/PRODUCTION_READINESS.md) ·
[Current review](docs/release/readiness-review.md)

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and run `make check` before a pull
request. Report vulnerabilities privately through [SECURITY.md](SECURITY.md).

[Roadmap](ROADMAP.md) · [Changelog](CHANGELOG.md) · [Support](SUPPORT.md) ·
[Governance](GOVERNANCE.md) · [Code of conduct](CODE_OF_CONDUCT.md)

The symbol uses two open arcs and one amber node, echoing the hero's warm
network lights. [Editable artwork and variants](assets/source/README.md).

## License

[BSD-3-Clause](LICENSE).
