#!/bin/sh
# Shared installer-runtime functions. Never source the generated configuration.
set +x
umask 077
W2D_RUN=/run
W2D_PAYLOAD=/w2d
W2D_SYS=/sys
W2D_DEV=/dev
W2D_TARGET=/target
W2D_LOCK_HELD=0

w2d_error() { printf 'W2D_ERROR: %s\n' "$*" >&2; }
w2d_log() { printf 'W2D: %s\n' "$*"; }
w2d_uint() { printf '%s\n' "$1" | grep -Eq '^(0|[1-9][0-9]*)$'; }
w2d_now() { cut -d. -f1 /proc/uptime; }
w2d_reboot() { /sbin/reboot -f; }
w2d_is_block() { [ -b "$1" ]; }
# d-i otherwise sends stdout to syslog, breaking callers that capture sshd -T.
w2d_in_target() { in-target --pass-stdout "$@"; }

w2d_ipv4() {
    printf '%s\n' "$1" | awk -F. '
      NF != 4 { exit 1 }
      { for (i=1;i<=4;i++) if ($i !~ /^(0|[1-9][0-9]*)$/ || $i>255) exit 1 }
    '
}
w2d_unicast() {
    w2d_ipv4 "$1" || return 1
    case ${1%%.*} in 0|127) return 1;; esac
    [ "${1%%.*}" -lt 224 ]
}
w2d_validate_config() {
    case $MODE in test|auto) ;; *) w2d_error 'Invalid MODE'; return 1;; esac
    w2d_uint "$PREFIX_LENGTH" && [ "$PREFIX_LENGTH" -ge 1 ] && [ "$PREFIX_LENGTH" -le 30 ] || {
        w2d_error 'Invalid PREFIX_LENGTH (supported: 1..30)'; return 1;
    }
    w2d_unicast "$IP_ADDRESS" && w2d_unicast "$GATEWAY" && w2d_ipv4 "$NETMASK" || {
        w2d_error 'Invalid IPv4 configuration'; return 1;
    }
    printf '%s %s %s %s\n' "$IP_ADDRESS" "$GATEWAY" "$NETMASK" "$PREFIX_LENGTH" | awk '
      function ip(s,a) { split(s,a,"."); return ((a[1]*256+a[2])*256+a[3])*256+a[4] }
      { host=1; for (bit=0;bit<32-$4;bit++) host*=2; n=ip($1); g=ip($2);
        if (ip($3)!=4294967296-host || int(n/host)!=int(g/host) || n==g ||
            n%host==0 || n%host==host-1 || g%host==0 || g%host==host-1) exit 1 }
    ' || { w2d_error 'Netmask/subnet/gateway mismatch'; return 1; }
    [ -n "$DNS_SERVERS" ] || { w2d_error 'DNS_SERVERS is required'; return 1; }
    case $DNS_SERVERS in *[!0-9.\ ]*) w2d_error 'Invalid DNS_SERVERS'; return 1;; esac
    count=0
    for dns in $DNS_SERVERS; do
        w2d_unicast "$dns" || { w2d_error 'Invalid DNS_SERVERS'; return 1; }
        count=$((count+1))
    done
    [ "$count" -ge 1 ] && [ "$count" -le 8 ] || { w2d_error 'Invalid DNS server count'; return 1; }
    printf '%s\n' "$NIC_MAC" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || {
        w2d_error 'Invalid NIC_MAC'; return 1;
    }
    case $NIC_MAC in 00:00:00:00:00:00|?[13579bdf]:*) w2d_error 'NIC_MAC must be a nonzero unicast MAC'; return 1;; esac
    [ "${#HOSTNAME}" -le 63 ] && printf '%s\n' "$HOSTNAME" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' || {
        w2d_error 'Invalid HOSTNAME'; return 1;
    }
    printf '%s\n' "$TIME_ZONE" | grep -Eq '^(UTC|[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+)$' || {
        w2d_error 'Invalid TIME_ZONE'; return 1;
    }
    [ -f "$W2D_PAYLOAD/timezones.sh" ] || { w2d_error 'Timezone allowlist missing'; return 1; }
    . "$W2D_PAYLOAD/timezones.sh"
    w2d_known_timezone "$TIME_ZONE" || { w2d_error 'Unsupported/unknown TIME_ZONE'; return 1; }
    w2d_uint "$SSH_PORT" && [ "${#SSH_PORT}" -le 5 ] && [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || {
        w2d_error 'Invalid SSH_PORT'; return 1;
    }
    # Values are supplied on stdin, never as arguments to a logging/crypto tool.
    printf '%s\n' "$ROOT_PASSWORD_HASH" | grep -Eq '^\$6\$(rounds=[1-9][0-9]{3,8}\$)?[./A-Za-z0-9]{1,16}\$[./A-Za-z0-9]{86}$' || {
        w2d_error 'Invalid ROOT_PASSWORD_HASH'; return 1;
    }
    printf '%s\n' "$EXPECTED_ESP_PARTUUID" | grep -Eq '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' || {
        w2d_error 'Invalid EXPECTED_ESP_PARTUUID'; return 1;
    }
    w2d_uint "$EXPECTED_DISK_BYTES" && printf '%s\n' "$EXPECTED_DISK_BYTES" | awk '
      length($0)>16 || $0<512 || $0>9007199254740991 || $0%512!=0 { exit 1 }
    ' || { w2d_error 'Invalid EXPECTED_DISK_BYTES'; return 1; }
    w2d_uint "$FALLBACK_SECONDS" && [ "${#FALLBACK_SECONDS}" -le 5 ] &&
        [ "$FALLBACK_SECONDS" -ge 30 ] && [ "$FALLBACK_SECONDS" -le 86400 ] || {
        w2d_error 'Invalid FALLBACK_SECONDS (supported: 30..86400)'; return 1;
    }
}

