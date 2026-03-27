# dlscope

Viewer and tools for the MaiKeLong W05A WiFi digital microscope. Replaces the proprietary DLScope iOS/Android app with an open-source alternative that runs on macOS.

The W05A creates an open WiFi AP and streams MJPEG over a custom UDP protocol. See [PROTOCOL.md](PROTOCOL.md) for the reverse-engineered protocol details.

## Usage

### Direct connection

Connect your Mac to the microscope's WiFi AP (`MKL_WIFI_*`), then run the viewer:

```bash
cd viewer
python viewer.py
```

The viewer handles registration, heartbeat, and frame reassembly. This gives the best quality (~13 fps, 640x480), but your Mac loses internet while connected to the microscope's AP.

**Keys:** Q = quit, S = save frame as PNG

**Options:**
- `--skip-dirty` — drop frames with missing packets (cleaner but lower fps)
- `--replay PCAP` — replay a pcap capture instead of live stream
- `--speed N` — replay speed (1.0 = realtime, 0 = max)

### With proxy (keep internet access)

A Raspberry Pi Zero 2W connects to the microscope's WiFi and forwards reassembled frames to the Mac over USB Ethernet. The Mac's WiFi stays free for internet.

```
Microscope --WiFi--> Pi Zero 2W --USB Ethernet--> Mac
                     (proxy)                      (viewer --proxy)
```

On the Pi:

```bash
./proxy 192.168.2.1
```

On the Mac:

```bash
cd viewer
python viewer.py --proxy
```

See [proxy/README.md](proxy/README.md) for build instructions and Pi setup.

## Project Structure

```
dlscope/
├── viewer/          # Python viewer (macOS)
│   └── viewer.py    # Stream viewer with direct and proxy modes
├── proxy/           # C++ proxy (Raspberry Pi Zero 2W)
│   ├── src/         # Proxy source (registration, reassembly, forwarding)
│   └── README.md    # Build and deployment instructions
├── PROTOCOL.md      # Reverse-engineered W05A protocol documentation
└── README.md        # This file
```

## Requirements

### Viewer

- Python 3.10+
- OpenCV (`pip install opencv-python`)
- NumPy (`pip install numpy`)

### Proxy

- Raspberry Pi Zero 2W with USB OTG Ethernet to Mac
- Built with Apple Containers (see [proxy/README.md](proxy/README.md))
