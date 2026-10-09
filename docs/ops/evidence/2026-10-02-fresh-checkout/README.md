# Fresh checkout from the quick start — 2026-10-02

`script/fresh-checkout-check --keep-going` (`make fresh-checkout`) run twice on
the macOS development host, first against commit `c9c00cb` and then, once the
first run's critic fix had been committed, against `9ecca7d`. Both runs had
`GPFORUM_DATABASE_DSN` pointing at a throwaway PostgreSQL cluster on
127.0.0.1, so the quick start's database commands and the integration tier ran
too. Each run cloned the commit into a temporary directory, installed every
dependency there from MetaCPAN, ran the README quick start and each step of
`make check` in order, then removed the clone, the throwaway role and the
throwaway database (checked afterwards: none left on the server).

| | `c9c00cb` | `9ecca7d` |
| --- | --- | --- |
| Host | macOS, Apple silicon; Homebrew perl 5.44.0 | same |
| PostgreSQL | 18.6 (Homebrew `postgresql@18`) | same |
| Result | `status=fail`: 12 of 14 steps passed; `migrate-apply` and `critic` failed | `status=fail`: 11 of 14 steps passed; `migrate-apply`, `critic` and `tidy` failed |
| Wall time | 960 s: dependency install 151 s, syntax 83 s, test 79 s, critic 101 s, tidy 498 s, integration 41 s | 988 s: dependency install 156 s, syntax 79 s, test 86 s, critic 105 s, tidy 512 s, integration 44 s |
| Unit tier (`make test`) | 242 files, 10,709 tests, pass | 250 files, 11,256 tests, pass |
| Integration tier | 31 files, 951 tests, pass | 34 files, 1,111 tests, pass |
| Log | [`fresh-checkout-c9c00cb.log`](fresh-checkout-c9c00cb.log) | [`fresh-checkout-9ecca7d.log`](fresh-checkout-9ecca7d.log) |

In both logs the temporary directory's path is replaced by `$TMPDIR/...`, or
left out where the script already prints none.

## What the runs found

**`make check` is red in a clean clone of either commit, each time on a file
that was fixed in the working tree but not committed.** At `c9c00cb`,
`critic` failed on a severity-5 `return sort`
(`Subroutines::ProhibitReturnSort`) in
`t/integration/postgres-search-results.t`; `9ecca7d` has that fix. At
`9ecca7d`, `critic` (`CodeLayout::RequireTidyCode`) and `tidy` both fail on
`t/82-realtime-supervisor.t`, committed untidy in `bea6d02`; the working tree's
copy is tidy. A gate run in the working tree passes on both, which is the gap
this check exists to show.

**The quick start's database commands do not work as written.**
`createuser gpforum` makes a plain role, and `bin/gpforum-migrate --apply` run
as that role dies on its first statement:

```text
ERROR:  permission denied to set parameter "lc_messages"
```

`GPForum::Config` puts `SET lc_messages = 'C'` in every connection's
`on_connect_do`, and `lc_messages` is a setting only a superuser, or a role
granted `SET` on it, may change. The integration tier passed because it
connects as the DSN's role, which on this cluster is a superuser; the
application as the README sets it up, and any production role without
superuser, cannot connect at all. `--plan` passed because it lists the
migration files without connecting. With that one `SET` taken out of a scratch
copy of `GPForum::Config` (the repository's copy unchanged), all 48 migrations
applied as a plain role that owns its database, so it is the only thing in the
way.

## What this proves

That a clean clone of either commit, with nothing from this checkout's
`local/`, shell or uncommitted files, installs from the lock and passes
`syntax`, `test` and `architecture` with the README's commands alone, and that
the integration tier passes from it.

## What it does not

A green `make check`: that needs the `t/82-realtime-supervisor.t` tidy fix
committed and a rerun. The quick start's database section, until
`GPForum::Config` stops setting `lc_messages`. The database section on
Debian/Ubuntu or FreeBSD, where the server, its superuser and its
authentication differ from macOS; nor `createuser` and `createdb` against the
default server on port 5432 (the run makes a throwaway role and database on
the server the DSN names instead, and gives the role a generated password,
since `createuser` asks for one only on a terminal).
