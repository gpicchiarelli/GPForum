# Evidence: 2026-09-20 macOS laptop prep

**PRIVATE BETA: NOT CLAIMED.**

This directory archives operator prep blobs from a **developer Mac laptop**,
not from a representative staging Hypnotoad+TLS host. It does **not** close
private-beta blockers in
[`docs/release/readiness-review.md`](../../release/readiness-review.md).

Commit baseline at capture time: `main` at/after `#21` / `#22`
(`staging-host-verify` + user-space PostgreSQL docs).

## Environment notes

| Item | State |
| --- | --- |
| OS | macOS (Darwin) |
| System Perl | `/usr/bin/perl` 5.34.1 — **below** GPForum 5.38 gate |
| MacPorts Perl 5.38+ | Not installed (needs `sudo port install perl5.38`) |
| Carton `local/` | Present but XS bundles mismatch system Perl |
| PostgreSQL | MacPorts 18 **client** tools; **user-space** server on `127.0.0.1:55432` (`~/gpforum-pgdata`) — see `docs/ops/staging-drills.md` |
| nginx / systemd | Not on PATH / N/A on macOS laptop |
| Staging TLS URL | None |

## Phase results

| Phase | Result | Artifact |
| --- | --- | --- |
| Private-beta checklist `--status` / `--commands` | print-only OK | `private-beta-checklist-*.txt` |
| `staging-host-verify` (repo artifacts only) | `pass` (live flags skipped) | `staging-host-verify.json` |
| `staging-drill-attachments` | `degraded` (no nginx/systemd host tools; attach phase may be limited under Perl XS mismatch) | `staging-drill-attachments.json` |
| `staging-drill` (DB) | not run | needs Perl 5.38+ + Carton deps rebuilt |
| `staging-host-verify --env-file/--systemd/--base-url` | skipped | no staging host |
| `gpforum-mail-check --dry-run` | fail / skipped | `mail-check-dry.SKIPPED.txt` |
| `stress-load` smoke/100 | not run | no running Hypnotoad |

## Residual gaps (still open for private beta)

- OS system Perl 5.38+ (MacPorts) and fresh `make install-deps-postgres`
- `script/staging-drill --json` against PostgreSQL major matching production
- Live Hypnotoad + TLS bring-up; `staging-host-verify` with `--env-file`,
  `--systemd` (Linux), `--base-url`
- Mail dry-run / controlled `--send` on staging SMTP
- Stress profiles `100` / `500` / `1000` on staging hardware
- Attachment restore + nginx/systemd **install/reload** on a real target

A Cloud Agent VM evidence PR may supersede or extend this laptop prep
archive; keep both labeled distinctly.
