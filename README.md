<p align="center">
  <img src="assets/icon/Janela.png" alt="Janela app icon" width="112">
</p>

<h1 align="center">Janela</h1>

<p align="center">
  A private virtual background for your Mac that follows your local time and weather.
</p>

<p align="center">
  <a href="https://github.com/vuca-dev/janela/releases/latest">
    <img src="https://img.shields.io/badge/Download_for_macOS-2F6FED?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS">
  </a>
</p>

<p align="center">
  <img src="assets/readme/day-cycle.webp" alt="The Atelier scene moving from dawn to night" width="720">
</p>

Janela shows up as a camera in Zoom, Meet, and anything else, and puts you in a scene whose
light and weather match your own.

## Privacy

All video stays on your Mac. The location box searches with Apple Maps as you type, and
weather comes from Open-Meteo using coordinates rounded to about a kilometre. Nothing runs
while no app reads the camera, and the camera light stays off.

## Setup

Needs Apple Silicon and macOS 14 or later. Download Janela, open it, and follow the setup
window: enter your city or postal code, pick a background, and allow the camera.

macOS only lets signed system extensions publish a camera, so Janela publishes through OBS's
open-source extension. Setup downloads OBS if needed, verifies its checksum and Apple
signature, and takes you to the one switch macOS needs you to turn on. OBS doesn't need to be
running afterwards.

## Resource use

Measured on an Apple M1 Pro with 16 GB and macOS 27.0.1, at commit `5e3a312`, on 2026-11-01.

| | |
| --- | --- |
| App size | 39 MB |
| Idle, before first use | 0.1% of one CPU core, 12 MB |
| Live | 13% of one CPU core, 90 MB average, 102 MB peak |
| Frame rate | 29.9 fps |
| Frame time | 20 ms median, 25 ms p95 |

These cover Janela's process over 5 minutes each, with a reader on the virtual camera. Live
figures come from file replay of a drawn 1080p clip at 30 fps, not a real camera. They include
H.264 decode, which took 3.5% of a core on its own, and exclude camera capture. Neural Engine
and GPU load, energy, and other processes weren't measured. After a call, memory stays at about
84 MB until Janela quits.

To reproduce, with OBS's extension on and Janela quit:

    scripts/benchmark.sh

## Build

Needs Apple Silicon, macOS 14 or later, and the Command Line Tools. Xcode isn't required.

    git clone https://github.com/vuca-dev/janela
    cd janela
    ./build_app.sh

The app lands in `build.noindex/Janela.app`. `research/export.py` regenerates the model in
`Resources/` from Robust Video Matting's weights.

## License

The code and the model are GPL-3.0, because Robust Video Matting is GPL-3.0. The GPL does not
cover the images in `scenes/`. OBS is a separate project and its extension is not distributed
here.
