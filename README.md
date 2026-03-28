# DLScope

A native iOS 6 app for viewing live video from the MaiKeLong W05A WiFi digital microscope on a jailbroken iPhone 4.

## Features

- Live MJPEG video stream over WiFi (UDP)
- Portrait display with full-width viewfinder (no black bars, no cropping)
- Capture frames to Camera Roll with shutter button or hardware snap button
- Camera-style UI with thumbnail preview
- Dirty frame skipping for clean video
- Eager JPEG decompression on background thread for smooth rendering

## Requirements

- Jailbroken iPhone 4 running iOS 6
- [Theos](https://theos.dev) build system with iOS 6.1 SDK
- MaiKeLong W05A WiFi microscope (firmware 6.000.076)

## Building

```bash
cd DLScope
export THEOS=~/theos
make clean && make package
```

The `.deb` package will be in `DLScope/packages/`.

## Installing

### From Cydia

Add the repository `https://abadari3.github.io/DLScope-W05A/` as a Cydia source, then install DLScope.

### Manual

Copy the `.deb` to your device and install with `dpkg -i`.

## Usage

1. Connect your iPhone to the microscope's WiFi AP (`Cam-*` or `MKL_WIFI_*`)
2. Open DLScope
3. The live feed appears once connected
4. Tap the shutter button to capture a frame to Camera Roll

## Project Structure

```
DLScope/          iOS app source (Objective-C, MRC)
  DLSMicroscope   UDP protocol, frame reassembly, JPEG decode
  DLSViewController  Camera-style UI
  Resources/      App icons, Info.plist
  DEBIAN/         Package scripts
docs/             Cydia repository (GitHub Pages)
viewer.py         Reference Python implementation (OpenCV)
protocol.md       Reverse-engineered W05A protocol documentation
spec.md           Original project specification
```

## Protocol

See [protocol.md](protocol.md) for the full reverse-engineered W05A protocol documentation.