w2d_load_config() {
    config_file=${1:-/w2d/config.sh}
    [ -f "$config_file" ] && [ ! -L "$config_file" ] || { w2d_error 'Missing regular config file'; return 1; }
    # The pinned d-i BusyBox has no stat applet. Numeric ls metadata is available.
    LC_ALL=C ls -ldn "$config_file" | awk '
      ($1!="-rw-------" && $1!="-r--------") || $3!=0 { exit 1 }
      END { if (NR!=1) exit 1 }
    ' || { w2d_error 'Config must be root-owned mode 0600/0400'; return 1; }
    unset MODE IP_ADDRESS PREFIX_LENGTH NETMASK GATEWAY DNS_SERVERS NIC_MAC HOSTNAME TIME_ZONE SSH_PORT ROOT_PASSWORD_HASH EXPECTED_ESP_PARTUUID EXPECTED_DISK_BYTES FALLBACK_SECONDS
    MODE=test TIME_ZONE=Asia/Shanghai SSH_PORT=22 FALLBACK_SECONDS=600
    IP_ADDRESS= PREFIX_LENGTH= NETMASK= GATEWAY= DNS_SERVERS= NIC_MAC= HOSTNAME=
    ROOT_PASSWORD_HASH= EXPECTED_ESP_PARTUUID= EXPECTED_DISK_BYTES=
    seen=' '
    cr=$(printf '\r')
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%"$cr"}
        case $line in ''|'#'*) continue;; esac
        case $line in *=*) key=${line%%=*}; value=${line#*=};; *) w2d_error 'Malformed config assignment'; return 1;; esac
        case $value in \'*\') value=${value#\'}; value=${value%\'};; *) w2d_error 'Config values must be single quoted'; return 1;; esac
        case $value in *\'*) w2d_error 'Quote in config value'; return 1;; esac
        case $seen in *" $key "*) w2d_error 'Duplicate config key'; return 1;; esac
        seen="$seen$key "
        case $key in
            MODE) MODE=$value;; IP_ADDRESS) IP_ADDRESS=$value;; PREFIX_LENGTH) PREFIX_LENGTH=$value;;
            NETMASK) NETMASK=$value;; GATEWAY) GATEWAY=$value;; DNS_SERVERS) DNS_SERVERS=$value;;
            NIC_MAC) NIC_MAC=$value;; HOSTNAME) HOSTNAME=$value;; TIME_ZONE) TIME_ZONE=$value;;
            SSH_PORT) SSH_PORT=$value;; ROOT_PASSWORD_HASH) ROOT_PASSWORD_HASH=$value;;
            EXPECTED_ESP_PARTUUID) EXPECTED_ESP_PARTUUID=$value;; EXPECTED_DISK_BYTES) EXPECTED_DISK_BYTES=$value;;
            FALLBACK_SECONDS) FALLBACK_SECONDS=$value;;
            *) w2d_error 'Unknown config key'; return 1;;
        esac
    done < "$config_file"
    unset line value
    w2d_validate_config
}

