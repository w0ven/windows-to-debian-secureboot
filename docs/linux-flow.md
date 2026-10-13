# Debian runtime: trial, authorization, installation

This document covers the Linux payload only. The launcher owns downloads, the
firmware trust update, the one-time boot entry, and the generated configuration.
See [runtime-contract.md](runtime-contract.md) for the Windows/Linux interface.

## Payload and startup order

Package **every `linux/*.sh` file** under `/w2d/`, executable and root-owned.
Also copy `linux/startup.sh` to
`/usr/lib/debian-installer-startup.d/S19w2d`. This includes the required
`timezones.sh` helper; it is a conservative, public-domain IANA name allowlist,
not a program downloaded at boot.

The launcher supplies:

- `/w2d/config.sh`, uid 0, mode **0600** (0400 is also accepted), containing only
  the contract's single-quoted assignments. No plaintext password is needed.
- `/w2d/packages/*.udeb`, already checked against the download lock: the SSH
  server and all required storage/module dependencies for this installer kernel.
- `/preseed.cfg`, whose `preseed/early_command` is `/w2d/boot-gate.sh`.

The scripts do not source `config.sh` or evaluate its values as shell code.
Unknown/duplicate keys, malformed assignments, unsafe network values, an invalid
crypt hash, and unsupported timezones are rejected without printing their values.
Configuration permits IPv4 prefixes 1–30 with an on-subnet gateway, not /31, /32,
DHCP, or an inferred/off-subnet gateway. Timezones must both have safe syntax and
occur in the shipped allowlist. The installed target must contain that timezone
as well. Alias names outside the allowlist fail closed; use a listed IANA name.

1. **S19** starts the soft watchdog with a 600-second default immediately. A
   validated `FALLBACK_SECONDS` (30–86400) adjusts its deadline relative to the
   original start time, not relative to subsequent calls.
2. Before any package unpack, S19 saves the original anna as
   `/usr/bin/anna.w2d-real` and installs the gate wrapper. It unpacks **all** supplied
   udebs, runs `depmod -a` for the running kernel, and requires `hv_storvsc` to load.
   Storage modules are not assumed to be present in the original netboot initrd.
3. Standard d-i S20 loads templates; S30 loads `/preseed.cfg`; S33 calls the early
   command. The boot gate requires successful S19 completion and UEFI runtime.
4. The boot gate identifies exactly one NIC by `NIC_MAC`, loads the Hyper-V
   network driver, and applies the supplied static address, gateway, and DNS.
5. It creates **both `/etc/ssh` and `/run/sshd`**, sets up password-authenticated
   `installer` and `root` UID 0 accounts using the supplied SHA-512 crypt hash,
   creates an ephemeral SSH host key, validates the SSH configuration, and starts
   the daemon on **`SSH_PORT`**. `installer` has `/bin/sh`, not the stock
   network-console forced menu. This runtime does not need the network-console
   udeb or a trial SSH public key.
6. In the default `test` mode, the early command stays in the foreground. It
   returns to the normal Debian installer **only after authorization**. Anna is
   independently gated. No control-console process is killed to start installation.

`SSH_LISTENING` means the daemon started; it does **not** prove that a firewall,
provider network, or SSH client can reach it. Mirror reachability is likewise not
an inbound SSH test. A startup failure leaves installation closed and the trial
watchdog active, rather than selecting a fallback disk or proceeding silently.

## Operator commands

Use the password supplied to the launcher, and the configured port. For example,
using a documentation-only address:

```console
ssh -tt -p 2222 installer@192.0.2.20
/w2d/install-debian.sh --status
/w2d/install-debian.sh --hold
/w2d/install-debian.sh
```

- `--status`: show runtime state and monotonic deadline; never show the hash.
- `--hold`: explicitly hold the soft fallback from an authenticated SSH shell.
  **Holding does not authorize installation.** Merely connecting, starting sshd,
  or reaching a mirror does not hold the timer. A hold cannot win after expiry.
- No argument: preflight the disk and mirrors, then require an interactive
  terminal and the exact displayed confirmation, e.g. **`WIPE /dev/sda`**. The
  actual path might instead be `/dev/nvme0n1`; never copy a guessed path.
