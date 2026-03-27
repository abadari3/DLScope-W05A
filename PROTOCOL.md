# W05A WiFi Microscope Protocol

Reverse-engineered protocol for the MaiKeLong W05A WiFi digital microscope
(firmware 6.000.076, device ID `MKL_WIFI_0A86CD`).

## Network

The microscope creates an open WiFi AP (SSID `Cam-*` or `MKL_WIFI_*`, no password).
The microscope IP is `192.168.1.1`. All communication is UDP.

| Port  | Direction      | Purpose                       |
|-------|----------------|-------------------------------|
| 10005 | client → device | Command channel               |
| 10006 | client → device | Stream registration            |
| 10007 | device → client | Heartbeat (client ACKs empty) |
| 10900 | device → client | JPEG stream (configurable)     |

## Command Format

All commands use a 4-byte magic header `ee ff ee ff` followed by variable-length data.

### Registration (12–16 bytes)

```
Offset  Size  Field
0       4     Magic: ee ff ee ff
4       2     Sequence number (LE uint16)
6       2     Command ID (LE uint16)
8       4     Parameter (LE uint32)
12      4     [CMD 4 only] Extra parameter
```

### Known Commands

| CMD | Port  | Param   | Response | Description |
|-----|-------|---------|----------|-------------|
| 1   | 10005 | 1       | 140 bytes | Device info (manufacturer, model, firmware, ID) |
| 2   | 10005 | 1       | 188 bytes | License/serial info |
| 4   | 10006 | special | 12 bytes  | Register stream listener port |
| 9   | 10007 | —       | —         | Heartbeat (device sends, client ACKs with empty UDP) |

### CMD 1 Response (Device Info)

```
Offset  Size  Content
0       4     Magic
4       2     Sequence (echo)
6       2     CMD = 1
8       4     Flags (0x00800001)
12      1     Unknown (0x01)
13      32    Manufacturer ("MaiKeLong")
45      32    Model ("W05A")
77      16    Firmware ("6.000.076")
93      32    Device ID ("MKL_WIFI_0A86CD")
```

### CMD 4 (Stream Registration)

```
Offset  Size  Value
0       4     Magic
4       2     Sequence
6       2     CMD = 4
8       2     0x0001
10      2     0x0002
12      4     Client listening port (LE uint32, e.g. 10900 = 0x00002a94)
```

## Stream Packets

JPEG frames are split across multiple UDP packets (max ~1472 bytes each).

### 16-Byte Stream Header

```
Offset  Size  Field
0       1     Fixed: 0x01
1       1     Sequence counter (8-bit, wraps at 256)
2       1     Frame counter (8-bit, wraps at 256)
3       1     Last-packet flag (1 = final packet of this frame)
4       2     Packet index within frame (LE uint16, 1-based)
6       4     Reserved (zeros)
10      2     Device ID (0x86cd)
12      2     Frame width (LE uint16, e.g. 640)
14      2     Frame height (LE uint16, e.g. 480)
```

### Frame Reassembly

1. Accumulate payloads (bytes 16+) for consecutive packets with the same frame counter
2. When `last_flag == 1`, the buffer contains one complete JPEG
3. Validate buffer starts with `ff d8` (JPEG SOI marker)
4. Decode with any JPEG decoder; partial frames from packet loss often still decode

### Stream Characteristics

- Resolution: 640x480 (default)
- Format: JPEG (MJPEG stream)
- Frame rate: ~13 fps
- Frame size: ~8–25 KB (scene-dependent)
- Packets per frame: ~7–17

## Heartbeat

The device sends CMD 9 packets to port 10007 approximately once per second.
The client must reply with an **empty UDP packet** to `192.168.1.1:10007`.
Without heartbeat ACKs, the stream may degrade or stop.

### CMD 9 (Heartbeat) Format

```
ee ff ee ff [seq:2] 09 00 [status:21 bytes]
```

Total: 29 bytes. Status bytes include device ID at offset 20–21 (0x86cd).

## Tools Used

- `tshark` — pcap analysis
- `jadx` — APK decompilation
- `radare2` — ARM native library disassembly
- `strings` — binary string extraction
