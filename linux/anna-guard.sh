#!/bin/sh
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
. /w2d/common.sh
# Missing, trial, held, and rebooting states are all closed. No magic touch file.
while ! w2d_is_authorized; do sleep 1; done
[ -x /usr/bin/anna.w2d-real ] || { w2d_error 'Saved anna missing'; exit 1; }
exec /usr/bin/anna.w2d-real "$@"
