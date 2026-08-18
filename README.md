# `ptpctl` for Inspur NF5468M6

```text
Status: Pre-deployment / awaiting NF5468M6 hardware validation
Version: v0.9.0
Target: Native Linux on Inspur NF5468M6
Supported NICs: Intel I350 and Intel X710 only
```

`ptpctl` is a native-Linux interactive discovery, validation, configuration,
and runtime controller for Intel I350 and X710 PTP ports. The normal deployment
experience is one command:

```bash
cd server_ptp
sudo ./ptpctl
```

The wizard discovers the server-specific Linux and NIC values itself. It asks
only for PTP profile/network facts that must come from the experiment or network
owner, writes `configs/site.env`, shows the complete setup summary, and starts
the existing transactional master or slave workflow after confirmation.

No interface name, PCI address, or `/dev/ptpX` value is hard-coded or copied
from a saved inventory. Hardware is scanned and validated again on every setup.
Real NF5468M6, I350, X710, Grandmaster interoperability, and timing-accuracy
testing are still pending; this release is not hardware-validated or described
as production-ready.

Only these four runtime modes are supported:

```text
I350-master
I350-slave
X710-master
X710-slave
```

## Requirements

The initial target is native Debian/Ubuntu-style Linux with systemd. Required
programs are:

- Bash 4.3 or newer
- `pciutils` (`lspci`)
- `iproute2` (`ip`)
- `ethtool`
- `linuxptp` (`ptp4l`, `phc2sys`, and `pmc`)
- `util-linux` (`flock` and `setsid`)
- `procps` (`pgrep`)
- systemd tools (`systemctl` and `timedatectl`)

The wizard never installs packages silently. A missing program produces a
specific diagnostic and Debian/Ubuntu-style suggestion, for example:

```text
Missing dependency: ethtool
Suggested command:
  sudo apt install ethtool
```

Intel I350 normally uses `igb`; Intel X710 normally uses `i40e`. The live PCI
model, active driver, and timestamp capabilities are verified instead of merely
trusting those expectations.

## First-run wizard

The wizard presents only the supported modes:

```text
[1] I350 Master
[2] I350 Slave
[3] X710 Master
[4] X710 Slave
```

If exactly one hardware-valid port in the selected family exists, it is chosen
automatically. If several physical ports exist, the user selects a simple
numbered entry:

```text
Found 2 X710 ports:
[1] enp65s0f0     PCI 0000:41:00.0   Link UP    PHC /dev/ptp2
[2] enp65s0f1     PCI 0000:41:00.1   Link DOWN  PHC /dev/ptp2
Select port [1]:
```

The PCI function identifies that menu choice only. Before launch, the setup
engine scans live hardware again and re-derives the interface, timestamp
capabilities, and PHC. A disappeared, changed, invalid, or down port is rejected.

An abbreviated first run looks like this:

```text
$ sudo ./ptpctl
PTP Interactive Setup Wizard

[OK] Live hardware inventory: .../state/server_inventory.txt

Supported PTP modes:
[1] I350 Master
[2] I350 Slave
[3] X710 Master
[4] X710 Slave
Selection: 4

Existing site configuration found: .../configs/site.env
PTP Domain [0]:

PTP transport:
[1] L2
[2] UDPv4
[3] UDPv6
Selection [1]:

Delay mechanism:
[1] E2E
[2] P2P
[3] Auto
Selection [1]:

PTP profile:
[1] IEEE 1588 default profile
[2] Other site-specific profile (reviewed extra config required)
Selection [1]:

transportSpecific [0]:

Grandmaster discovery mode:
[1] Multicast discovery
[2] Configured unicast (reviewed extra config required)
Selection [1]:

PTP Setup Summary
Mode:             X710-slave
NIC:              Intel X710
Interface:        enp65s0f0
PCI:              0000:41:00.0
Driver:           i40e
Firmware:         ...
Link:             UP
HW TX timestamp:  YES
HW RX timestamp:  YES
PHC:              /dev/ptp2
PHC shared:       YES (enp65s0f0, enp65s0f1)
PTP domain:       0
Transport:        L2
Delay mechanism:  E2E
PTP profile:      IEEE1588_DEFAULT
Clock conflicts:  none

Start PTP synchronization now? [Y/n]
```

