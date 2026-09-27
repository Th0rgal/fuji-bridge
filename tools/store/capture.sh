#!/bin/zsh
# Raw screenshots at the exact store sizes into build/store/shots. Run stage.sh first.
#   tools/store/capture.sh [iphone|ipad|mac ...]      (default: all three)
source "$(dirname "$0")/lib.sh"

sim_shot() { # sim_shot DEVICE NAME WAIT [args...]
  local d=$1 n=$2 w=$3; shift 3
  sim_launch $d "$@"; sleep $w
  xcrun simctl io $d screenshot --type=png $SHOTS/$n.png >/dev/null 2>&1 && echo "$n"
}
sim_set() { # sim_set DEVICE PREFIX
  local d=$1 p=$2
  sim_shot $d $p-library 6
  sim_shot $d $p-camera 20 -BridgeDemoCard YES           # thumbnails of 26 full JPEGs take a while
  sim_shot $d $p-viewer 6 -BridgeAutoRun viewer -BridgeViewerIndex 6   # index 6: the chestnuts
  start_fakecam $(fresh_card $p)
  sim_shot $d $p-import 9 -BridgeHost 127.0.0.1 -BridgeAutoRun camera -BridgeLatest 4
  stop_fakecam
}
mac_shot() { # mac_shot NAME WAIT [args...]
  local n=$1 w=$2; shift 2
  mac_launch "$@"; sleep $w
  screencapture -x -o -l $(mac_window) $SHOTS/$n.png && echo "$n"
}
mac_set() {
  mac_shot mac-library 7
  mac_shot mac-camera 20 -BridgeDemoCard YES
  mac_shot mac-viewer 7 -BridgeAutoRun viewer -BridgeViewerIndex 6
  start_fakecam $(fresh_card mac)
  mac_shot mac-import 10 -BridgeHost 127.0.0.1 -BridgeAutoRun camera -BridgeLatest 6
  sleep 25; stop_fakecam                                  # let it finish: Diagnostics shows this run
  mac_shot mac-diagnostics 7 -BridgeShowDiagnostics YES
  pkill -x FujiBridge; open -n $MAC_APP                   # back to the real library
}

for t in ${@:-iphone ipad mac}; do
  case $t in
    iphone) sim_set $IPHONE iphone ;;
    ipad) sim_set $IPAD ipad ;;
    mac) mac_set ;;
  esac
done