- `--cancel`: before authorization only, request an immediate firmware reboot.
  This also works after a hold. Returning to Windows still depends on the
  launcher's preserved Windows default and consumed one-time boot entry.

Unknown arguments, `--yes`, and `--force` are errors, not confirmation bypasses.
The internal `--auto` option is accepted **only with `MODE=auto`**, which means
Windows already obtained the destructive confirmation. The boot gate calls this
option after bringing up SSH. Auto mode still does all configuration, disk and
mirror checks; it does not claim that anybody has verified inbound SSH.

Do not create or edit runtime markers manually. `SSH_CONNECTION` is checked for
interactive commands to avoid an accidental console/autostart hold; it is not a
security boundary against an already privileged local root user.

## Disk and authorization checks

There is no "first disk" fallback and no direct wipe/partition command in this
payload. Before releasing the **standard Debian installer**, it requires:

1. Exactly one block partition matching `EXPECTED_ESP_PARTUUID`.
2. A sysfs-resolved **whole parent disk**, not a name obtained by removing digits
   from a partition path. SATA/SCSI and NVMe names are handled the same way.
3. Exact `EXPECTED_DISK_BYTES`, using sysfs's 512-byte sector count. A GPT disk,
   FAT EFI System Partition type, writable disk, and no active disk holder are
   required. Other disks are not selected simply because their sizes match.
4. Exactly one NIC matching the supplied MAC and successful HTTP fetches of the
   Debian trixie, trixie-updates and trixie-security InRelease endpoints. This is
   a connectivity preflight; d-i/apt subsequently enforce Debian signatures.
5. The explicit interactive wipe phrase in test/manual mode.
6. A second disk identity check after the user confirmation, successful preseed
   loading, and readback of the disk, suite and late-command values.

Only then is the shared state atomically changed to `authorized`. A concurrent
second invocation cannot start another preflight; a repeat invocation after
release reports "already authorized" and does not start a second installation.

### Watchdog/partitioning exclusion

The watchdog and the authorization transition use the same atomic `mkdir` lock
at `/run/w2d-state.lock`. State changes are published with a file rename.

```text
trial ──explicit SSH hold──> held
trial or held ──all checks/confirmation──> authorized ──late checks──> finished
trial expiry / explicit cancel ──> rebooting (terminal for this boot)
```

- The watchdog commits `rebooting` while holding the lock **before** requesting a
  reboot. An installer that loses that race cannot subsequently authorize.
- Authorization checks expiry again while holding the lock, then atomically
  disables fallback and opens both the boot/anna gates via that single state.
- No delayed `sleep; reboot` job is killed optimistically. After authorization,
  a watchdog tick cannot reboot even if the installation takes hours.
- A stale/unavailable lock fails closed. It is not forcibly removed on a guessed
  timeout, which could otherwise steal a live authorization/reboot lock.

This is a **soft** fallback. It cannot recover a firmware/GRUB/kernel hang before
S19, a dead scheduler, missing runtime files, or failed hardware reboot. It is not
provider-console access. A held trial will not automatically fall back. Once
partitioning is authorized, a failed install must be diagnosed; blindly rebooting
cannot be assumed to restore the now-overwritten Windows disk.

## Installation and late finalization

The generated root-only preseed asks Debian's normal installer for:

- Debian **13 / trixie**, GPT, the `atomic` recipe, the explicitly verified disk;
- `linux-image-cloud-amd64`, signed EFI GRUB/shim, and the removable EFI fallback;
- static IPv4 with explicit `netcfg/target_network_config=ifupdown`, and the
  supplied root password **hash**, with no extra normal user;
- `openssh-server`, CA certificates, security and stable updates;
- `/w2d/finish-install.sh` as `preseed/late_command`.

Late finalization requires the authorized state, a Debian 13 target, an existing
zoneinfo file, and an exact match of the target root shadow hash. It then:

- binds the selected MAC to the stable target interface name **`w2d0`** using
  `/etc/systemd/network/10-w2d.link`; it does not assume that the selected NIC will
  always become `eth0`;