Answering `n`, sending end-of-input, or failing any validation starts no PTP
process. The validated site answers remain saved for the next run.

## Automatically discovered

Every wizard/setup run obtains these from the live machine:

- native Linux/kernel and distribution
- server vendor/model when DMI exposes them
- linuxptp version
- every physical PCI I350 and X710 port
- NIC family/model and PCI function
- current Linux interface name
- active driver and firmware/NVM string
- MAC and carrier/link state
- hardware TX timestamp support
- hardware RX timestamp support
- hardware raw-clock support
- interface-specific PHC provider index and exact `/dev/ptpX`
- PHC sysfs mapping and whether ports share the PHC
- chrony/chronyd, systemd-timesyncd, NTP service states
- existing chronyd/NTP/systemd-timesyncd, `ptp4l`, and `phc2sys` processes
- whether `CLOCK_REALTIME` reports an upstream synchronization source

`state/server_inventory.txt` is refreshed by the wizard (and by `probe`) as a
human-readable deployment record. It is documentation only; setup never uses it
as a hardware cache.

## Site-provided

The machine cannot safely infer these site facts, so the wizard asks for them:

- PTP domain (`0..255`)
- transport (`L2`, `UDPv4`, or `UDPv6`)
- delay mechanism (`E2E`, `P2P`, or `Auto`)
- PTP profile
- the profile-defined `transportSpecific` byte
- multicast versus configured-unicast Grandmaster discovery for a slave
- synchronized-system versus laboratory-free-running policy for a master
- a master’s confirmed current TAI-minus-UTC offset and its authority
- a reviewed extra linuxptp directive file for non-default profiles or
  configured unicast

The wizard offers visible defaults for common values, but accepting a default is
an explicit operator action. It does not pretend that telecom, power, industrial,
802.1AS, unicast, UTC, or other profile-specific values can be discovered from
the NIC.

## `configs/site.env`

Manual editing is not required for normal operation. The repository ships only
the safe public template `configs/site.env.example`; `configs/site.env` is
ignored. If the live file is absent, the wizard starts from documented defaults
and creates it after validation. If it exists, the wizard safely parses it
without executing it, preloads valid values, and lets the user press Enter to
retain or select a new value. It atomically rewrites a commented file after role
and range validation.

The file stores only site-owned values. It never stores an interface, PCI
function, driver, MAC, or PHC. Safety policies remain explicit:

```text
SLAVE_CLOCK_POLICY=REQUIRE_NO_OTHER_DISCIPLINER
SLAVE_TAI_UTC_POLICY=REQUIRE_VALID_GM
MASTER_TIME_POLICY=REQUIRE_SYNCED_SYSTEM | ALLOW_LAB_FREERUN
```

`IEEE1588_DEFAULT` uses the bundled conservative role templates. Any other
profile—and configured unicast—requires a reviewed `PROFILE_EXTRA_CONFIG`.
Safety-critical keys such as role, timestamp mode, domain, transport, delay,
and management sockets cannot be overridden by that file.

## Slave workflow

```text
External Grandmaster
  -> selected NIC hardware timestamps
  -> NIC PHC
  -> ptp4l
  -> phc2sys
  -> CLOCK_REALTIME
```

Slave setup verifies the selected NIC, driver, timestamp features, PHC, and
link. It refuses an existing `ptp4l`/`phc2sys` and any active competing
system-clock discipliner. It reports a possible temporary `systemctl stop`
command but never stops or permanently disables chrony/NTP itself.

