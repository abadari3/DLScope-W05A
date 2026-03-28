# DLScope — W05A Microscope Viewer for iPhone 4

## Overview

A native iOS app that connects to a MaiKeLong W05A WiFi digital microscope and
displays its live video feed fullscreen on a jailbroken iPhone 4 running iOS 6.
No Mac, no computer, no internet required after installation.

Distributed via a self-hosted Cydia repository on GitHub Pages.

---

## Hardware

| Device | Details |
|---|---|
| Microscope | MaiKeLong W05A, BK7231U SoC |
| Phone | iPhone 4, iOS 6.1.3, jailbroken |
| Network | Microscope's own WiFi AP (open, SSID `Cam-*` or `MKL_WIFI_*`) |
| IP | Microscope at `192.168.1.1`, phone gets DHCP address |

---

## Protocol

Reverse-engineered and implemented in `viewer.py`. All communication is UDP
with a 4-byte magic prefix `eeffeeff`.

### Ports

| Port | Direction | Purpose |
|---|---|---|
| 10005 | Phone -> Microscope | Command channel |
| 10006 | Phone -> Microscope | Stream registration |
| 10007 | Microscope -> Phone | Heartbeat (must ACK with empty UDP) |
| 10900 | Microscope -> Phone | JPEG stream data |

### Command format

```
Offset  Size  Field
0       4     Magic: ee ff ee ff
4       2     Sequence number (LE uint16)
6       2     Command ID (LE uint16)
8       4     Parameter (LE uint32)
```

Built by: `struct.pack("<4sHHI", b"\xee\xff\xee\xff", seq, cmd, param)`

### Startup sequence

1. **CMD 1** (device info): send to port 10005
   - `pack("<4sHHI", MAGIC, 0, 1, 1)`
   - Response contains manufacturer, model, firmware, device_id at known offsets

2. **CMD 2** (license/auth): send to port 10005
   - `pack("<4sHHI", MAGIC, 1, 2, 1)`

3. **CMD 4** (register stream): send to port 10006
   - `pack("<4sHHHHI", MAGIC, 2, 4, 1, 2, 10900)`
   - Tells microscope to start sending JPEG stream to our port 10900

### Heartbeat

- Microscope sends `eeffeeff` CMD 9 packets to port 10007 roughly every second
- Client must reply with an empty UDP packet (`b""`) to `192.168.1.1:10007`
- Without ACKs, the microscope throttles or drops the stream
- Byte 8 of heartbeat packet = hardware snap button state (1 = pressed)

### Stream packets (port 10900)

Each UDP packet has a 16-byte header followed by a JPEG fragment:

```
Offset  Size  Field
0       1     Fixed: 0x01
1       1     Sequence counter (8-bit, wraps at 256)
2       1     Frame counter (8-bit, wraps at 256)
3       1     Last-packet flag (1 = final packet of this frame)
4       2     Packet index within frame (LE uint16, 1-based)
6       4     (unused/reserved)
10      2     Device ID (LE uint16, typically 0x86cd)
12      2     Width (LE uint16)
14      2     Height (LE uint16)
16+     var   JPEG fragment
```

### Frame reassembly

1. Accumulate payloads (bytes 16+) for packets sharing the same frame counter
2. When `last_flag == 1`, the frame is complete
3. Validate: first two bytes of assembled buffer must be `ff d8` (JPEG SOI)
4. If a new frame counter appears before the previous frame's last packet,
   discard the incomplete frame and start fresh
5. Track packet index for gap detection (dirty frame detection)

### Stream specs

- Resolution: 640x480
- Codec: JPEG (standard, decodable by any JPEG library)
- Framerate: ~15-25 fps depending on scene complexity
- Typical frame size: 20-60 KB

---

## App Architecture

### Target

- Platform: iOS 6.0+
- Architecture: armv7
- Language: Objective-C
- Build system: Theos (iphone/application template)
- Signing: `ldid` (self-signed for jailbroken device)

### Structure

Single-view application. No navigation, no settings, no UI chrome.

```
DLScope/
  Makefile
  control                  # Debian package metadata
  DLScope-Info.plist       # App plist (landscape, fullscreen, no status bar)
  main.m                   # UIApplicationMain entry
  DLSAppDelegate.h/.m      # Sets up fullscreen window + root view controller
  DLSViewController.h/.m   # Landscape fullscreen UIImageView
  DLSMicroscope.h/.m       # Protocol layer: connect, heartbeat, stream receive
```

### Components

**DLSAppDelegate**
- Creates UIWindow, sets DLSViewController as root
- Hides status bar

**DLSViewController**
- Single fullscreen UIImageView, landscape orientation
- Receives decoded UIImage from DLSMicroscope, displays on main thread
- Black background, no other UI elements