# Both the watchdog's reboot decision and authorization use this same lock.
# Never reap a possibly live lock: a stale lock fails closed, not destructively.
w2d_lock() {
    tries=0
    while ! mkdir "$W2D_RUN/w2d-state.lock" 2>/dev/null; do
        tries=$((tries+1))
        [ "$tries" -lt 30 ] || { w2d_error 'Runtime state lock unavailable'; return 1; }
        sleep 1
    done
    W2D_LOCK_HELD=1
}
w2d_unlock() {
    if [ "$W2D_LOCK_HELD" = 1 ]; then
        rmdir "$W2D_RUN/w2d-state.lock"
        W2D_LOCK_HELD=0
    fi
}
w2d_state() { if [ -f "$W2D_RUN/w2d-state" ]; then cat "$W2D_RUN/w2d-state"; else printf 'missing\n'; fi; }
w2d_set_state() {
    [ "$W2D_LOCK_HELD" = 1 ] || return 1
    printf '%s\n' "$1" > "$W2D_RUN/w2d-state.tmp" || return 1
    mv "$W2D_RUN/w2d-state.tmp" "$W2D_RUN/w2d-state"
}
w2d_is_authorized() {
    case $(w2d_state) in authorized|finished) return 0;; *) return 1;; esac
}
w2d_deadline_valid() {
    [ "$(w2d_state)" = held ] && return 0
    [ "$(w2d_state)" = trial ] || return 1
    deadline=$(cat "$W2D_RUN/w2d-deadline") || return 1
    w2d_uint "$deadline" || return 1
    [ "$(w2d_now)" -lt "$deadline" ]
}
w2d_watchdog_tick() {
    w2d_lock || return 0
    case $(w2d_state) in
        authorized|finished|held|rebooting) w2d_unlock; return 1;;
        trial)
            if ! w2d_deadline_valid; then
                w2d_set_state rebooting || { w2d_unlock; return 0; }
                w2d_log 'Trial deadline reached; requesting firmware reboot (Windows return is not guaranteed).'
                w2d_reboot || w2d_error 'Reboot request failed; installation remains prohibited'
                w2d_unlock
                return 1
            fi;;
        *) w2d_error 'Unknown watchdog state; refusing destructive operations';;
    esac
    w2d_unlock
    return 0
}
w2d_watchdog_loop() { while w2d_watchdog_tick; do sleep 1; done; }
w2d_start_watchdog() {
    w2d_lock || return 1
    if [ "$(w2d_state)" != missing ]; then w2d_unlock; return 0; fi
    started=$(w2d_now)
    w2d_uint "$started" || { w2d_unlock; return 1; }
    printf '%s\n' "$started" > "$W2D_RUN/w2d-started"
    printf '%s\n' "$((started+600))" > "$W2D_RUN/w2d-deadline"
    w2d_set_state trial
    w2d_unlock
    (trap '' HUP; w2d_watchdog_loop) </dev/null >>/var/log/w2d-watchdog.log 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
}
w2d_configure_deadline() {
    w2d_lock || return 1
    if [ "$(w2d_state)" = trial ]; then
        started=$(cat "$W2D_RUN/w2d-started")
        w2d_uint "$started" || { w2d_unlock; return 1; }
        printf '%s\n' "$((started+FALLBACK_SECONDS))" > "$W2D_RUN/w2d-deadline"
    fi
    w2d_unlock
}
w2d_hold() {
    w2d_lock || return 1
    case $(w2d_state) in
        held) w2d_unlock; return 0;;
        trial)
            if w2d_deadline_valid; then
                w2d_set_state held || { w2d_unlock; return 1; }
            else w2d_unlock; return 1; fi;;
        *) w2d_unlock; return 1;;
    esac
    w2d_unlock
    w2d_log 'Trial watchdog held by SSH operator; installation is still prohibited.'
}
w2d_cancel() {
    w2d_lock || return 1
    case $(w2d_state) in trial|held) ;; *) w2d_unlock; w2d_error 'Cannot cancel after authorization/reboot decision'; return 1;; esac
    w2d_set_state rebooting || { w2d_unlock; return 1; }
    w2d_reboot || { w2d_unlock; w2d_error 'Reboot failed; state remains rebooting'; return 1; }
    w2d_unlock
}
w2d_publish_authorization() {
    w2d_lock || return 1
    if ! w2d_deadline_valid; then
        w2d_unlock; w2d_error 'Watchdog deadline/reboot decision won; installation NOT authorized'; return 1
    fi
    # A single atomic state transition both disables reboot and opens the gate.
    w2d_set_state authorized || { w2d_unlock; return 1; }
    w2d_unlock
}

