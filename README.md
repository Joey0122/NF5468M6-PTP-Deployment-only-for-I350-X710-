# Unified PTP + NTP deployment for Inspur NF5468M6

```text
Status: Pre-deployment software implementation complete.
Hardware: Real NF5468M6 / I350 / X710 hardware validation pending.
Target: Native Linux on Inspur NF5468M6
Supported NICs: Intel I350 (igb) and Intel X710 (i40e)
```

`ptpctl` is an interactive PTP + NTP discovery, validation, and runtime
controller. The normal deployment path is:

```bash
cd server_ptp
sudo ./ptpctl
```

The wizard discovers the Linux interface, driver, PCI function, hardware
timestamp capabilities, and interface-mapped `/dev/ptpX` live. It asks only for
site facts it cannot discover: PTP network/profile choices, whether a PTP slave
may change the Linux system clock, and optional NTP server hostnames or IPs.

No public NTP server is invented. `/etc/chrony.conf` is never overwritten. The
existing I350/X710 discovery, four PTP modes, hardware validation, transactional
rollback, and engineering commands remain supported:

```text
I350-master
I350-slave
X710-master
X710-slave
```

Real NF5468M6, I350, X710, Grandmaster interoperability, and timing-accuracy
validation still need to be completed on the target hardware. This
pre-deployment release is not production-ready or hardware-validated.

## One system-clock owner

The global safety invariant is:

> At most one active component may discipline `CLOCK_REALTIME`.

An explicit policy matrix in `lib/clock_policy.sh` derives the owner before any
runtime process starts. The runtime then consumes that policy; it does not make
independent clock-direction decisions.

| PTP role | PTP changes system? | NTP | `CLOCK_REALTIME` owner | NIC PHC owner | NTP mode |
|---|---:|---:|---|---|---|
| Slave | Yes | Off | PTP / `phc2sys` | PTP / `ptp4l` | Disabled |
| Slave | Yes | On | PTP / `phc2sys` | PTP / `ptp4l` | Monitor-only `chronyd -x` |
| Slave | No | Off | Unchanged | PTP / `ptp4l` | Disabled |
| Slave | No | On | NTP / private `chronyd` | PTP / `ptp4l` | Discipline |
| Master | n/a | On | NTP / private `chronyd` | system / `phc2sys` | Discipline |
| Master | n/a | Off | Existing synchronized source or lab free-run | system / `phc2sys` | Disabled |

The policy assertion rejects any derived combination in which discipline-mode
`chronyd` and a system-targeting `phc2sys` could both run. Master `phc2sys` uses
an explicit `CLOCK_REALTIME -> selected NIC PHC` direction, so it cannot choose
the Linux system clock as a target.

## Wizard flow

An abbreviated first run is:

```text
NF5468M6 Time Synchronization Setup

Detected Intel I350/X710 ports:
  ...

Supported PTP modes:

[1] I350 Master
[2] I350 Slave
[3] X710 Master
[4] X710 Slave

Selection: 4
```

For a slave:

```text
Should PTP modify the Linux system clock?

[1] Yes — synchronize CLOCK_REALTIME from PTP
[2] No  — synchronize only the NIC PHC
```

For all roles:

```text
Configure NTP connection?

[1] No NTP
[2] Yes — NTP client

NTP server hostname/IP: 192.168.1.230
```

Multiple servers can be separated with spaces or commas. The wizard then asks
for the existing PTP site parameters: domain, transport, delay mechanism,
profile, `transportSpecific`, and slave Grandmaster discovery. A master also
requires a confirmed current TAI-minus-UTC offset and its authority.

Before startup, it displays the detected NIC/interface/driver/PHC, both
protocol choices, the derived clock owners, the architecture label, and any
service conflict requiring a temporary stop. Nothing starts until the operator
confirms.

Existing saved answers appear as defaults. Live hardware values never do.

## Slave behavior

### PTP changes the Linux system clock

```text
External PTP Grandmaster
  -> ptp4l
  -> selected NIC PHC
  -> phc2sys
  -> CLOCK_REALTIME
```