- writes static ifupdown configuration and resolver addresses for that interface;
- includes the link file in the target initramfs using an initramfs-tools hook;
- persists `net.ifnames=0 biosdevname=0`, rebuilds initramfs and runs `update-grub`;
- configures the requested SSH port, root login and password authentication,
  disables `ssh.socket` if present, enables `ssh.service`, and checks both
  `sshd -t` and the effective port/root/password settings from `sshd -T`;
- checks nonempty Debian shim/GRUB files, generated GRUB configuration including
  the persistent parameter, and a cloud kernel with matching initrd.

Target commands use `in-target --pass-stdout`: the installer's default
`in-target` routes stdout through `log-output` to syslog, so it cannot supply the
captured `sshd -T` settings without this flag. The regression test uses the pinned
real `in-target`, `log-output`, nested `chroot`, and `sshd`; only mount preparation
is bypassed inside the isolated fixture.

The explicit ifupdown selection fixes the finish-install branch that leaves the
late-written interface configuration intact, rather than relying on a default
that could select NetworkManager or netplan.

The stable `w2d0` name is deliberate: the temporary installer may report `eth0`,
`eth1`, or another name, but the installed static configuration matches the chosen
MAC across boots. The ephemeral installer host key/account is **not** copied into
the target. Expect the installed SSH host key to differ from the trial key.

On success, the late command returns normally. Standard d-i finishes and reboots
without another remote approval. On failure it returns an error without marking
success; the watchdog remains disabled after authorization.

## Logs and sensitive artifacts

Keep the normal installer logs. The payload additionally records root-only
`/var/log/w2d-startup.log`, `w2d-watchdog.log`, `w2d-boot.log`, `w2d-sshd.log` and
`w2d-finish.log` in the installer environment. Normal d-i collection of its logs
continues; this project does not clear shell history or audit logs. Preserve
needed runtime logs before a failed installation is rebooted.

`config.sh` and `install-preseed.cfg` contain a crypt hash and must remain
root-only. They are not printed to logs. After successful late checks, only these
project-owned temporary hash-bearing files are removed. Standard debconf and
installer logs are not purged. Treat the launcher's generated initrd and staging
artifacts as sensitive too; they contain the configured hash.

## Reproducible local tests

Basic tests (Python 3.9+, standard library):

```console
python3 -I -m unittest discover -s tests -p 'test_linux*.py' -v
```

Root-only configuration ownership checks and optional chroot tests are skipped
when their prerequisites are unavailable. To run the actual pinned initrd/SSH
checks as root, provide the verified materials explicitly:

```console
W2D_TEST_INITRD=/path/to/pinned/initrd.gz \
W2D_TEST_SSH_UDEB=/path/to/pinned/openssh-server.udeb \
python3 -I -m unittest discover -s tests -p 'test_linux*.py' -v
```

The optional tests require existing `ar`, `openssl`, `chroot`, and Python paramiko
for the SSH authentication case; they do not install software. They check input
SHA256 before extraction, create a fresh temporary chroot, expose **no host mounts
or block devices**, and replace reboot/network/module actions with record-only
stubs for control-flow tests. Actual sshd password authentication for `installer`
and `root` runs through a local **AF_UNIX socketpair**, with no TCP listener or
server connection. Random test passwords exist only in memory; only their hashes
are written inside the temporary fixture, which is removed afterwards.

Coverage includes shell syntax; malformed/injected configuration; timezone and
IPv4 rejection; exact/duplicate/missing disk identity; MAC selection; mirror
failure; explicit WIPE confirmation; test/auto argument handling; real cdebconf
preseed loading; repeat invocation; anna gating; watchdog/authorization mutual
exclusion; and target configuration/boot-file checks with stubbed in-target tools.

These tests caught the pinned BusyBox's lack of `stat` and awk exponentiation
support; the runtime uses available `ls -ln` metadata and simple arithmetic instead.
They do **not** exercise real partitioning, firmware execution, live Hyper-V driver
loading, a complete installed-system boot, or provider firewalls. This packaged
repository version has **not** been end-to-end tested on a server by these tests.
