# Shared by the store scripts: paths, devices, launching the app in a staged state. Source it, don't run it.
REPO=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$REPO/build/store                   # everything generated lands here (build/ is ignored)
SHOTS=$OUT/shots; VIDEO=$OUT/video; FINAL=$OUT/final
mkdir -p $SHOTS $VIDEO $FINAL
BUNDLE=md.thomas.fujibridge
LIBRARY="$HOME/Pictures/Fuji Bridge"     # the real library the demo photos are copied from
DEMO="$HOME/Pictures/Fuji Bridge Demo"   # what the Mac app shows with -BridgeFolder
MAC_APP=$REPO/build/mac/Build/Products/Debug-maccatalyst/FujiBridge.app
# Simulators by name, so a new Xcode's UUIDs don't matter. iPhone: 1320 × 2868. iPad: 2064 × 2752.
IPHONE=$(xcrun simctl list devices available | grep -m1 "iPhone 17 Pro Max" | grep -oE "[0-9A-F-]{36}")
IPAD=$(xcrun simctl list devices available | grep -m1 "iPad Pro 13-inch" | grep -oE "[0-9A-F-]{36}")
# Catalyst draws iPad-idiom apps at 77 %: 1870 × 1169 points is a 1440 × 900 window, 2880 × 1800 on Retina.
MAC_ARGS=(-BridgeWindowSize 1870x1169 -BridgeFolder "Fuji Bridge Demo" -BridgeDemoCamera X100VI -BridgeRowHeight 270)

# A card for the fake camera with names the app has never imported. Otherwise skip-existing says
# "Up to date" and the progress rail never shows (rehearsals remember what they copied).
fresh_card() {
  local dir=$OUT/card-$1 n=$((1000 + $(date +%s) / 7 % 8000))
  rm -rf $dir; mkdir -p $dir
  while read f; do cp "$LIBRARY/$f" $dir/DSCF$n.JPG; n=$((n + 1)); done < $REPO/tools/store/demo-photos.txt
  echo $dir
}

# The fake camera on 127.0.0.1:55740, slowed so the copy is still running when the shot is taken.
# A leftover one keeps the port and serves the old card: always kill before starting.
start_fakecam() {
  pkill -f tools/fakecam.py; sleep 1
  python3 $REPO/tools/fakecam.py --photos $1 --rate ${RATE:-9} --ok-after 0.5 > $OUT/fakecam.log 2>&1 &
  FAKECAM=$!; sleep 1
}
stop_fakecam() { kill $FAKECAM 2>/dev/null; pkill -f tools/fakecam.py; }

sim_launch() { # sim_launch DEVICE [args...]
  local d=$1; shift
  xcrun simctl terminate $d $BUNDLE 2>/dev/null
  xcrun simctl launch $d $BUNDLE -BridgeDemoCamera X100VI "$@" >/dev/null
}

mac_launch() { # mac_launch [args...]
  pkill -x FujiBridge; sleep 1
  open -n $MAC_APP --args $MAC_ARGS "$@"
}

# Window number of the app's main window, for `screencapture -l` (window only, never the desktop).
mac_window() {
  swift -e 'import CoreGraphics; let l = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String:Any]]; let ws = l.filter { ($0["kCGWindowOwnerName"] as? String) == "Fuji Bridge" && ($0["kCGWindowLayer"] as? Int) == 0 }; let b = ws.max { (($0["kCGWindowBounds"] as! [String:Any])["Height"] as! Double) < (($1["kCGWindowBounds"] as! [String:Any])["Height"] as! Double) }!; print(b["kCGWindowNumber"]!)'
}
