#!/bin/zsh
# App Preview videos: three real segments per platform (import running, picking on the card, viewer),
# joined by preview.py. Run stage.sh first.
#   tools/store/record.sh [iphone|ipad|mac ...]
source "$(dirname "$0")/lib.sh"
WINREC=$OUT/winrec
[[ -x $WINREC ]] || swiftc -O -o $WINREC $REPO/tools/store/winrec.swift

sim_rec() { # sim_rec DEVICE FILE SECONDS
  xcrun simctl io $1 recordVideo --codec=h264 --force $2 >/dev/null 2>&1 &
  local r=$!; sleep $3; kill -INT $r; wait $r 2>/dev/null
}
sim_set() { # sim_set DEVICE PREFIX
  local d=$1 p=$2
  start_fakecam $(fresh_card $p-video)
  sim_launch $d -BridgeHost 127.0.0.1 -BridgeAutoRun camera -BridgeLatest 4 -BridgeTab imported; sleep 2
  sim_rec $d $VIDEO/$p-import.mp4 11; stop_fakecam
  sim_launch $d -BridgeDemoCard YES; sleep 20
  sim_rec $d $VIDEO/$p-card.mp4 5
  sim_launch $d -BridgeAutoRun viewer -BridgeViewerIndex 6; sleep 5
  sim_rec $d $VIDEO/$p-viewer.mp4 5
}
# ScreenCaptureKit draws a purple "recording" pill where the window buttons are: paste the buttons back
# from a still (the same window at the same size) so the video matches the screenshots.
mac_fix() { # mac_fix NAME
  [[ -f $OUT/lights.png ]] || python3 -c "from PIL import Image; Image.open('$SHOTS/mac-library.png').crop((16,20,184,88)).save('$OUT/lights.png')"
  ffmpeg -loglevel error -y -i $VIDEO/mac-$1.mov -i $OUT/lights.png \
    -filter_complex "[0:v][1:v]overlay=16:20,format=yuv420p" -c:v libx264 -an $VIDEO/mac-$1.mp4
}
mac_set() {
  start_fakecam $(fresh_card mac-video)
  mac_launch -BridgeHost 127.0.0.1 -BridgeAutoRun camera -BridgeLatest 4 -BridgeTab imported; sleep 3
  $WINREC "Fuji Bridge" 10 $VIDEO/mac-import.mov; stop_fakecam
  mac_launch -BridgeDemoCard YES; sleep 20
  $WINREC "Fuji Bridge" 5 $VIDEO/mac-card.mov
  mac_launch -BridgeAutoRun viewer -BridgeViewerIndex 6; sleep 6
  $WINREC "Fuji Bridge" 5 $VIDEO/mac-viewer.mov
  for n in import card viewer; do mac_fix $n; done
  pkill -x FujiBridge; open -n $MAC_APP
}

for t in ${@:-iphone ipad mac}; do
  case $t in
    iphone) sim_set $IPHONE iphone; python3 $REPO/tools/store/preview.py iphone 886 1920 ;;
    ipad) sim_set $IPAD ipad; python3 $REPO/tools/store/preview.py ipad 1200 1600 ;;
    mac) mac_set; python3 $REPO/tools/store/preview.py mac 1920 1080 pad ;;
  esac
done