w2d_require_ssh() {
    [ "$(id -u)" = 0 ] && [ -n "${SSH_CONNECTION:-}" ] || {
        w2d_error 'This action requires an authenticated installer/root SSH shell'; return 1;
    }
}
w2d_find_nic() {
    IFACE= matches=0
    for path in "$W2D_SYS"/class/net/*; do
        [ -f "$path/address" ] || continue
        [ "$(cat "$path/address")" = "$NIC_MAC" ] || continue
        name=${path##*/}
        printf '%s\n' "$name" | grep -Eq '^[A-Za-z0-9_.:-]{1,15}$' || return 1
        IFACE=$name; matches=$((matches+1))
    done
    [ "$matches" = 1 ] || { w2d_error 'NIC MAC must match exactly one interface'; return 1; }
}
w2d_identify_disk() {
    ESP_DEVICE= DISK_DEVICE= matches=0
    for path in "$W2D_SYS"/class/block/*; do
        [ -f "$path/partition" ] || continue
        name=${path##*/}
        printf '%s\n' "$name" | grep -Eq '^[A-Za-z0-9_-]+$' || continue
        candidate="$W2D_DEV/$name"
        w2d_is_block "$candidate" || continue
        uuid=$(blkid -s PARTUUID -o value "$candidate" 2>/dev/null) || continue
        [ "$uuid" = "$EXPECTED_ESP_PARTUUID" ] || continue
        ESP_DEVICE=$candidate; esp_sys=$path; matches=$((matches+1))
    done
    [ "$matches" = 1 ] || { w2d_error 'Expected ESP PARTUUID must match exactly one block partition'; return 1; }
    resolved=$(readlink -f "$esp_sys") || return 1
    parent_path=${resolved%/*}; parent=${parent_path##*/}
    printf '%s\n' "$parent" | grep -Eq '^[A-Za-z0-9_-]+$' || return 1
    [ "$(readlink -f "$W2D_SYS/class/block/$parent")" = "$parent_path" ] &&
        [ ! -e "$W2D_SYS/class/block/$parent/partition" ] || {
        w2d_error 'ESP sysfs parent is not a whole disk'; return 1;
    }
    DISK_DEVICE="$W2D_DEV/$parent"
    w2d_is_block "$DISK_DEVICE" || { w2d_error 'Parent block device missing'; return 1; }
    sectors=$(cat "$W2D_SYS/class/block/$parent/size") || return 1
    w2d_uint "$sectors" || return 1
    bytes=$(printf '%s\n' "$sectors" | awk '$0<=17592186044415 { printf "%.0f",$0*512 }')
    [ "$bytes" = "$EXPECTED_DISK_BYTES" ] || { w2d_error 'Exact disk byte-size mismatch'; return 1; }
    [ "$(cat "$W2D_SYS/class/block/$parent/ro")" = 0 ] || { w2d_error 'Disk is read-only'; return 1; }
    [ "$(blkid -p -s PTTYPE -o value "$DISK_DEVICE" 2>/dev/null)" = gpt ] &&
        [ "$(blkid -s TYPE -o value "$ESP_DEVICE" 2>/dev/null)" = vfat ] &&
        [ "$(blkid -p -s PART_ENTRY_TYPE -o value "$ESP_DEVICE" 2>/dev/null)" = c12a7328-f81f-11d2-ba4b-00a0c93ec93b ] || {
        w2d_error 'Expected GPT/FAT EFI system partition metadata missing'; return 1;
    }
    for holder in "$W2D_SYS/class/block/$parent/holders/"*; do
        [ ! -e "$holder" ] || { w2d_error 'Selected disk has an active holder'; return 1; }
    done
}
w2d_network_preflight() {
    # Reachability only. d-i/apt separately verify Debian release signatures.
    n=0
    for url in http://deb.debian.org/debian/dists/trixie/InRelease http://deb.debian.org/debian/dists/trixie-updates/InRelease http://security.debian.org/debian-security/dists/trixie-security/InRelease; do
        n=$((n+1)); probe="$W2D_RUN/w2d-network-probe-$n"
        if ! wget -q -T 30 -O "$probe" "$url" || ! grep -q '^-----BEGIN PGP SIGNED MESSAGE-----' "$probe"; then
            rm -f "$probe"; w2d_error 'Debian mirror/security reachability check failed'; return 1
        fi
        rm -f "$probe"
    done
    w2d_log 'Mirror and security endpoints reachable; this does NOT prove inbound SSH access.'
}
w2d_confirm_disk() {
    [ -t 0 ] || { w2d_error 'Wipe confirmation requires an interactive terminal'; return 1; }
    printf '\nERASE ALL DATA on %s (%s bytes); original ESP %s\nType exactly: WIPE %s\n> ' "$DISK_DEVICE" "$EXPECTED_DISK_BYTES" "$EXPECTED_ESP_PARTUUID" "$DISK_DEVICE"
    IFS= read -r confirmation || return 1
    [ "$confirmation" = "WIPE $DISK_DEVICE" ] || { w2d_error 'Wipe confirmation did not match; nothing released'; return 1; }
}