`ptp4l` must first reach `SLAVE`. Before `phc2sys` is allowed to start, `pmc`
must report:

- `ptpTimescale=1`
- numeric `currentUtcOffset`
- `currentUtcOffsetValid=1`

If NTP is enabled, the private NTP process runs with `chronyd -x`. It selects
and measures NTP sources but cannot adjust the system clock. Status still shows
reachability, reference ID, stratum, offset, and frequency estimate.

### PTP changes only the NIC PHC

```text
PTP Grandmaster -> ptp4l -> selected NIC PHC
```

No system-targeting `phc2sys` is started. PTP remains a hardware-timestamped
slave and exposes its state, offset, and path delay. `CLOCK_REALTIME` remains
independent.

With NTP enabled, the supported architecture is:

```text
PTP Grandmaster -> selected NIC PHC
NTP server      -> private chronyd -> CLOCK_REALTIME
```

This makes NTP the only Linux system-clock discipliner while PTP remains useful
for PHC synchronization, measurement, and experiments.

## Master behavior

With NTP enabled:

```text
External NTP server
  -> private chronyd
  -> CLOCK_REALTIME
  -> phc2sys
  -> selected NIC PHC
  -> ptp4l MASTER
  -> downstream PTP clients
```

Startup order is enforced:

1. Validate NTP names and the generated chrony configuration.
2. Probe the configured servers without setting the clock.
3. Start private discipline-mode `chronyd`.
4. Require a selected usable source and normal leap status.
5. Pre-align the selected NIC PHC from `CLOCK_REALTIME` and verify samples.
6. Start `ptp4l`, require `MASTER`, and verify the advertised UTC offset.

`ptp4l` therefore does not start before the configured upstream NTP condition
is satisfied. The bundled master dataset remains deliberately conservative and
non-traceable (`clockClass 248`) until a site supplies reviewed profile data.

With NTP disabled, the existing synchronized-system and explicit laboratory
free-running master policies remain available. A lab master is prominently
reported as not traceable.

## Private chrony runtime

When NTP is selected, `ptpctl` creates its own client-only configuration and
never includes the system chrony file:

```text
run/chrony.conf
run/chronyd.pid
logs/chronyd-<mode>-<timestamp>.log
logs/ntp-status-<mode>-<timestamp>.log
```

The configuration contains only the operator-provided `server ... iburst`
lines, a private PID path, loopback-only monitoring on private command port
32322, `port 0` (no NTP server),
and `makestep` only in discipline mode. `chronyd -d` keeps the process under
transactional PID ownership and sends diagnostics to the project log.
Monitor-only adds `-x`, which is also recorded in the dry-run plan and tested.

Configuration syntax is checked with `chronyd -p`. Reachability is checked with
a non-setting `chronyd -Q` probe before the owned daemon starts. Runtime
readiness then requires a selected source and `Leap status: Normal` through the
private monitoring endpoint.

`ptpctl stop` signals only the exact chronyd PID stored in its runtime state. It
does not use a broad `pkill` and does not touch `/etc/chrony.conf`.

## Existing clock services

Every setup inspects:

- `chronyd.service` / `chrony.service`
- `systemd-timesyncd.service`
- `ntp.service`, `ntpd.service`, `ntpsec.service`, and `openntpd.service`
- running `chronyd`, NTP, `ptp4l`, and `phc2sys` processes

When the selected architecture needs exclusive control, an active system time
service is reported before launch. The interactive path offers a temporary
stop and requires confirmation. The service is never disabled. Its previous
active state is written to the transaction state and restored by rollback or
`ptpctl stop`.

An unmanaged daemon is rejected instead of killed. An advanced non-interactive
setup also rejects a service conflict and directs the operator to the wizard.
In PHC-only/NTP-off operation, one existing system time owner may remain
unchanged; multiple independent owners are rejected.

## Status

```bash
./ptpctl status
```

The combined report has three sections:

