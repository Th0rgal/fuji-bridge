# Store assets

How the App Store screenshots, the App Previews, the README images and the icon are made, so they can be
redone in one pass after a UI change. Everything is scripted in `tools/store/`; generated files go to
`build/store/` (ignored by git).

```sh
tools/store/stage.sh                 # build Debug, boot simulators, load the demo library everywhere
tools/store/capture.sh               # raw screenshots → build/store/shots/
python3 tools/store/compose.py       # framed + captioned → build/store/final/{iphone,ipad,mac}-N.png
tools/store/record.sh                # App Previews → build/store/final/{iphone,ipad,mac}-preview.mp4
python3 tools/store/readme.py        # docs/icon.png and docs/*.webp for the README
```

Each script takes a subset: `capture.sh mac`, `record.sh iphone ipad`. A full run takes about ten minutes.

## Look

One palette for the icon, the store frames and the README, taken from the icon (`tools/icon.swift`):

| Role | Color |
|---|---|
| Gold, top of gradient | `#C9A04C` |
| Gold, bottom of gradient | `#A87E32` |
| Ink: mountain, captions | `#1B1510` |
| Cream: snow cap | `#F4E9CF` |
| Subtitle | `#3A2C18` |
| Shadow under the capture | `#3A280C`, alpha 110/255, blur 36 px, offset 18 px down |
| Hairline around the capture | `#2A2016`, 3 px |
| Letterbox in the Mac preview | `#16120E` (the app's dark) |

Type: captions in **New York** at weight 640 (optical size 64), subtitles in **SF Pro** at weight 480,
both centered. Set every variable axis, or New York comes out in its thin display cut. The app itself is
shown in dark mode, status bar at 9:41 with full battery, Wi-Fi and four bars.

Icon: a flat Mount Fuji, ink on the gold gradient, with a cream cap ending in three scallops that start
exactly on the flanks. No sun, no texture, no Fujifilm lettering (trademark). 1024 × 1024, opaque.
`swift tools/icon.swift FujiBridge/Assets.xcassets/AppIcon.appiconset/AppIcon.png` redraws it.

## Sizes

| Asset | Size | Source |
|---|---|---|
| iPhone screenshots | 1284 × 2778 (6.5" slot, used for every iPhone) | iPhone 17 Pro Max simulator, 1320 × 2868 |
| iPad screenshots | 2064 × 2752 (13") | iPad Pro 13-inch simulator, same size |
| Mac screenshots | 2880 × 1800 | the app window pinned at 1440 × 900 points |
| iPhone preview | 886 × 1920, 15–30 s | simulator recording, cropped to fill |
| iPad preview | 1200 × 1600 | simulator recording |
| Mac preview | 1920 × 1080 | window recording, letterboxed |
| README | icon 256 px, Mac 1600 px wide, iPhone 520 px wide, WebP | the raw screenshots, no captions |

Previews are H.264 High, 30 fps, 10 Mb/s, with a silent stereo AAC track, and cross-fade 0.5 s between
three segments: an import running, picking on the card, the viewer.

## Captions

In `tools/store/compose.py`, in App Store order (the first three show on the install sheet):

1. **Import from your Fujifilm in one tap** · USB or Wi-Fi, woken over Bluetooth (one *click* on the Mac)
2. **Preview the card, keep what you pick** · Browse before anything is copied
3. **Your photos, beautifully laid out** · Straight into Files, newest first (Mac: *straight into Pictures* · A calm grid that makes room for the images)
4. **Every frame at full resolution** · Swipe, zoom, share (Mac: Arrow keys to move, Space to close)
5. Mac only: **Every import, measured and explained** · Share a report when something goes wrong

## Staging

The shots are real captures of the Debug app, put in each state by launch arguments (Debug builds only):

| Argument | Effect |
|---|---|
| `-BridgeDemoCamera X100VI` | the camera card shows a body paired over Bluetooth |
| `-BridgeDemoCard YES` | "On the camera" filled from the library, four new frames selected |
| `-BridgeAutoRun viewer -BridgeViewerIndex 6` | opens the viewer on the 7th photo (the chestnuts) |
| `-BridgeHost 127.0.0.1 -BridgeAutoRun camera -BridgeLatest 4` | a real import from `tools/fakecam.py` |
| `-BridgeShowDiagnostics YES` | opens Diagnostics (Mac) |
| `-BridgeFolder "Fuji Bridge Demo"` | the Mac shows `~/Pictures/Fuji Bridge Demo` instead of the real library |
| `-BridgeWindowSize 1870x1169` | pins the Mac window size |
| `-BridgeRowHeight 270` | bigger rows so 26 photos fill the Mac window |

**Photos.** `tools/store/demo-photos.txt` lists 26 frames from the real library with **no people in them**
(landscapes, the plane window, cows, chestnuts, blackberries, the lasagna). Check any new frame before
adding it: these images are public. They are copied, never moved: to the simulators' `Documents/Fuji Bridge`
and to `~/Pictures/Fuji Bridge Demo`.

**The import shot** uses the fake camera, not the X100VI: `fakecam.py --rate 9` serves copies of the demo
photos slowly enough to catch the progress rail. Each run gets new `DSCFnnnn` names (`fresh_card`), because
the app skips files a previous rehearsal already copied and would only say "Up to date".

## Pitfalls met the first time

- **Catalyst scales iPad-idiom apps to 77 %.** A 1440 × 900 window needs `-BridgeWindowSize 1870x1169`;
  the capture comes out 2878 × 1800 and `compose.py` fits it to 2880 × 1800.
- **Capture the window, never the screen.** `screencapture -l <window>` for stills, and `winrec.swift`
  (ScreenCaptureKit, one window) for video. `screencapture -V -R` records the wrong region and the cursor.
- **ScreenCaptureKit shows a purple recording pill** where the window buttons are. `record.sh` pastes the
  buttons back from a still of the same window.
- **A stale `fakecam.py` holds port 55740** and serves the previous card. `start_fakecam` kills it first.
- **Demo card thumbnails are slow**: 26 full-size JPEGs. Wait 20 s before shooting "On the camera".
- **Hover labels.** On the Mac, a pointer resting over the grid shows a file name tooltip in the video. Park
  the pointer outside the window before recording.

## Uploading to App Store Connect

- **Order.** Screenshots dropped together land in a random order. Upload them one at a time, in order, and
  dismiss the "App Previews, Screenshots, and Localizations" dialog after each one.
- **Slots.** iOS: the iPhone tab takes the 6.5" set (Apple scales it to every iPhone), the iPad tab takes the
  13" set. The macOS version has its own page with its own set.
- **App Review information is saved as one block**: name, email and phone together, or none of them. A
  missing phone blocks the whole page's Save, including the media.
- **Listing text** lives in `tools/store/listing/`: promotional text, keywords, the iOS and Mac
  descriptions, the review notes, and `app-information.md` with every other setting (category, age rating,
  privacy, price).
- **Builds**: `scripts/testflight.sh` archives and uploads iOS and Mac; the version in `project.yml` must
  match the App Store version (1.0 for the first release).
