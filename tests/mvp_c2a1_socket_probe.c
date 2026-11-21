// SPDX-License-Identifier: MIT
// QEMU-only proof: a rootless process can set and read back IP_TRANSPARENT
// on distinct TCP and UDP sockets with CAP_NET_RAW alone.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int probe(int kind, const char *label) {
    int fd = socket(AF_INET, kind, 0), value = 1, got = 0;
    socklen_t len = sizeof(got);
    struct sockaddr_in address = { .sin_family = AF_INET,
                                   .sin_port = htons(kind == SOCK_STREAM ? 39101 : 39102) };
    if (fd < 0 || inet_pton(AF_INET, "127.0.0.2", &address.sin_addr) != 1) {
        perror("socket/inet_pton"); return 1;
    }
    if (setsockopt(fd, SOL_IP, IP_TRANSPARENT, &value, sizeof(value)) < 0) {
        fprintf(stderr, "REJECT: %s IP_TRANSPARENT setsockopt: %s\n", label, strerror(errno));
        close(fd); return 1;
    }
    if (getsockopt(fd, SOL_IP, IP_TRANSPARENT, &got, &len) < 0 || got != 1) {
        fprintf(stderr, "FAIL: %s IP_TRANSPARENT getsockopt\n", label);
        close(fd); return 1;
    }
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("bind"); close(fd); return 1;
    }
    if (kind == SOCK_STREAM && listen(fd, 1) < 0) {
        perror("listen"); close(fd); return 1;
    }
    printf("PASS: %s setsockopt+getsockopt IP_TRANSPARENT=1 bound to 127.0.0.2\n", label);
    close(fd); return 0;
}

int main(void) {
    int tcp = probe(SOCK_STREAM, "TCP");
    int udp = probe(SOCK_DGRAM, "UDP");
    return tcp || udp;
}