```text
PTP

Role:               SLAVE
NIC:                X710 / enp65s0f0
PHC:                /dev/ptp2
State:              SLAVE
Master offset:      ...
Path delay:         ...

NTP

Mode:               DISCIPLINE
Server(s):          192.168.1.230
Reachability:       OK
Stratum:            1
Offset:             ...
Reference ID:       ...
Frequency estimate: ...

Clock Control

CLOCK_REALTIME:     NTP / chronyd
NIC PHC:            PTP / ptp4l
Conflict:           NONE
```

When PTP owns the system clock, it shows `PTP / phc2sys` and `NTP: MONITOR
ONLY`. The read-only ptp4l management socket and chronyd loopback monitoring
interface allow status queries without granting control commands.

## Persistence

The wizard atomically maintains ignored `configs/site.env`. New site-owned
values are:

```text
NTP_ENABLED=YES|NO
NTP_SERVERS=host1.example 192.0.2.20
PTP_SLAVE_SYSTEM_CLOCK=YES|NO
```

The public `configs/site.env.example` contains no public NTP default. Existing
older PTP-only site files remain compatible: they default to NTP off and the
former slave behavior (`PTP_SLAVE_SYSTEM_CLOCK=YES`) until the wizard rewrites
them.

The file never persists interface name, driver, PCI function, MAC address, PHC
number, or `/dev/ptpX`. Those are discovered and validated again on every run.

## Rollback and logs

Setup holds a transaction lock, records the pre-launch service/process/clock
state, and tracks every PID it starts. NTP probe failure, NTP readiness failure,
PTP state failure, UTC validation failure, PHC alignment failure, interruption,
or state-commit failure triggers rollback.

Rollback stops only transaction-owned `phc2sys`, `ptp4l`, and private `chronyd`
PIDs, restores temporarily stopped services, removes transient configs/sockets,
and preserves diagnostics:

```text
logs/
  setup-...
  ptp4l-...
  phc2sys-...
  chronyd-...
  ntp-status-...
  pmc-...
  pre-state-...
```

It does not change NIC drivers, firmware, addresses, routes, VLANs, boot
settings, or service enablement.

## Requirements

Base requirements are Bash, `pciutils`, `iproute2`, `ethtool`, `linuxptp`
(`ptp4l`, `phc2sys`, `pmc`), `util-linux`, `procps`, and systemd tools. Selecting
NTP additionally requires the `chrony` package (`chronyd` and `chronyc`) and
`getent`.

The wizard never installs packages. A missing dependency gives an install hint.

`doctor` also reports whether the installed linuxptp provides `timemaster`.
LinuxPTP includes timemaster for coordinated PTP/NTP operation, but this change
does not replace the proven explicit runtime engine with it; the single-owner
policy and existing semantics remain directly visible and testable.

## Advanced commands

The interactive wizard remains primary. Existing commands continue to work:

```bash
./ptpctl probe
./ptpctl doctor
./ptpctl status
sudo ./ptpctl stop

./ptpctl setup I350-master --dry-run
./ptpctl setup I350-slave --dry-run
./ptpctl setup X710-master --dry-run
./ptpctl setup X710-slave --dry-run
```

Optional non-interactive overrides are available without persisting hardware:

```bash
sudo ./ptpctl setup X710-slave \
  --ptp-system-clock=no \
  --ntp-server=192.168.1.230

sudo ./ptpctl setup I350-master \
  --ntp-server=ntp1.example \
  --ntp-server=ntp2.example
```

Use `--ntp=off` to override a saved NTP choice for one setup. Dry-run performs
discovery, validation, policy derivation, and config/command rendering without
starting a process, stopping a service, changing a clock, or committing state.

## Tests

```bash
./tests/run.sh
```

The mocked suite starts no production time service and never modifies a real
clock. It covers all I350/X710 slave ownership combinations, both master
families with NTP and lab free-run, conflict rejection, monitor-only `-x`, PHC
only behavior, NTP/PTP startup ordering and failure gates, service restoration,
rollback, cancellation, saved defaults, multiple and invalid NTP servers,
status, logs, dry-run, hardware failures, dependency guidance, and timemaster
detection.