w2d_write_preseed() {
    # All substituted fields were validated. The hash is data, never shell code.
    preseed=${1:-/w2d/install-preseed.cfg}
    rm -f "$preseed.tmp" || return 1
    cat > "$preseed.tmp" <<EOF || return 1
d-i debian-installer/locale string en_US.UTF-8
d-i localechooser/supported-locales multiselect en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select $IFACE
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/disable_dhcp boolean true
d-i netcfg/use_autoconfig boolean false
d-i netcfg/get_ipaddress string $IP_ADDRESS
d-i netcfg/get_netmask string $NETMASK
d-i netcfg/get_gateway string $GATEWAY
d-i netcfg/get_nameservers string $DNS_SERVERS
d-i netcfg/get_hostname string $HOSTNAME
d-i netcfg/get_domain string
d-i netcfg/confirm_static boolean true
d-i netcfg/target_network_config select ifupdown
d-i mirror/country string manual
d-i mirror/protocol string http
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i mirror/suite string trixie
d-i mirror/udeb/suite string trixie
d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
d-i passwd/root-password-crypted password $ROOT_PASSWORD_HASH
d-i clock-setup/utc boolean true
d-i time/zone string $TIME_ZONE
d-i clock-setup/ntp boolean true
d-i partman-auto/disk string $DISK_DEVICE
d-i partman-auto/method string regular
d-i partman-partitioning/choose_label select gpt
d-i partman-partitioning/default_label string gpt
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i base-installer/kernel/image string linux-image-cloud-amd64
d-i apt-setup/non-free-firmware boolean false
d-i apt-setup/contrib boolean false
d-i apt-setup/non-free boolean false
d-i apt-setup/services-select multiselect security, updates
d-i pkgsel/include string openssh-server ca-certificates
d-i pkgsel/upgrade select safe-upgrade
tasksel tasksel/first multiselect standard
popularity-contest popularity-contest/participate boolean false
d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string $DISK_DEVICE
d-i grub-installer/force-efi-extra-removable boolean true
d-i preseed/early_command string
d-i preseed/late_command string /w2d/finish-install.sh
d-i finish-install/reboot_in_progress note
EOF
    chmod 600 "$preseed.tmp" || return 1
    mv "$preseed.tmp" "$preseed"
}

