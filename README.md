Helpers for administering [runit](https://smarden.org/runit/) services —
as root on a runit system, as a regular user on macOS or Linux, or as
PID 1 in a container.

[full documentation](https://github.com/rubyists/sv-helper/wiki)

## Install

Homebrew, on macOS or Linux:

    brew install rubyists/tap/sv-helper

From a release archive, with no package manager at all:

    curl -fsSLO https://github.com/rubyists/sv-helper/releases/latest/download/sv-helper-linux.tar.gz
    tar -xzf sv-helper-linux.tar.gz
    cd sv-helper-*/
    ./install.sh

Replace `linux` with `darwin` on macOS. Each release also publishes
`rsvlog`, `sv-helper.sh` and `runsvdir.sh` on their own, a `SHA256SUMS`
covering everything, and a signed [packslip](https://packslip.dev)
bundle. To check what you downloaded:

    sha256sum -c SHA256SUMS --ignore-missing

    packslip verify packslip.sigstore.json \
      --identity-prefix 'https://github.com/rubyists/sv-helper/.github/workflows/main.yaml@' \
      --issuer https://token.actions.githubusercontent.com \
      --artifact sv-helper-linux.tar.gz

See [docs/releasing.md](docs/releasing.md) for how releases are built
and verified.

From a checkout, or from that unpacked archive:

    ./install.sh                    # ~/.local by default, /usr/local as root
    ./install.sh --prefix /opt/sv
    ./install.sh uninstall

It installs `sv-helper`, `rsvlog` and `runsvdir.sh`, plus the command
links below. Running it again over an identical tree is fine; a file it
did not write is reported rather than replaced, and `uninstall` takes
back only its own and leaves everything else alone.

`PREFIX` is where the files will live when they run. `DESTDIR` is a
staging root used only at install time, for package builds:

    ./install.sh --destdir "$pkgdir" --prefix /usr

`make install` and `make uninstall` drive the same installer, so there is
only one definition of what "installed" means.

## Commands

    sv-enable <service>    Enable a service, so the supervisor starts it
    sv-disable <service>   Disable it again
    svls [<service>]       Status of one service, or of all of them
    sv-find <service>      Where a service's definition is
    sv-list                Every service definition available
    sv-start <service>     Start a stopped service
    sv-stop <service>      Stop a running one
    sv-restart <service>   Restart it
    sv-helper paths        Every path this invocation would use
    sv-helper version      sv-helper's version

All of them are the same script, `sv-helper.sh`, dispatching on the name
it was called by. `sv-helper paths` is the one to reach for when a
service turns up somewhere unexpected.

As a regular user they manage your own services. Root's services are
root's: runsv lets only the account that runs it ask about a service, so
pointing `SVDIR` at a system tree gets you an explanation and the
command to run instead, never a silent `sudo`:

    $ SVDIR=/var/service svls
    Listing All Services
    Cannot ask runsv about 40 service(s) in /var/service as tj: they belong to root.
    Run it as root instead: sudo env SVDIR=/var/service svls

Every command, `rsvlog` and `runsvdir.sh` included, also takes
`--version`:

<!-- x-release-please-start-version -->

    $ svls --version
    svls (sv-helper) 4.2.0

<!-- x-release-please-end -->

## Where things go

The invoking user decides the scope. A regular user never gets
system-wide state, however writable `/var/service` happens to be, and
nothing here ever escalates privilege: if a directory is not yours, it
says so rather than reaching for `sudo`.

|  | definitions | enabled tree | logs |
| --- | --- | --- | --- |
| Linux, root | `/etc/sv` | `/var/service`, `/service` or `/etc/service` | `/var/log` |
| Linux, user | `${XDG_CONFIG_HOME:-~/.config}/sv-helper/sv` | `${XDG_STATE_HOME:-~/.local/state}/sv-helper/service` | `${XDG_STATE_HOME:-~/.local/state}/sv-helper/log` |
| macOS | `$(brew --prefix)/etc/sv` | `$(brew --prefix)/var/service` | `$(brew --prefix)/var/log` |

Paths are resolved from the environment and the invoking UID, never from
where the scripts happen to be installed, so a copy in a checkout and a
copy in `/usr/bin` behave identically.

Any of it can be overridden, and an override is never second-guessed:

    SVDIR           the enabled tree to supervise and act on
    SV_SOURCE_DIR   where to look for service definitions
    SV_LOG_BASE     where per-service logs go
    SV_ROOT         for runsvdir.sh: pick $SV_ROOT/service/<tree> by hostname

### macOS

macOS runs on Homebrew's runit (`brew install runit`), which is what
decides these paths: its formula patches `sv` to default to
`$(brew --prefix)/var/service` and ships the `brew services` definition
that supervises it. To keep a tree running across logins:

    brew services start runit

That logs the supervisor itself to `$(brew --prefix)/var/log/runit.log`.
Its launch agent runs with a minimal `PATH` that does not include
Homebrew's `bin`, so the helpers find runit's tools themselves rather
than requiring an interactive shell environment.

## Running your own supervision tree

`runsvdir.sh` starts one, and creates the directories it needs if they
are not there yet:

    runsvdir.sh

An explicit `SVDIR` is always what gets supervised. With `SV_ROOT` set
instead, it picks `$SV_ROOT/service/<tree>` by hostname: `$HOSTNAME`,
then the hostname with one trailing `-component` removed, then two, each
optionally prefixed with `$SV_PREFIX`, falling back to `generic`.

## Logging: rsvlog.sh

`rsvlog` is a generic `run` script for a service's `log` directory:

    mkdir -p ~/.config/sv-helper/sv/myservice/log
    ln -s /usr/bin/rsvlog ~/.config/sv-helper/sv/myservice/log/run

Logs then land in the log base above, under the service's own name, with
`./main` and `./current` linked where everything expects them.

A `conf` file beside it changes that:

    SV_LOG_SYSLOG=true            log to syslog instead, through logger
    SV_LOG_SYSLOG_PRIORITY=...    facility.level, default daemon.info
    SV_LOGDIR=subdir              under the log base, or an absolute path
    CURRENT_LOG_FILE=name.log     a second name for the live log
    USERGROUP=user:group          run the logger as this account

For example, logging to syslog:

    SV_LOG_SYSLOG=true
    SV_LOG_SYSLOG_PRIORITY=local7.info

or to a named subdirectory of the log base:

    SV_LOGDIR=myservice/service_logs
    CURRENT_LOG_FILE=myservice.log

`USERGROUP` only applies as root; a regular user's logs are written as
that user. Its old default of `rsvlog:adm` is still used when that
account exists, and quietly skipped when it does not — plenty of hosts
and almost every container have no such user, and a log service that
crash-loops on `chown` logs nothing at all. An account you name
explicitly is a different matter: if it does not exist, that is an error
rather than a silent downgrade to root.

An existing `./main` directory is always kept as-is, so an established
log layout is never moved out from under the logs already in it.

## Containers

`etc/runit/{1,2,3}` are a complete runit lifecycle for a container,
running as root or as a regular user, with `runsvdir.sh` as stage 2 —
the same script a regular user runs on a host. Installing them is a separate, explicit
step, because dropping files into `/etc/runit` changes how the machine
boots:

    ./install.sh install-stages

See [container/Readme.md](container/Readme.md) for working
`Containerfile`s for both, how stopping works, and what to expect when a
service fails.

## Development

    git submodule update --init --recursive
    make test

Tests run under [bats](https://github.com/bats-core/bats-core); see
[test/README.md](test/README.md).
