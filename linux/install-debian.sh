#!/bin/sh
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
. /w2d/common.sh
usage() { printf 'Usage: /w2d/install-debian.sh [--status|--hold|--cancel]\nNo option: SSH-only, interactive WIPE confirmation. --auto is reserved for MODE=auto boot.\n'; }
[ "$#" -le 1 ] || { usage; exit 1; }
action=${1:-install}
case $action in
    --status)
        printf 'State: %s\n' "$(w2d_state)"
        if [ -f /run/w2d-deadline ]; then printf 'Monotonic trial deadline: %s\n' "$(cat /run/w2d-deadline)"; fi
        [ ! -e /run/w2d-ssh-ready ] || printf 'SSH daemon started (not proof of inbound reachability).\n'
        exit 0;;
    --help) usage; exit 0;;
    install|--auto|--hold|--cancel) ;;
    *) usage; exit 1;;
esac
[ "$(id -u)" = 0 ] || { w2d_error 'UID 0 is required'; exit 1; }
trap 'w2d_unlock' 0
if [ "$action" = --hold ] || [ "$action" = --cancel ]; then
    w2d_require_ssh || exit 1
    if [ "$action" = --hold ]; then w2d_hold; else w2d_cancel; fi
    exit $?
fi
if w2d_is_authorized; then w2d_log 'Already authorized; not starting a second installation.'; exit 0; fi
w2d_load_config || exit 1
if [ "$action" = --auto ]; then
    [ "$MODE" = auto ] || { w2d_error '--auto is prohibited in test mode'; exit 1; }
else
    w2d_require_ssh || exit 1
fi
[ -e /run/w2d-startup-ready ] && [ -e /run/w2d-ssh-ready ] || { w2d_error 'Boot gate is not ready'; exit 1; }
w2d_deadline_valid || { w2d_error 'Trial is expired or unavailable'; exit 1; }
mkdir /run/w2d-install.lock 2>/dev/null || { w2d_error 'Another installation preflight is in progress'; exit 1; }
cleanup() { w2d_unlock; rmdir /run/w2d-install.lock; }
trap cleanup 0
trap 'exit 1' HUP INT TERM
w2d_identify_disk || exit 1
approved_disk=$DISK_DEVICE
w2d_find_nic || exit 1
w2d_network_preflight || exit 1
if [ "$action" != --auto ]; then w2d_confirm_disk || exit 1; fi
# Do not assume that a disk stayed attached while the operator was reading.
w2d_identify_disk || exit 1
[ "$DISK_DEVICE" = "$approved_disk" ] || { w2d_error 'Disk changed during confirmation'; exit 1; }
w2d_write_preseed /w2d/install-preseed.cfg || exit 1
# Values are loaded while both the boot gate and anna are still closed.
debconf-set-selections /w2d/install-preseed.cfg || { w2d_error 'Cannot load installation preseed'; exit 1; }
[ "$(debconf-get partman-auto/disk)" = "$DISK_DEVICE" ] &&
    [ "$(debconf-get mirror/suite)" = trixie ] &&
    [ "$(debconf-get preseed/late_command)" = /w2d/finish-install.sh ] || {
    w2d_error 'Installer did not retain the required disk/suite/late-command settings'; exit 1;
}
printf '%s\n%s\n%s\n' "$DISK_DEVICE" "$EXPECTED_ESP_PARTUUID" "$EXPECTED_DISK_BYTES" > /run/w2d-approved-disk
w2d_publish_authorization || exit 1
w2d_log "Authorized standard Debian installer on $DISK_DEVICE; watchdog permanently disabled for this boot."
w2d_log 'Installer will finish and reboot without an additional online approval.'