w2d_setup_accounts() {
    # Installer is uid 0 with a real shell; no network-console forced menu.
    mkdir -p /etc/ssh /run/sshd || return 1
    chmod 755 /run/sshd || return 1
    sed -i '/^installer:/d' /etc/passwd || return 1
    printf 'installer:x:0:0:installer:/:/bin/sh\n' >> /etc/passwd || return 1
    if ! grep -q '^sshd:' /etc/passwd; then
        printf 'sshd:*:100:65534::/run/sshd:/bin/false\n' >> /etc/passwd || return 1
    fi
    if ! grep -q '^nogroup:' /etc/group; then
        printf 'nogroup:*:65534:\n' >> /etc/group || return 1
    fi
    touch /etc/shadow || return 1
    chmod 600 /etc/shadow || return 1
    sed -i '/^installer:/d; /^root:/d' /etc/shadow || return 1
    printf 'installer:%s:1:0:99999:7:::\nroot:%s:1:0:99999:7:::\n' "$ROOT_PASSWORD_HASH" "$ROOT_PASSWORD_HASH" >> /etc/shadow || return 1
    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
        ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key || return 1
    fi
    cat > /w2d/sshd_config <<EOF || return 1
Port $SSH_PORT
ListenAddress $IP_ADDRESS
HostKey /etc/ssh/ssh_host_ed25519_key
PidFile /run/w2d-sshd.pid
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AllowUsers installer root
UseDNS no
PrintMotd no
EOF
    chmod 600 /w2d/sshd_config || return 1
    /usr/sbin/sshd -t -f /w2d/sshd_config
}

w2d_finish_target() {
    t=$W2D_TARGET
    [ -f "$t/etc/debian_version" ] && [ -f "$t/usr/share/zoneinfo/$TIME_ZONE" ] || {
        w2d_error 'Installed Debian target/timezone missing'; return 1;
    }
    case $(cat "$t/etc/debian_version") in 13|13.*) ;; *) w2d_error 'Target is not Debian 13'; return 1;; esac
    [ "$(awk -F: '$1=="root" { print $2 }' "$t/etc/shadow")" = "$ROOT_PASSWORD_HASH" ] || {
        w2d_error 'Installed root password hash does not match supplied hash'; return 1;
    }
    mkdir -p "$t/etc/ssh/sshd_config.d" "$t/etc/default/grub.d" "$t/etc/systemd/network" "$t/etc/initramfs-tools/hooks" "$t/run/sshd" || return 1
    # An explicit MAC-bound name avoids guessing which ethN persists after reboot.
    cat > "$t/etc/systemd/network/10-w2d.link" <<EOF || return 1