**DLSMicroscope**
- Manages all UDP communication on a background thread/queue
- BSD sockets (POSIX — no third-party dependencies)
- On init: sends CMD 1, CMD 2, CMD 4 (startup sequence)
- Heartbeat: background thread listening on port 10007, ACKs with empty UDP
- Stream receiver: binds port 10900, receives packets, reassembles frames
- On complete frame: decode JPEG via ImageIO (`CGImageSourceCreateWithData`),
  wrap as UIImage, dispatch to main thread via delegate/block callback
- Handles timeout/re-registration if stream stops

### Frame decode path

```
UDP packet (port 10900)
  -> accumulate payload in NSMutableData (keyed by frame counter)
  -> on last_flag: validate ff d8 header
  -> CGImageSourceCreateWithData (ImageIO framework — available on iOS 6)
  -> CGImageSourceCreateImageAtIndex
  -> [UIImage imageWithCGImage:]
  -> dispatch_async(dispatch_get_main_queue(), ^{ imageView.image = img; })
```

### Dependencies

None beyond system frameworks:
- UIKit
- Foundation
- CoreGraphics
- ImageIO (for JPEG decoding)
- System POSIX sockets (sys/socket.h, netinet/in.h, arpa/inet.h)

---

## Build & Development

### Prerequisites

- Mac (Apple Silicon or Intel)
- Theos installed (`$THEOS` set)
- iOS 6.1 SDK (extracted from Xcode 4.x)
- Toolchain capable of producing armv7 binaries

### Build

```bash
cd DLScope
make package FINALPACKAGE=1
# produces .theos/_/debs/com.abadari3.dlscope_1.0-1_iphoneos-arm.deb
```

### Deploy (direct)

```bash
scp .theos/_/debs/*.deb root@<iphone-ip>:/tmp/
ssh root@<iphone-ip> dpkg -i /tmp/com.abadari3.dlscope_*.deb
```

### Theos project files

**Makefile**
```makefile
ARCHS = armv7
TARGET = iphone:6.1:6.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = DLScope
DLScope_FILES = main.m DLSAppDelegate.m DLSViewController.m DLSMicroscope.m
DLScope_FRAMEWORKS = UIKit CoreGraphics ImageIO Foundation

include $(THEOS_MAKE_PATH)/application.mk
```

**control**
```
Package: com.abadari3.dlscope
Name: DLScope
Depends: firmware (>= 6.0)
Version: 1.0
Architecture: iphoneos-arm
Description: W05A WiFi Microscope Viewer
Maintainer: Ananda Badari
Author: Ananda Badari
Section: Multimedia
```

---

## Distribution — Cydia Repository

Self-hosted Cydia repo on GitHub Pages.

### Repository: `abadari3/dlscope-repo`

```
dlscope-repo/
  Packages.gz          # Package index (generated)
  Release              # Repo metadata
  debs/
    com.abadari3.dlscope_1.0-1_iphoneos-arm.deb
```

### Release file

```
Archive: stable
Component: main
Origin: Ananda Badari
Label: DLScope Repo
Architecture: iphoneos-arm
```

### Build repo index

```bash
dpkg-scanpackages debs/ /dev/null | gzip -9c > Packages.gz
```

### GitHub Pages

- Enable Pages on `abadari3/dlscope-repo` (main branch, root)
- Cydia source URL: `https://abadari3.github.io/dlscope-repo`

### Install on iPhone 4

1. Connect iPhone to any WiFi with internet (for Cydia)
2. Cydia -> Manage -> Sources -> Edit -> Add
3. Enter: `https://abadari3.github.io/dlscope-repo`
4. Search "DLScope" -> Install
5. Switch WiFi to microscope AP
6. Launch DLScope

---

## Success Criteria

- [ ] iPhone 4 shows live 640x480 video from microscope
- [ ] No Mac/computer/internet required during use
- [ ] Workflow: connect to microscope WiFi -> launch app -> see video
- [ ] Fullscreen, landscape, no UI chrome
- [ ] Installable from Cydia via self-hosted repo
- [ ] Hardware snap button on microscope triggers on-device screenshot

---

## Risk: Theos Toolchain

The primary risk is getting Theos to produce working armv7 binaries on a
modern Mac. Key issues:

1. **iOS 6 SDK** — available from https://github.com/growtopiajaw/iPhoneOS-SDK
   (clone/download the iPhoneOS6.1.sdk directory into `$THEOS/sdks/`)
2. **armv7 support** — modern Apple clang dropped armv7; may need Theos's
   own toolchain or an older clang
3. **Apple Silicon** — cross-compiling armv7 from arm64 Mac adds a layer

If Theos proves unworkable, fallback options:
- Xcode 4.x in a macOS VM (Mountain Lion / Mavericks)
- Cross-compile with a manually configured older clang
- Build directly on the iPhone (slow but possible with on-device toolchain)

---

## Reference Implementation

`viewer.py` in this repo is the complete, tested Python implementation of the
protocol. Every packet format, command sequence, and reassembly detail in this
spec was verified against that code and real microscope traffic.
