#!/usr/bin/env python3
"""Headless stream test — runs on the Pi to measure packet reception and frame assembly."""

import socket
import struct
import time

MICROSCOPE_IP = "192.168.1.1"
CMD_PORT   = 10005
STREAM_REG = 10006
STREAM_RX  = 10900
MAGIC = b"\xee\xff\xee\xff"

def make_cmd(seq, cmd, param):
    return struct.pack("<4sHHI", MAGIC, seq, cmd, param)

def register_stream(sock):
    sock.sendto(make_cmd(0, 1, 1), (MICROSCOPE_IP, CMD_PORT))
    sock.sendto(make_cmd(1, 2, 1), (MICROSCOPE_IP, CMD_PORT))
    sock.sendto(
        struct.pack("<4sHHHHI", MAGIC, 2, 4, 1, 2, STREAM_RX),
        (MICROSCOPE_IP, STREAM_REG),
    )
    print("Registration sent")

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("", STREAM_RX))
sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2 * 1024 * 1024)
sock.settimeout(5.0)

register_stream(sock)

buf = b""
pkts = 0
frames = 0
failed = 0
dirty = 0
last_frame = None
expect_idx = 1
frame_dirty = False
t_start = time.time()
t_stat = time.time()

print("Listening...")

try:
    while True:
        try:
            data, addr = sock.recvfrom(65535)
        except TimeoutError:
            print("Timeout — re-registering...")
            register_stream(sock)
            continue

        pkts += 1

        if data[:4] == MAGIC:
            continue
        if len(data) <= 16:
            continue

        frame_num = data[2]
        last_flag = data[3]
        pkt_idx = struct.unpack_from("<H", data, 4)[0]
        payload = data[16:]

        if last_frame is not None and frame_num != last_frame:
            if buf:
                buf = b""
            expect_idx = 1
            frame_dirty = False
        last_frame = frame_num

        if pkt_idx != expect_idx:
            frame_dirty = True
        expect_idx = pkt_idx + 1

        buf += payload

        if last_flag != 1:
            continue

        expect_idx = 1

        if buf[:2] != b"\xff\xd8":
            failed += 1
            buf = b""
            frame_dirty = False
            continue

        frames += 1
        if frame_dirty:
            dirty += 1
            frame_dirty = False

        frame_size = len(buf)
        buf = b""

        if frames % 50 == 0:
            elapsed = time.time() - t_stat
            fps = 50 / elapsed if elapsed > 0 else 0
            total = time.time() - t_start
            print(f"{fps:.1f} fps | {frame_size//1024}K | frames={frames} failed={failed} dirty={dirty} pkts={pkts} | {total:.0f}s")
            t_stat = time.time()

except KeyboardInterrupt:
    total = time.time() - t_start
    print(f"\nDone in {total:.1f}s — frames={frames} failed={failed} dirty={dirty} pkts={pkts}")

sock.close()
