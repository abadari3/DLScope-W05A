# proxy

C++20 UDP proxy for the W05A microscope. Runs on a Raspberry Pi Zero 2W, receives fragmented JPEG stream packets over WiFi, reassembles them into complete frames, and forwards them to a Mac over USB Ethernet.

See [PROXY.md](PROXY.md) for protocol details and architecture.

## Build

### Prerequisites

- macOS with Apple Containers CLI (`container` command)
- CMake, Ninja (for local macOS builds: `brew install cmake ninja`)

### Build for Pi (ARM64, via container)

```bash
# One-time: build the container image
container build --tag pizero-dev-dlscope .

# Build
container run --rm -v "$(pwd)":/project pizero-dev-dlscope sh -c "make 2>&1 | grep -v gmake"
```

The binary is at `build/proxy`.

### Build for macOS (local testing)

```bash
make
```

The binary is at `build-mac/proxy`.

## Deploy

```bash
scp ./build/proxy ananda@pizero.local:~
```

## Pi Setup

### First-time setup

```bash
# Set WLAN country (permanently unblocks WiFi)
sudo raspi-config nonint do_wifi_country US

# Increase UDP receive buffer limit
echo 'net.core.rmem_max=2097152' | sudo tee -a /etc/sysctl.conf

# Save WiFi config for microscope AP
echo 'network={
    ssid="MKL_WIFI_0A86CD"
    key_mgmt=NONE
}' | sudo tee /etc/wpa_microscope.conf
```

### Each session

```bash
# Connect to microscope WiFi
sudo wpa_supplicant -i wlan0 -c /etc/wpa_microscope.conf -B
sudo dhcpcd wlan0
sudo iw dev wlan0 set power_save off

# Fix DNS (dhcpcd may overwrite resolv.conf with empty microscope DNS)
echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf

# Run the proxy
./proxy 192.168.2.1
```

### Teardown

```bash
sudo killall wpa_supplicant dhcpcd 2>/dev/null
sudo ip link set wlan0 down
```

## Usage

On the Pi:

```bash
./proxy <mac-ip> [port]
```

- `mac-ip`: Mac's USB Ethernet IP (e.g. `192.168.2.1`)
- `port`: UDP port to forward to (default: `10900`)

On the Mac:

```bash
python viewer.py --proxy
```

## Project Structure

```
proxy/
├── src/
│   ├── main.cpp          # Proxy: registration, reassembly, forwarding
│   └── CMakeLists.txt    # C++20, -O3 -Wall -Wextra -Wpedantic
├── test_recv.py          # Headless stream test (run on Pi)
├── Containerfile         # Ubuntu 22.04 + clang + cmake + ninja
├── Makefile              # Platform-aware build (build/ vs build-mac/)
├── PROXY.md              # Protocol and architecture details
└── README.md             # This file
```

## Compiler Flags

- C++20
- `-O3` — full optimization
- `-Wall -Wextra -Wpedantic` — strict warnings
- Built with Clang (in container) or AppleClang (macOS)
