# Development notes

Native iOS import for a Fujifilm X100 VI. Quiet Ink, the same paper and type as [thomas.md](https://thomas.md) and the OpenHealth iOS app: warm paper, New York titles, SF Mono for every number, a hairline instead of a card, color only when something is actually wrong.

XApp’s copy is hard to debug because a dropped socket looks like a spinner. Fuji Bridge keeps the trace.

## What it talks

The camera is `192.168.0.1`, command port **55740**. The first packet is Fuji’s 82-byte init (`version` `0x8f53e4f2` in front of the GUID), not ISO PTP/IP. After the ack, containers are USB PTP: 12-byte header, little-endian. This follows the published [libfuji](https://github.com/petabyt/libfuji) client (MIT). It is not a decompile of XApp, and it does not include Fujifilm’s code.

Fuji Bridge, compared with the way that session usually dies:

- sends the init again after Init Fail, including on a reconnect
- waits 50 ms before OpenSession, and the transaction id goes back to 1 on every new socket
- polls `0xD212` until `0xDF00` leaves "press OK". That record is not always first; object count is `0xD222`
- sets client state `0xDF01 = 20` (XApp gallery)
- reads `0xD621` for the import handles, and only falls back to `1..count` when that list is empty
- sets `0xD226 = 2` (XApp's ImageForceCompression: 2 original, 1 resized) once for the whole import and back to 0 at the end, like XApp. The file size comes from `GetObjectPropValue` (`0x9803`) of ObjectSize `0xDC04`, as XApp does; ObjectInfo reports about 100 KB while `0xD227` is 0. A body that does not answer ObjectSize gets libfuji's `0xD227 = 1` instead
- for a resized import (menu next to Connect › Size over Wi-Fi, experimental, Original by default), sets `0xD22E` (1 S, 0 XS) and `0xD226 = 1` instead, like XApp's Resize setting, with `0xD227 = 1` so ObjectInfo gives the resized length. A file already here under the same name counts as imported
- gives each read 30 s once files are moving (XApp's GET_OBJECT_TIMEOUT), so a slow window is not cut and asked again
- reads `GetPartialObject` (`0x101B`) in 1 MB pieces and resumes from the last offset. `compressed_size` is the unaligned word at offset 13. The filename is a PTP string at offset 52 (length byte, then UTF-16), not raw ASCII.

## Wi-Fi reliability and what the report measures

- **Streaming and resume.** Each file is written as it arrives to a hidden `.<name>.<size>.part` next to the photo, then moved into place. A run that dies (Wi-Fi lost, app suspended, camera off) keeps what it got, and the next import asks the camera only for the rest, from a 512-byte boundary. The size in the name keeps a resized copy and an original apart.
- **Reconnects.** A dead window reopens the session up to four times (0, 1, 2, 4 s apart). Before each retry the app checks the phone still has an address on the camera's network and joins it again if iOS fell back to the home Wi-Fi. A file is given up only after five stalls in a row with no window getting through.
- **Leaving the screen.** iOS will not join a network for a background app. The join waits for the app to come back, and an import cut short by leaving the screen starts again (as a resume) when it does, within 10 minutes.
- **Per window.** Every GetPartialObject line records the first-byte latency (the camera) and, over TCP, how many receives the window came in and the longest silence once bytes were flowing (the radio).
- **TRANSFER** in the report: wire vs effective MB/s, per-window p10/p50/p90, first byte and silence percentiles, reconnects and their cost, bytes asked twice, bytes resumed from disk, and MB/s per 5 s slice. The same numbers are in the JSON (`transfer`).
- **End of file and whole JPEGs.** While resizing, an X100VI still announces the original's length (9.5 MB for a 3.8 MB file) and answers past the real end with the same last 257 bytes. The same short answer twice at the same offset is taken as the end of the file (build 202609271214 asked 1,510 times instead). For resized files the size is first asked as `0xD802`, as XApp does. Every saved `.jpg` must start with `FF D8` and end with `FF D9`; one that does not is not kept, and a broken copy already on disk is fetched again instead of counting as "already here".
- **Samples.** Every 5 s the trace gets a `sample` line: MB/s over those 5 s, phone battery, thermal state, Low Power Mode, on screen or not, and the phase. The import card draws the same speed live, one point a second. The camera's own BatteryLevel (PTP `0x5001`) is read once after the handshake.
- **Bluetooth during transfers** (Diagnostics switch, off by default): drop the Bluetooth link once the Wi-Fi session is open. Each report says which way the run went, so an import with and without it can be compared on the same phone.
- **Speed test** (Diagnostics): reads the newest photo with 256 KB, 512 KB, 1 MB, 2 MB and 4 MB windows, up to 8 MB each, saves nothing, and switches imports to the fastest window if it beats the current one by 10%. "Back to 1 MB" undoes it.

## Two modes

**Virtual body.** A body in the process. Turn on the stalls (flaky init, OK prompt, mid-file TCP death, 100 KB size lie, skipped settle) and replay XApp next to Fuji Bridge. Compare runs each fault alone.

**Camera Wi-Fi.** Join `FUJIFILM-xxxx` in Settings (5 GHz is the same protocol, just faster), allow Local Network, come back, import. Files land in the app’s documents folder. OK is on the camera.

## Build

From this repository:

```sh
brew install xcodegen
xcodegen generate
open FujiBridge.xcodeproj
```

Team is set to the same development team as OpenHealth. Run `FujiBridgeTests` for the session: init retry, stall resume at transaction id 1, size lie, D621 handles, partial offsets, the event layout, PTP-string filenames, and a live list that skips a dead handle. Those tests run against the in-process body. They do not join a camera.

The phone has to be on the camera’s network. Fuji Bridge cannot join that SSID for you without the Hotspot Configuration entitlement.

## Diagnostics

Every run writes three files to `Documents/Diagnostics` (visible in the Files app, shareable from the Diagnostics screen):

- `<stamp>.jsonl`: one trace line per row, written as it happens, so a hang or a kill still leaves it
- `<stamp>.txt`: the report. Result, findings, a phase table (connect, init, OK wait, setup, per-file props, partial reads, save, reconnects) with n/total/avg/p50/p95/max, per-file speed and overhead, the slowest exchanges, then the full trace
- `<stamp>.json`: the same report plus the trace, for scripts

Times are real, on the monotonic clock. Each partial read records time to first byte (the body's latency) apart from the transfer itself (the Wi-Fi). Socket state changes, path changes, timeouts, app backgrounding and memory warnings are in the trace too. The same lines go to the unified log under subsystem `md.thomas.fujibridge`.

The socket has deadlines (8 s connect, 10 s without progress), so a dead Wi-Fi turns into a reconnect from the last offset instead of a hang. The screen stays on during an import. A file already in `Documents/Fuji Bridge` with the same name and size is not copied again.

## Rehearsing without the camera

The simulator shares the Mac's network, so a fake body on the Mac is enough:

```sh
python3 tools/fakecam.py --flaky --lie --stall 12 --rate 8 --dump /tmp/served
xcrun simctl launch booted md.thomas.fujibridge -BridgeHost 127.0.0.1 -BridgeAutoRun camera
```

`-BridgeAutoRun` only exists in Debug builds. The Body field on the Camera Wi-Fi tab sets the host by hand.

## TestFlight

```sh
scripts/testflight.sh --archive   # signed archive only
scripts/testflight.sh             # archive and upload
```

Bundle id `md.thomas.fujibridge`, team BQ6Z84B8L5. The build number is a timestamp. The app record has to exist in App Store Connect first.

## Mac

The Mac app is the same target built with Mac Catalyst ("Optimize for Mac"): no second UI, no `#if` in the app code. Where the platforms really differ it is decided at runtime from one shared code path (`ProcessInfo.isMacCatalystApp`): Finder vs Files for the photo folder, the device name in reports, and whether a hidden window means suspension. Sleep is held off with `ProcessInfo.beginActivity` on both.

The Mac build is sandboxed with outgoing network only (`FujiBridge-mac.entitlements`); Debug may also listen, for the loopback camera in `Tests/LoopbackTests.swift`. When the host is 192.168.0.1 the socket is pinned to Wi-Fi, so a Mac on Ethernet to a home router at the same address still reaches the camera.

```sh
xcodebuild -scheme FujiBridge -destination 'platform=macOS,variant=Mac Catalyst' test
```

Files land in `~/Library/Containers/md.thomas.fujibridge/Data/Documents/{Fuji Bridge,Diagnostics}`.

## Measured on the body (USB)

`tools/usbprobe.swift` talks raw PTP to a body on USB through ImageCaptureCore, read only. X100VI, firmware 1.32, 26 Sep 2026:

- The card serves about 27 MB/s. Per-command cost is ~3 ms, GetObjectInfo ~1.6 ms. Over Wi-Fi the radio is the limit, not the card.
- GetPartialObject honours windows up to 8 MB over USB. Past 1 MB, bigger windows only gain ~5% (26 → 27.7 MB/s), so Fuji Bridge keeps 1 MB.
- **Offset alignment matters.** 1 MB from a 512-byte-aligned offset takes 38–40 ms. From an even, unaligned one it takes ~95 ms, and from an odd one ~1.5 s (40× slower), cold or warm. Fuji Bridge drops any tail past the last 512-byte boundary before its next read.
- Over USB the Fuji Wi-Fi props (D212, D222, D620/D621, DF00–DF28, D226/D227) answer 0x200A. The Wi-Fi handshake can only be tested over Wi-Fi.
- USB ObjectInfo is standard PTP (size at offset 8). libfuji documents the Wi-Fi record with the size at offset 13. The trace keeps the raw head of every ObjectInfo so the first Wi-Fi run confirms it.

## USB import

When a body is plugged in, Fuji Bridge imports over the cable; otherwise over Wi-Fi. `USBLink` is a `ByteLink` like `TCPLink`: it turns each PTP container the importer writes into one ImageCaptureCore transaction (`requestSendPTPCommand`) and hands the data phase and response back as bytes. The file loop (1 MB windows, 512-byte realignment, resume, skip what is already here, save, progress, trace) is the same code for both. Only the start differs: USB mode is plain PTP, so there is no Fuji init, no OK on the camera, and the list comes from GetObjectHandles with the standard ObjectInfo layout. Folders are skipped.

Measured on the Mac with the X100VI: about 22 MB/s end to end. On the first connection after the cable goes in, ImageCaptureCore indexes the card (about 32 s for 1771 files), and copying alongside it runs at a third of that speed, so Fuji Bridge waits for the index (up to 60 s). `Tests/USBTests.swift` runs the USB path against a fake body on both platforms. The same file is meant to work on an iPhone or iPad with USB-C; that has not been tried on a device yet.

Photos land in `~/Pictures/Fuji Bridge` on the Mac and in Files › Fuji Bridge on the phone. The home screen offers the newest 25, the newest 100, or the whole card; what is already there is never copied again.

Debug launch arguments: `-BridgeAutoRun usb|wifi|camera|virtual`, `-BridgeLatest N`, `-BridgeHost 127.0.0.1`.

## Look before importing

"Browse the camera" lists the newest frames in scope without copying anything: ObjectInfo, the body's own thumbnail (GetThumb, 160x120, ~5 ms over USB) and the first 4 KB of each file for its EXIF orientation, since the thumbnail is never rotated. It is the importer again with `RunOptions.preview` set, so it works over USB and Wi-Fi alike. Pick frames and "Import N selected" copies only those (`RunOptions.only`). "View full size" copies one frame into Caches/Preview and opens it in Quick Look; the X100VI embeds no bigger preview than 160x120, so full size means the whole file.

Wide windows (Mac, iPad) put the controls on the left and the photos in a grid filling the rest; a phone gets one column. Thumbnails of imported files are decoded in parallel and cached in Caches/Thumbs.

## Bluetooth: waking the camera's Wi-Fi

No USB cable: Fuji Bridge can find the body over Bluetooth, ask it to start its access point, and join it. `FujiBridge/FujiBluetooth.swift`:

1. Scan for manufacturer data with company id `0x04D8`. A bonded X100VI (firmware 1.32) advertises service `804daa8e…` plus a short serial, e.g. `1D7B8`.
2. Connect, then identify: secure bodies (X100VI from firmware 1.31, profile `ad14d4` in fffw) read STATUS `f557d96b…` and write it back with its last byte set to `0x20`; older bodies write the 4-byte token from the pairing advert to `aba356eb…`. Then write the client name to `85b9163e…` (CONNECTED_DEVICE_NAME). XApp sends the same name as the device name in the Wi-Fi init packet, with the same version and GUID as ours.
3. Read the SSID (`bf6dc9cf…`), write the function code `03 00` to `600655e6…` (FUNCTION_LAUNCH_REQUEST; XApp's codes: 1 ImportImage, 3 InCameraViewing, 4 RemoteShooting, 5 UpdateFirmware; XApp sends 3 to import, and `04 00`, which libfuji uses, starts a remote-shooting session that ignores an import client's init), read the password (`e809256a…`), and wait for indication `a68e3f66…`: `01` means up, `00` means busy.
4. iPhone/iPad: `NEHotspotConfiguration` (hidden, join once) makes iOS ask to join. Mac: no app may join a network there, so Fuji Bridge shows the network and a copy button and waits up to 2 minutes.

On an iPhone already paired with XApp, the bond belongs to iOS, so Fuji Bridge uses it without pairing again. A Mac has no bond: connecting would need the camera's pairing registration, which may make the Mac the camera's pairing destination instead of the phone.

Photos do not go over Bluetooth. The body has no image service there (the only file service is a ~33 KB settings backup), and BLE would take minutes per 25 MB JPEG.

Sources: gkoh/furble (pairing), petabyt/libfuji `lib/bluetooth.c` (Wi-Fi wake), tiredboffin/fffw (GATT tables per model and firmware), missuo/Koko (UUIDs checked against XApp 2.7.5). `Tests/BluetoothTests.swift` runs the handshake against a fake body.