After `ptp4l` starts, `pmc` must report port state `SLAVE`. Before `phc2sys` is
allowed to start, `TIME_PROPERTIES_DATA_SET` must contain PTP timescale, a
numeric `currentUtcOffset`, and `currentUtcOffsetValid=1`. `phc2sys -a -r` is
then started and must produce a recognizable running clock-update state.

## Master workflow

```text
upstream/system time source
  -> CLOCK_REALTIME
  -> selected NIC PHC
  -> ptp4l MASTER
  -> downstream PTP clients
```

The wizard reports whether the system clock is synchronized to an upstream
source or is free-running laboratory time. `REQUIRE_SYNCED_SYSTEM` refuses an
unproven source. `ALLOW_LAB_FREERUN` displays this warning before confirmation:

```text
This server will act as a PTP protocol master, but its time is not traceable or guaranteed accurate.
```

The master path preserves the role-specific ordering: pre-align the selected
PHC from `CLOCK_REALTIME`, verify valid pre-alignment samples, start the master
template, require `MASTER` through `pmc`, verify the advertised UTC offset, stop
the temporary pre-alignment process, and transition to `phc2sys -a -rr`.

The bundled master dataset advertises conservative, non-traceable quality. A
site must provide reviewed profile directives before claiming better quality.

## Advanced and engineering commands

The no-argument wizard is the primary path. Existing read-only, dry-run, manual
mode, status, and stop commands remain available:

```bash
./ptpctl probe
./ptpctl doctor
./ptpctl status
sudo ./ptpctl stop

./ptpctl setup I350-master --dry-run
./ptpctl setup I350-slave --dry-run
./ptpctl setup X710-master --dry-run
./ptpctl setup X710-slave --dry-run

sudo ./ptpctl setup I350-master
sudo ./ptpctl setup I350-slave
sudo ./ptpctl setup X710-master
sudo ./ptpctl setup X710-slave
```

`probe` emits the detailed live NIC report, raw diagnostics, and refreshed
inventory. `doctor` checks dependencies, site values, hardware, services, and
processes. `setup MODE --dry-run` repeats discovery and validation, renders a
temporary config, and prints the exact process plan without starting/stopping a
process or changing persistent configuration.

Manual `setup MODE` is intentionally non-interactive except when multiple valid
ports require a numbered selection. It expects `configs/site.env` to have
already been populated by the wizard or an advanced operator.

## Safety and rollback

Setup holds an exclusive lock and records the pre-launch service, process,
clock, link, driver, and PHC state. Until the final verification succeeds, all
new PIDs remain transaction-owned. Startup, PTP-state, UTC-data, or phc2sys
verification failure—and `INT`, `TERM`, or `HUP`—stops only processes started by
that transaction, removes transient runtime config/state/sockets, and preserves
all logs.

`ptpctl` does not:

- blacklist `igb` or `i40e`
- modify boot parameters
- hard-code a PHC, interface, or PCI address
- change addresses, routes, VLANs, or unrelated network configuration
- stop or permanently disable chrony, NTP, or systemd-timesyncd
- rebind drivers or change NIC firmware

Successful setup atomically commits `run/state.env`. `sudo ./ptpctl stop`
validates the recorded process names, signals only ptpctl-owned PIDs, removes
transient runtime files, and leaves logs, networking, drivers, and services
unchanged.

## Logs and state

```text
configs/site.env             validated site-owned answers
state/server_inventory.txt   refreshed human-readable live inventory
run/                         transient lock, sockets, generated config, state
logs/                        probe/setup/ptp4l/phc2sys/pmc/pre-state logs
```

## Tests

Run:

```bash
./tests/run.sh
```

The mocked suite starts no real `ptp4l` or `phc2sys`. It covers all four
advanced dry-run modes and all four interactive modes, multiple-port selection,
shared PHCs, missing NIC, wrong driver, missing timestamp features, missing PHC,
link down, clock-service conflicts, saved and changed `site.env` defaults,
dry-run safety, cancellation, invalid UTC offset, inventory output, dependency
guidance, and rollback after a deliberately failed mocked `ptp4l` launch.
