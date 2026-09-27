<p align="center">
  <img src="docs/icon.png" width="128" alt="Fuji Bridge">
</p>

<h1 align="center">Fuji Bridge</h1>

<p align="center">
  Photos from your Fujifilm to your iPhone, iPad and Mac.<br>
  Over USB or Wi-Fi, with the camera woken over Bluetooth.
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6816612097"><b>App Store</b></a> · €2.99
</p>

<br>

<p align="center">
  <img src="docs/mac.webp" width="820" alt="Fuji Bridge on the Mac">
</p>

<p align="center">
  <img src="docs/iphone-import.webp" width="240" alt="Importing">
  &nbsp;
  <img src="docs/iphone-camera.webp" width="240" alt="Picking on the card">
  &nbsp;
  <img src="docs/iphone-viewer.webp" width="240" alt="Full-size viewer">
</p>

<br>

Preview the card, keep what you pick, and see what happened when a transfer is slow. Tested with the X100VI.

**Private.** No account, no analytics, no server. The app talks to your camera and nothing else. Photos stay in Files › Fuji Bridge, or Pictures › Fuji Bridge on the Mac.

**Open source.** The App Store version is how you support the work. If you'd rather not, build it yourself, it's the same app:

```sh
brew install xcodegen
xcodegen generate
open FujiBridge.xcodeproj   # set your team, then Run
```

Notes on the protocol, the tests and the camera's quirks: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Store assets: [docs/STORE.md](docs/STORE.md).

<sub>MIT licensed. Not affiliated with FUJIFILM Corporation.</sub>
