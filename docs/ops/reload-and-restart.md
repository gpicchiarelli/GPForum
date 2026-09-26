# Reload and Restart

**`systemctl reload gpforum` is not supported, and that is deliberate.** It
used to be, and it killed the service.

## What went wrong

`ExecReload=` was byte-identical to `ExecStart=`. Running `hypnotoad` against a
live instance is its hot-deploy path: the new manager starts, sends `QUIT` to
the old one and takes over. Under `Type=forking` with `PIDFile=`, systemd read
the pid file once at start and went on tracking the original manager, so a
reload handed the service to a process systemd no longer supervised. The unit
was then either restarted or marked failed, depending on `Restart=`.

`ExecReload=/bin/kill -USR2 $MAINPID` does not fix it. `USR2` **is** the hot
deploy — see `perldoc Mojo::Server::Hypnotoad` — so the manager moves either
way. Hypnotoad has no reload-in-place signal:

| Signal | Effect |
| --- | --- |
| `INT`, `TERM` | Stop immediately |
| `QUIT` | Stop gracefully |
| `TTIN` / `TTOU` | Grow / shrink the worker pool by one |
| `USR2` | Hot deploy: replace the manager |

There is nothing honest to put in `ExecReload=`, so the directive is gone.
`systemctl reload` now fails with "operation not supported" instead of stopping
the forum.

## What to do instead

Pick up new code or new configuration with a restart:

```sh
sudo systemctl restart gpforum
```

Workers finish in-flight requests during the graceful stop, so this is a short
interruption rather than a dropped connection, but it *is* an interruption.
Schedule it like any other deploy step.

To change the worker pool without a restart, signal the manager directly. This
does not move the pid, so systemd keeps supervising the same process:

```sh
sudo kill -TTIN "$(cat /opt/gpforum/hypnotoad.pid)"   # one more worker
sudo kill -TTOU "$(cat /opt/gpforum/hypnotoad.pid)"   # one fewer
```

## Zero-downtime deploys

Hypnotoad's hot deploy works; what does not work is systemd tracking it. If you
need zero-downtime upgrades, run hypnotoad in the foreground under
`Type=notify` with `HYPNOTOAD_FOREGROUND=1` so systemd supervises the manager
directly, and drive the upgrade from outside the unit. That restructuring is
not shipped here: it is the same change `docs/QUALITY_PROGRAM.md` 3.1 leaves
open, and it cannot be exercised on a development host without systemd.

## Related

- `deploy/systemd/gpforum.service` — the unit, with the reasoning inline
- `docs/ops/partition-maintenance.md` — another operation that needs a window
