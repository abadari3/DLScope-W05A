#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

#include <array>
#include <atomic>
#include <cinttypes>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

// -- protocol constants --

constexpr const char* MICROSCOPE_IP = "192.168.1.1";
constexpr uint16_t CMD_PORT    = 10005;
constexpr uint16_t STREAM_REG  = 10006;
constexpr uint16_t STREAM_RX   = 10900;

constexpr uint8_t MAGIC[] = {0xee, 0xff, 0xee, 0xff};
constexpr size_t HEADER_SIZE = 16;
constexpr size_t MAX_FRAME_SIZE = 64 * 1024;

// -- globals --

std::atomic<bool> running{true};

void signal_handler(int) { running = false; }

// -- helpers --

sockaddr_in make_addr(const char* ip, uint16_t port) {
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, ip, &addr.sin_addr);
    return addr;
}

int make_udp_socket(uint16_t bind_port = 0) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        return -1;
    }

    if (bind_port > 0) {
        int reuse = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(bind_port);
        addr.sin_addr.s_addr = INADDR_ANY;
        if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
            perror("bind");
            close(fd);
            return -1;
        }
    }

    int bufsize = 2 * 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufsize, sizeof(bufsize));

    return fd;
}

std::array<uint8_t, 12> make_cmd(uint16_t seq, uint16_t cmd, uint32_t param) {
    std::array<uint8_t, 12> buf{};
    std::memcpy(buf.data(), MAGIC, 4);
    std::memcpy(buf.data() + 4, &seq, 2);
    std::memcpy(buf.data() + 6, &cmd, 2);
    std::memcpy(buf.data() + 8, &param, 2);
    return buf;
}

void register_stream(int fd) {
    auto cmd_addr = make_addr(MICROSCOPE_IP, CMD_PORT);
    auto reg_addr = make_addr(MICROSCOPE_IP, STREAM_REG);

    auto cmd1 = make_cmd(0, 1, 1);
    sendto(fd, cmd1.data(), cmd1.size(), 0,
           reinterpret_cast<sockaddr*>(&cmd_addr), sizeof(cmd_addr));

    auto cmd2 = make_cmd(1, 2, 1);
    sendto(fd, cmd2.data(), cmd2.size(), 0,
           reinterpret_cast<sockaddr*>(&cmd_addr), sizeof(cmd_addr));

    uint8_t cmd4[16]{};
    std::memcpy(cmd4, MAGIC, 4);
    uint16_t seq = 2, cmd = 4, v1 = 1, v2 = 2;
    uint32_t port = STREAM_RX;
    std::memcpy(cmd4 + 4, &seq, 2);
    std::memcpy(cmd4 + 6, &cmd, 2);
    std::memcpy(cmd4 + 8, &v1, 2);
    std::memcpy(cmd4 + 10, &v2, 2);
    std::memcpy(cmd4 + 12, &port, 4);
    sendto(fd, cmd4, sizeof(cmd4), 0,
           reinterpret_cast<sockaddr*>(&reg_addr), sizeof(reg_addr));

    std::printf("[proxy] Registration commands sent\n");
}

