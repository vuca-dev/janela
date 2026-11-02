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
weather comes from Open-Meteo using coordinates rounded to about a kilometre. The camera only
runs while an app reads it, so otherwise its light stays off.

## Setup

Needs Apple Silicon and macOS 14 or later. Tested on macOS 27 so far.

1. Download `Janela.zip` from the [latest release](https://github.com/vuca-dev/janela/releases/latest),
   unzip it, and move Janela to Applications.
2. Open Janela. It isn't notarized by Apple yet, so macOS will block it the first time. Open
   System Settings > Privacy & Security, scroll to Security, click **Open Anyway**, and confirm.
3. Follow the setup window: enter your city or postal code, pick a background, and allow the
   camera.

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

At launch and after wake, Janela runs a low-priority copy of itself that prepares the model and
shaders, then exits. That copy doesn't use the camera. It took 0.3 s and 15 MB when already
prepared, and 5 to 7 s and 26 MB the first time. macOS keeps the result on disk, so a call starts
faster without Janela holding the model. A call that starts meanwhile stops it.

| Model and shaders ready to first matte frame | Before | Now |
| --- | --- | --- |
| Nothing prepared yet | 2.8 s | 2.1 s |
| Prepared | 0.16 s | 0.10 to 0.14 s |

Measured on the same Mac at commit `41ca88e`, five runs each for now and three for before, on
battery, in a fresh process with test frames at 30 fps. These times start when loading starts.
They exclude noticing the reader, which is checked every 0.5 s, and starting the camera, which
weren't measured. To reproduce:

    scripts/first-matte.sh

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