[Match]
MACAddress=$NIC_MAC
[Link]
NamePolicy=
Name=w2d0
EOF
    cat > "$t/etc/network/interfaces" <<EOF || return 1
# Only the explicitly selected, MAC-bound interface is configured.
auto lo
iface lo inet loopback

auto w2d0
iface w2d0 inet static
    address $IP_ADDRESS/$PREFIX_LENGTH
    gateway $GATEWAY
    dns-nameservers $DNS_SERVERS
EOF
    # A chroot-absolute resolver symlink must not redirect writes into the installer.
    rm -f "$t/etc/resolv.conf" || return 1
    : > "$t/etc/resolv.conf" || return 1
    for dns in $DNS_SERVERS; do printf 'nameserver %s\n' "$dns" >> "$t/etc/resolv.conf" || return 1; done
    cat > "$t/etc/ssh/sshd_config.d/00-w2d.conf" <<EOF || return 1
Port $SSH_PORT
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no
EOF
    cat > "$t/etc/default/grub.d/10-w2d.cfg" <<'EOF' || return 1
GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX net.ifnames=0 biosdevname=0"
EOF
    chmod 644 "$t/etc/network/interfaces" "$t/etc/systemd/network/10-w2d.link" "$t/etc/ssh/sshd_config.d/00-w2d.conf" "$t/etc/default/grub.d/10-w2d.cfg" || return 1
    # Include the MAC/name mapping even if the NIC is discovered in initramfs.
    cat > "$t/etc/initramfs-tools/hooks/w2d-link" <<'EOF' || return 1
#!/bin/sh
set -e
case "${1:-}" in prereqs) exit 0;; esac
mkdir -p "$DESTDIR/etc/systemd/network"
cp /etc/systemd/network/10-w2d.link "$DESTDIR/etc/systemd/network/10-w2d.link"
EOF
    chmod 755 "$t/etc/initramfs-tools/hooks/w2d-link" || return 1
    # Do not copy the ephemeral installer host key or installer account.
    w2d_in_target update-initramfs -u -k all || return 1
    w2d_in_target update-grub || return 1
    if [ -f "$t/usr/lib/systemd/system/ssh.socket" ] || [ -f "$t/lib/systemd/system/ssh.socket" ]; then
        w2d_in_target systemctl disable ssh.socket || return 1
    fi
    w2d_in_target systemctl enable ssh || return 1
    w2d_in_target /usr/sbin/sshd -t || return 1
    effective=$(w2d_in_target /usr/sbin/sshd -T) || return 1
    [ "$(printf '%s\n' "$effective" | awk '$1=="port" { print $2 }')" = "$SSH_PORT" ] &&
        printf '%s\n' "$effective" | grep -qx 'permitrootlogin yes' &&
        printf '%s\n' "$effective" | grep -qx 'passwordauthentication yes' || {
        w2d_error 'Installed effective SSH settings do not match requested settings'; return 1;
    }
    [ -s "$t/boot/efi/EFI/debian/shimx64.efi" ] && [ -s "$t/boot/efi/EFI/debian/grubx64.efi" ] &&
        [ -s "$t/boot/grub/grub.cfg" ] && grep -q 'net.ifnames=0' "$t/boot/grub/grub.cfg" || {
        w2d_error 'Installed signed EFI/GRUB boot files or persistent boot parameters missing'; return 1;
    }
    kernels=0
    for kernel in "$t"/boot/vmlinuz-*-cloud-amd64; do
        [ -s "$kernel" ] || continue
        version=${kernel##*/vmlinuz-}
        [ -s "$t/boot/initrd.img-$version" ] || { w2d_error 'Matching installed cloud initrd missing'; return 1; }
        kernels=$((kernels+1))
    done
    [ "$kernels" -gt 0 ] || { w2d_error 'Installed cloud kernel missing'; return 1; }
}
