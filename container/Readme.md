# runit in a container

`etc/runit/1`, `2` and `3` are a complete runit lifecycle for a container
running as UID 0 or as a regular user, with `runsvdir.sh` as stage 2 —
the same script a regular user runs on a host. There is a `Containerfile`
for each: `Containerfile` runs as root, `Containerfile.unprivileged`
never does. See [As a regular user](#as-a-regular-user).

## Try it

From the repository root:

    podman build -f container/Containerfile -t sv-helper-demo .
    podman run -d --cap-add SYS_BOOT --name demo sv-helper-demo

    podman exec demo svls              # the hello service, supervised
    podman exec demo sv-enable crasher # a service that keeps crashing
    podman exec demo tail /var/log/hello/current

    podman stop demo                   # exits through stage 3, in a second or two

`docker` works identically. `test/container.bats` runs exactly this and
checks each step.

## Why `--cap-add SYS_BOOT`

When stage 3 finishes, runit halts the machine — in a container, that is
a `reboot(2)` call, which ends the PID namespace and so ends the
container. `reboot(2)` needs `CAP_SYS_BOOT`, which neither Docker nor
Podman grants by default.

The same holds for a container running as a regular user. For a
nonzero UID, podman puts a capability added with `--cap-add` in the
ambient set, so runit holds it without any setuid helper or file
capability, even under `--security-opt no-new-privileges`. Not every
runtime does that. To check yours, look at `CapAmb` in
`/proc/1/status` inside the container.

Without it, everything still works: the stop signal is handled, services
are stopped, logs are flushed, and stage 3 runs to completion. Only the
very last step fails, runit sits there, and the runtime kills the
container when its stop timeout expires — about 10 seconds of delay on
every stop, and an exit status that says "killed" rather than "stopped".

In Kubernetes:

    securityContext:
      capabilities:
        add: ["SYS_BOOT"]

## How stopping works

runit as PID 1 accepts exactly two signals, and only during stage 2:

- `INT` — a ctrl-alt-del request. runit runs `/etc/runit/ctrlaltdel` and
  then signals itself `CONT`.
- `CONT` — shut down, but only if `/etc/runit/stopit` exists and is
  executable.

`SIGTERM`, which every container runtime sends by default, is ignored
entirely. That is why the Containerfile sets `STOPSIGNAL SIGINT`: the
shipped `ctrlaltdel` arms `stopit` and lets runit's own `CONT` carry on
from there. Stage 1 creates `stopit` and `reboot` unarmed (mode 0), so a
stray signal cannot stop the container and `ctrlaltdel` only has to
`chmod` one file.

Then:

1. runit terminates stage 2. `runsvdir` exits immediately on `TERM` and
   leaves its `runsv` children running, now reparented to runit.
2. Stage 3 stops them, in two passes. `sv force-stop` takes each service
   down, killing anything that will not go. `sv shutdown` then makes each
   `runsv` exit, which closes its log service's stdin and waits for the
   logger to drain and terminate — without that second pass, the last
   lines a service wrote are lost.
3. Both passes are bounded by `SV_STOP_TIMEOUT`, 25 seconds by default,
   chosen to finish inside a runtime's usual 30 second stop timeout.

## Installing the stages

Deliberately separate from installing the commands, because dropping
files into `/etc/runit` changes how the machine boots:

    ./install.sh install            # the commands
    ./install.sh install-stages     # stages 1, 2, 3 and ctrlaltdel

It also links `/etc/runit/stopit` and `/etc/runit/reboot` to
`/run/runit/stopit` and `/run/runit/reboot`, the same layout Void uses.
runit reads both and chmods `stopit` itself, so they have to belong to
whoever runit runs as, and `/etc/runit` does not have to be writable.

`--runit-dir` moves them if your runit package uses another path, and
`--destdir` stages them for a package build. `install.sh` refuses to
overwrite a stage file it did not write, so it will not quietly replace
a distribution's own.

Stage 2 is a thin wrapper that finds and execs `runsvdir.sh`, so it holds
no policy of its own; a symlink from `/etc/runit/2` to an installed
`runsvdir.sh` works just as well.

## Services

Service definitions go in `/etc/sv`, and enabling one is a symlink into
the supervised tree — exactly as on a host:

    COPY container/sv /etc/sv
    RUN mkdir -p /etc/service \
        && ln -s /etc/sv/myservice /etc/service/myservice \
        && ln -s /usr/local/bin/rsvlog /etc/sv/myservice/log/run

    ENV SVDIR=/etc/service

`SVDIR` is honoured as given. `/service` is still pointed at the tree for
anything that looks there by default, but it never replaces the tree you
asked for.

## As a regular user

    podman build -f container/Containerfile.unprivileged -t sv-helper-user .
    podman run -d --cap-add SYS_BOOT --name user-demo sv-helper-user

    podman exec user-demo svls
    podman exec user-demo sv-enable crasher
    podman exec user-demo tail ~/.local/state/sv-helper/log/hello/current

    podman stop user-demo

Nothing in this container runs as root, and nothing in it can become
root. runit is PID 1 as UID 1000, and the stages, `runsvdir`, every
`runsv` and every service run as that user too. The paths are the ones
that user would get on a host, under `HOME=/home/sv`:

| What | Where |
| --- | --- |
| service definitions | `~/.config/sv-helper/sv` |
| the supervised tree (`SVDIR`) | `~/.local/state/sv-helper/service` |
| logs, through `rsvlog` | `~/.local/state/sv-helper/log` |
| runit's `stopit` and `reboot` | `/run/runit` |

An explicit `SVDIR` still wins, as it does everywhere else.

The image prepares everything that user has to write, because stage 1
cannot create anything outside the user's home without privilege it
should not have:

- `/run/runit` exists and belongs to the user.
- `install-stages` links runit's control files there (see
  [Installing the stages](#installing-the-stages)).
- `HOME` is set in the image, not left to the runtime.

If any of that is missing, stage 1 says what and exits 100. The
container then goes straight to stage 3 and exits, rather than booting
into something that could not be stopped.

**Any UID.** Everything the user owns also belongs to group 0 and is
group-writable. A UID the image has never heard of can therefore run it
unchanged, as long as its group is 0 — the convention OpenShift assigns
arbitrary UIDs under:

    podman run -d --cap-add SYS_BOOT --user 54321:0 sv-helper-user

A UID outside group 0 cannot write that state, and stage 1 refuses to
boot. `test/container_unprivileged.bats` covers all three cases. To use
a different fixed UID, rebuild with `--build-arg SV_UID=...`.

**Your own image.** Start from `Containerfile.unprivileged` and keep the
parts listed above. Put service definitions in
`~/.config/sv-helper/sv` and enable them by linking them into
`~/.local/state/sv-helper/service`, or run `sv-enable` as the user.

## When things go wrong

**Stage 1 fails.** Exiting 100 tells runit to skip stage 2 and go
straight to stage 3, so a container whose preparation failed shuts down
instead of supervising services on a broken base. Anything else stage 1
reports is a warning and the boot continues.

**A service crashes.** `runsv` restarts it, forever, roughly once a
second. That is supervision working, and the container stays up — a
crash loop shows as a service whose pid keeps changing and whose uptime
never grows. `podman logs` shows each start; the service's own log keeps
whatever it wrote. Nothing escalates to the container exiting, so a
service that can never start is something to watch the logs for rather
than something you will notice from the outside.

**A service will not stop.** `sv force-stop` kills it after
`SV_STOP_TIMEOUT`, and shutdown continues. Raise that if a service needs
longer to flush, and raise the runtime's stop timeout to match.

**Zombies.** runit is PID 1 and reaps what it is handed, including the
children an orphaned crash loop leaves behind.
