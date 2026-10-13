#!/bin/sh
# preseed/late_command: finish normally; never wait for a remote reboot approval.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
. /w2d/common.sh
exec >>/var/log/w2d-finish.log 2>&1
[ "$(w2d_state)" != finished ] || exit 0
[ "$(w2d_state)" = authorized ] || { w2d_error 'Late command called without installation authorization'; exit 1; }
w2d_load_config || exit 1
w2d_log 'Configuring installed network, root SSH and persistent boot parameters.'
w2d_finish_target || { w2d_error 'Finalization failed; keep installer logs and diagnose before reboot'; exit 1; }
sync
w2d_lock || exit 1
trap 'w2d_unlock' 0
[ "$(w2d_state)" = authorized ] || { w2d_error 'Unexpected finalization state'; exit 1; }
w2d_set_state finished
w2d_unlock
# Do not delete installer/audit logs. Remove only our temporary hash-bearing files.
rm -f /w2d/install-preseed.cfg /w2d/config.sh
unset ROOT_PASSWORD_HASH
w2d_log 'Installed boot files and SSH settings checked; d-i may complete its normal reboot.'
