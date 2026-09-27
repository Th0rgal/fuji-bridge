<p align="center">
  <img src="docs/icon.png" width="128" alt="Fuji Bridge">
</p>

<h1 align="center">Fuji Bridge</h1>

<p align="center">
  Photos from your Fujifilm to your iPhone, iPad and Mac.<br>
  Over USB or Wi-Fi, with the camera woken over Bluetooth.
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6816612097"><b>App Store</b></a> · €4.99
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

I love my Fujifilm X100VI, but the official app kept failing me: imports stuck on a spinner, Wi-Fi dropping for no reason. So I made my own. It works over USB or Wi-Fi, lets you look at the card before copying, and tells you why when something is slow.

It's private: no account, no analytics, no server. It only talks to your camera.

It's also open source. Buying it is a nice way to support me, but you are free to build it yourself:

```sh
brew install xcodegen
xcodegen generate
open FujiBridge.xcodeproj   # set your team, then Run
```

Notes on the protocol, the tests and the camera's quirks: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Store assets: [docs/STORE.md](docs/STORE.md).

<sub>MIT licensed. Not affiliated with FUJIFILM Corporation.</sub>
