#!/bin/sh
# Installed as /usr/lib/debian-installer-startup.d/S19w2d.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
. /w2d/common.sh
mkdir -p /run /var/log
exec >>/var/log/w2d-startup.log 2>&1
# Start with a safe default even if the generated configuration is invalid.
w2d_start_watchdog || exit 1
[ ! -e /run/w2d-startup-ready ] || exit 0
startup_failed() { w2d_error "$1"; : > /run/w2d-startup-failed; exit 1; }
trap 'w2d_unlock' 0
# Gate before unpacking anything: partial startup must not expose anna.
if [ ! -e /usr/bin/anna.w2d-real ]; then
    [ -x /usr/bin/anna ] || startup_failed 'Original anna is missing'
    mv /usr/bin/anna /usr/bin/anna.w2d-real
fi
[ -x /usr/bin/anna.w2d-real ] || startup_failed 'Saved anna is not executable'
cp /w2d/anna-guard.sh /usr/bin/anna
chmod 755 /usr/bin/anna
w2d_load_config || startup_failed 'Configuration rejected'
w2d_configure_deadline || startup_failed 'Cannot configure watchdog deadline'
packages=0
for package in /w2d/packages/*.udeb; do
    [ -f "$package" ] || continue
    udpkg --unpack "$package" || startup_failed 'Pinned udeb unpack failed'
    packages=$((packages+1))
done
[ "$packages" -gt 0 ] || startup_failed 'No pinned installer packages supplied'
[ -x /usr/sbin/sshd ] || startup_failed 'openssh-server udeb missing'
depmod -a "$(uname -r)" || startup_failed 'Storage module depmod failed'
modprobe hv_storvsc || startup_failed 'Required Hyper-V storage driver unavailable'
rm -f /run/w2d-startup-failed
: > /run/w2d-startup-ready
w2d_log 'Pinned udebs unpacked, storage ready; anna remains gated.'