// -- main --

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::fprintf(stderr, "Usage: proxy <client-ip> [client-port]\n");
        std::fprintf(stderr, "  client-ip:   Mac's USB Ethernet IP (e.g. 192.168.2.1)\n");
        std::fprintf(stderr, "  client-port: port to forward to (default: 10900)\n");
        return 1;
    }

    const char* client_ip = argv[1];
    uint16_t client_port = (argc >= 3) ? static_cast<uint16_t>(std::stoi(argv[2])) : STREAM_RX;

    auto client_addr = make_addr(client_ip, client_port);

    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);

    // Single socket: registration goes out from port 10900, stream comes back to it
    int sock_fd = make_udp_socket(STREAM_RX);
    if (sock_fd < 0) return 1;

    std::printf("[proxy] Registering with microscope at %s...\n", MICROSCOPE_IP);
    register_stream(sock_fd);

    std::printf("[proxy] Forwarding assembled frames to %s:%d\n", client_ip, client_port);

    timeval tv{.tv_sec = 1, .tv_usec = 0};
    setsockopt(sock_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    uint8_t pkt_buf[65535];

    // Frame assembly state
    std::vector<uint8_t> frame_buf;
    frame_buf.reserve(MAX_FRAME_SIZE);
    uint8_t last_frame_num = 0;
    bool have_frame = false;
    uint32_t pkts_in_frame = 0;

    uint64_t frames_fwd = 0;
    uint64_t frames_dropped = 0;
    uint64_t total_pkts = 0;

    while (running) {
        ssize_t n = recv(sock_fd, pkt_buf, sizeof(pkt_buf), 0);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                std::printf("[proxy] Timeout (no packets for 1s), re-registering...\n");
                register_stream(sock_fd);
                continue;
            }
            perror("recv");
            break;
        }

        total_pkts++;

        // Skip command responses
        if (n >= 4 && std::memcmp(pkt_buf, MAGIC, 4) == 0) {
            std::printf("[proxy] Received command response (%zd bytes)\n", n);
            continue;
        }

        if (static_cast<size_t>(n) <= HEADER_SIZE) {
            std::printf("[proxy] Skipping short packet (%zd bytes)\n", n);
            continue;
        }

        // Parse stream header
        uint8_t seq       = pkt_buf[1];
        uint8_t frame_num = pkt_buf[2];
        uint8_t last_flag = pkt_buf[3];
        uint16_t pkt_idx  = pkt_buf[4] | (pkt_buf[5] << 8);
        const uint8_t* payload = pkt_buf + HEADER_SIZE;
        size_t payload_len = static_cast<size_t>(n) - HEADER_SIZE;

        // New frame started — reset buffer
        if (!have_frame || frame_num != last_frame_num) {
            if (have_frame && frame_buf.size() > 0) {
                std::printf("[proxy] Frame %u incomplete (%u pkts, %zuB), dropped for new frame %u\n",
                            last_frame_num, pkts_in_frame, frame_buf.size(), frame_num);
                frames_dropped++;
            }
            frame_buf.clear();
            last_frame_num = frame_num;
            have_frame = true;
            pkts_in_frame = 0;
        }

        pkts_in_frame++;
        frame_buf.insert(frame_buf.end(), payload, payload + payload_len);

        if (total_pkts <= 20)
            std::printf("[proxy] pkt #%" PRIu64 ": seq=%u frame=%u idx=%u last=%u payload=%zu buf=%zu\n",
                        total_pkts, seq, frame_num, pkt_idx, last_flag, payload_len, frame_buf.size());

        if (last_flag != 1)
            continue;

        // Frame complete — validate JPEG SOI and forward
        have_frame = false;

        if (frame_buf.size() < 2 || frame_buf[0] != 0xff || frame_buf[1] != 0xd8) {
            std::printf("[proxy] Frame %u bad SOI: %02x %02x (%zu bytes, %u pkts), dropped\n",
                        frame_num, frame_buf.size() >= 1 ? frame_buf[0] : 0,
                        frame_buf.size() >= 2 ? frame_buf[1] : 0,
                        frame_buf.size(), pkts_in_frame);
            frames_dropped++;
            continue;
        }

        ssize_t sent = sendto(sock_fd, frame_buf.data(), frame_buf.size(), 0,
                              reinterpret_cast<sockaddr*>(&client_addr), sizeof(client_addr));

        frames_fwd++;
        if (frames_fwd <= 5 || frames_fwd % 100 == 0)
            std::printf("[proxy] Frame %u: %zuK, %u pkts, sent=%zd | total: %" PRIu64 " fwd, %" PRIu64 " dropped\n",
                        frame_num, frame_buf.size() / 1024, pkts_in_frame, sent,
                        frames_fwd, frames_dropped);
    }

    std::printf("[proxy] Shutting down (%" PRIu64 " frames forwarded, %" PRIu64 " dropped)\n",
                frames_fwd, frames_dropped);
    close(sock_fd);
    return 0;
}
