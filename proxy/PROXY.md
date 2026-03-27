# W05A Microscope Proxy

## Problem

The W05A microscope creates its own WiFi AP. Connecting a Mac to it means losing internet access. We want both: microscope stream and internet.

## Solution

A Raspberry Pi Zero 2W sits between the microscope and the Mac:

```
[ W05A Microscope 192.168.1.1 ]
        |
        |  WiFi (UDP stream packets)
        v
[ Pi Zero 2W ]
  wlan0: 192.168.1.x  (microscope AP)
  usb0:  192.168.2.2  (USB Ethernet to Mac)
        |
        |  USB Ethernet (complete JPEG frames)
        v
[ Mac 192.168.2.1 ]
  viewer.py --proxy
```

The Pi connects to the microscope's WiFi, handles the protocol (registration, stream reception), reassembles fragmented JPEG frames from UDP packets, and forwards complete JPEGs to the Mac over USB Ethernet. The Mac's WiFi stays free for internet.

## How It Works

### Registration

The proxy sends three commands to the microscope on startup:
- CMD 1 (port 10005): device info request
- CMD 2 (port 10005): license info request
- CMD 4 (port 10006): register stream listener on port 10900

All commands use the `eeffeeff` magic header. The microscope then begins streaming JPEG fragments to the registered port.

### Frame Reassembly

The microscope splits each JPEG frame across ~10-20 UDP packets (max ~1472 bytes each). Each packet has a 16-byte header:

```
byte 0:    fixed 0x01
byte 1:    sequence counter (8-bit)
byte 2:    frame counter (8-bit, identifies which frame)
byte 3:    last-packet flag (1 = final packet of frame)
bytes 4-5: packet index within frame (LE uint16)
bytes 16+: JPEG fragment
```

The proxy accumulates payload bytes for each frame counter value. When `last_flag == 1`, the buffer contains a complete JPEG. If the buffer starts with `ff d8` (JPEG SOI marker), it's forwarded to the Mac as a single UDP packet. Otherwise it's dropped.

When a new frame counter appears before the previous frame completed, the incomplete frame is silently dropped.

### Forwarding

Complete JPEG frames are sent as single UDP datagrams to the Mac's IP on port 10900. The viewer receives them with a simple `recvfrom()` — no reassembly needed on the Mac side.

### Timeout Recovery

If no packets arrive for 1 second, the proxy re-sends the registration commands. This handles cases where the microscope drops the session.

## Viewer Integration

The viewer supports a `--proxy` flag:

```bash
# Direct connection (Mac WiFi on microscope AP)
python viewer.py

# Through the Pi proxy (Mac WiFi free for internet)
python viewer.py --proxy
```

In proxy mode, the viewer skips registration and heartbeat handling. It just binds port 10900 and decodes incoming JPEG frames.

## Known Limitations

- The Pi Zero 2W's BCM43430 WiFi chip experiences significant packet loss (~70%) with the microscope's bursty UDP stream. This results in lower fps (5-11 vs 13 direct) and dropped frames. The proxy handles this gracefully — it only forwards complete, valid JPEGs — but the frame rate suffers.
- No heartbeat handling. The microscope sends heartbeat packets (CMD 9, port 10007) but we haven't confirmed they're necessary for maintaining the stream.

## Network Layout

| Device | Interface | IP | Role |
|--------|-----------|-----|------|
| Microscope | WiFi AP | 192.168.1.1 | Stream source |
| Pi Zero 2W | wlan0 | 192.168.1.100 (DHCP) | Proxy |
| Pi Zero 2W | usb0 | 192.168.2.2 | USB Ethernet to Mac |
| Mac | USB Ethernet | 192.168.2.1 | Viewer |
