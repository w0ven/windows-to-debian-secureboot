# Windows / Debian payload contract

The Windows launcher builds an extra `newc` cpio archive appended as a gzip member to the pinned official Debian netboot initrd. No deployed server is required to build the repository.

Files inside the overlay:

- `/w2d/config.sh`: root-only generated shell assignments; all inputs validated and single-quoted by the launcher. Contains a SHA-512 crypt hash, never a plaintext password.
- `/w2d/packages/*.udeb`: pinned `openssh-server` and required Hyper-V storage udebs. The launcher checks SHA-256 before embedding them.
- `/w2d/boot-gate.sh`, `/w2d/install-debian.sh`, `/w2d/finish-install.sh`, `/w2d/common.sh`, `/w2d/anna-guard.sh`: copies of `linux/` files.
- `/usr/lib/debian-installer-startup.d/S19w2d`: `linux/startup.sh`.
- `/preseed.cfg`: initial locale and static networking only; `preseed/early_command` invokes `/w2d/boot-gate.sh`.

Generated configuration keys:

| Variable | Meaning |
| --- | --- |
| `MODE` | `test` (default) or `auto` (destructive after checks) |
| `IP_ADDRESS`, `PREFIX_LENGTH`, `NETMASK`, `GATEWAY` | IPv4 static network; same-subnet gateway, no /31 or /32 support in v1 |
| `DNS_SERVERS` | Space-separated IPv4 resolver addresses |
| `NIC_MAC` | Lowercase colon-separated MAC of the selected Windows NIC |
| `HOSTNAME` | Valid lowercase single DNS label |
| `TIME_ZONE` | Validated IANA-style timezone; default `Asia/Shanghai` |
| `SSH_PORT` | Port 1–65535, default 22 |
| `ROOT_PASSWORD_HASH` | SHA-512 crypt hash, validated `$6$...` syntax |
| `EXPECTED_ESP_PARTUUID` | Lowercase GPT partition GUID of the original Windows ESP |
| `EXPECTED_DISK_BYTES` | Exact byte size of the Windows system disk |
| `FALLBACK_SECONDS` | 600 by default; starts at the earliest custom startup hook |

Runtime markers live in `/run/w2d-*`. Confirming a test SSH session and allowing installation must remain separate decisions. In test mode the operator can invoke `/w2d/install-debian.sh` from an authenticated `installer` SSH shell, which performs disk/network preflight and requires typing the displayed wipe confirmation. Auto mode has already been explicitly confirmed in Windows, but must still run the same disk/network preflight; it is not proof of inbound SSH reachability. Watchdog must never reboot after partitioning is authorized. No partitioner is available to the normal installer path before the anna gate is released.

The default Windows boot order and original Windows boot files stay unchanged during the trial. Only BootNext is armed. A soft watchdog cannot recover hangs before its hook executes, cannot guarantee hardware reset and cannot replace provider console access. Test mode without installation eventually reboots to Windows; a held interactive session must explicitly acknowledge/hold the watchdog if supported by the Linux scripts.

On an authorized installation, Debian's official installer replaces the identified entire disk, installs signed shim/GRUB and cloud kernel, static IPv4, and password-authenticated root SSH on `SSH_PORT`. All destructive operations must fail closed on missing/mismatched identity and configuration. The installed password must be the supplied hash. Do not retain a test SSH key, expose a callback service or access another server.
