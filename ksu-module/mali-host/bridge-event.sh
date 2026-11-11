#!/system/bin/sh
# inotifyd callback for /data/local/Droidspaces/Net.
#
# A container with Anland enabled makes Droidspaces create
# anland-<hash>.sock when it starts and remove it when it stops; that is the
# lifecycle signal. inotifyd runs this script on every create/delete event,
# the lock debounces bursts, and one reconciliation pass aligns all bridges.
# No periodic polling of `droidspaces show` is needed.
LOCK=/data/local/tmp/.xring-mali-reconcile.lock
HERE=$(cd -- "$(dirname -- "$0")" && pwd -P)
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
sleep 1
sh "$HERE/bridge-reconcile.sh"
