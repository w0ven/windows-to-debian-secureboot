#!/bin/sh
# Called synchronously by preseed/early_command; do not return before approval.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
. /w2d/common.sh
exec >>/var/log/w2d-boot.log 2>&1
trap 'w2d_unlock' 0
fail_closed() {
    w2d_error "$1"
    : > /run/w2d-boot-failed
    # The watchdog still controls trial expiry; never fall through to main-menu.
    while :; do sleep 5; done
}
w2d_is_authorized && exit 0
w2d_load_config || fail_closed 'Configuration rejected'
[ -e /run/w2d-startup-ready ] && [ ! -e /run/w2d-startup-failed ] || fail_closed 'S19 startup did not complete'
[ -d /sys/firmware/efi ] || fail_closed 'UEFI runtime is required'
if [ ! -e /run/w2d-ssh-ready ]; then
    modprobe hv_vmbus || fail_closed 'Hyper-V bus module unavailable'
    modprobe hv_netvsc || fail_closed 'Hyper-V network module unavailable'
    attempts=0
    until w2d_find_nic; do
        attempts=$((attempts+1))
        [ "$attempts" -lt 60 ] || fail_closed 'Selected NIC MAC not uniquely available'
        sleep 1
    done
    ip link set dev "$IFACE" up || fail_closed 'Cannot bring selected NIC up'
    ip addr replace "$IP_ADDRESS/$PREFIX_LENGTH" dev "$IFACE" || fail_closed 'Cannot configure static address'
    ip route replace default via "$GATEWAY" dev "$IFACE" || fail_closed 'Cannot configure gateway'
    : > /etc/resolv.conf
    for dns in $DNS_SERVERS; do printf 'nameserver %s\n' "$dns" >> /etc/resolv.conf; done
    hostname "$HOSTNAME" || fail_closed 'Cannot set hostname'
    w2d_setup_accounts || fail_closed 'Installer SSH account/configuration failed'
    /usr/sbin/sshd -f /w2d/sshd_config -E /var/log/w2d-sshd.log || fail_closed 'SSH daemon failed to start'
    printf '%s\n' "$IFACE" > /run/w2d-iface
    : > /run/w2d-ssh-ready
    w2d_log "SSH_LISTENING interface=$IFACE port=$SSH_PORT; inbound reachability NOT verified."
    if [ -c /dev/console ]; then
        printf 'W2D: SSH listening on configured port %s; log in as installer with the supplied root password.\nRun /w2d/install-debian.sh --hold to hold the fallback, or /w2d/install-debian.sh to request installation.\n' "$SSH_PORT" > /dev/console
    fi
fi
if [ "$MODE" = auto ]; then
    /w2d/install-debian.sh --auto || fail_closed 'Automatic preflight/authorization failed'
fi
while ! w2d_is_authorized; do sleep 1; done
w2d_log 'Installation authorized; returning normally to Debian installer.'
