/* tun-dispatch — ROS-qtt (by qwe203, 2026)
 * Клиент csqtt (ядро amurcanov/csqtt) сам не открывает /dev/net/tun — на Android fd
 * создаёт VpnService и передаёт его клиенту по абстрактному UDS (--tun-uds).
 * На RouterOS (container) роль VpnService выполняет этот хелпер:
 *
 *   1. открывает /dev/net/tun и создаёт интерфейс rosqtt0 (TUN, IFF_NO_PI);
 *   2. назначает адрес/маску/MTU ioctl'ами (без дочерних ip-процессов);
 *   3. подключается к abstract UDS и передаёт fd клиенту через SCM_RIGHTS;
 *   4. выходит (своя копия fd за клиентом — интерфейс не умрёт).
 *
 *   tun-dispatch <uds-имя> [--addr A.B.C.D/p] [--mtu N] [--retry S] [--hold]
 *
 * Ядро: csqtt v2.5.0 © amurcanov (PolyForm-Noncommercial-1.0.0).
 * Сборка статическая: zig cc -static (см. build.sh ROS-qtt).
 */

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define TUN_DEV        "/dev/net/tun"
#define TUN_IFACE      "rosqtt0"
#define TUNSETIFF_IOW  0x400454cau /* _IOW('t', 202, int) — одинаково на arm64/x86_64 */
#define IFF_TUN_NO_PI  (IFF_TUN | IFF_NO_PI)
#define DEFAULT_TUN_IP "26.26.26.2"
#define DEFAULT_MASK   "255.255.255.0"
#define DEFAULT_MTU    1300        /* Constants.Vpn.DEFAULT_MTU как в Android-приложении */

/* Водянка ROS-qtt — печатается на каждый запуск, попадает в /log (container logging). */
static void watermark(const char *line) {
    fprintf(stderr, "[ROS-qtt] %s · by qwe203 · ядро csqtt © amurcanov\n", line);
}

static int fd_ioctl_addr(unsigned long req, void *arg) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return -1;
    int rc = ioctl(s, req, arg);
    int errno_save = errno;
    close(s);
    errno = errno_save;
    return rc;
}

/* addr/mask/mtu на интерфейсе + поднять: SIOCSIFADDR, SIOCSIFNETMASK, SIOCSIFMTU, SIOCSIFFLAGS.
 * TUNSETIFF уже сделан в main() на этом fd — здесь только L3-конфигурация. */
static int configure_iface(const char *ip, const char *mask, int mtu) {
    struct ifreq ifr;
    struct sockaddr_in sa;
    memset(&ifr, 0, sizeof(ifr));
    memset(&sa, 0, sizeof(sa));
    snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", TUN_IFACE);
    sa.sin_family = AF_INET;
    if (inet_pton(AF_INET, ip, &sa.sin_addr) != 1) {
        fprintf(stderr, "[ОШИБКА] неверный адрес: %s\n", ip);
        return -1;
    }
    struct ifreq a = ifr, m = ifr, f = ifr, t = ifr;
    a.ifr_addr = *(struct sockaddr *)&sa;
    if (fd_ioctl_addr(SIOCSIFADDR, &a) < 0) goto io_fail;
    if (inet_pton(AF_INET, mask, &sa.sin_addr) != 1) {
        fprintf(stderr, "[ОШИБКА] неверная маска: %s\n", mask);
        return -1;
    }
    m.ifr_netmask = *(struct sockaddr *)&sa;
    if (fd_ioctl_addr(SIOCSIFNETMASK, &m) < 0) goto io_fail;
    t.ifr_mtu = mtu;
    if (fd_ioctl_addr(SIOCSIFMTU, &t) < 0) goto io_fail;

    if (fd_ioctl_addr(SIOCGIFFLAGS, &f) < 0) goto io_fail;
    f.ifr_flags |= IFF_UP | IFF_RUNNING;
    if (fd_ioctl_addr(SIOCSIFFLAGS, &f) < 0) goto io_fail;
    return 0;

io_fail:
    fprintf(stderr, "[ОШИБКА] конфигурация %s: %s\n", TUN_IFACE, strerror(errno));
    return -1;
}

/* Подключение к абстрактному UDS: sun_path[0] = '\0', имя — байты после ведущего нуля.
 * Ровно так nix::UnixAddr::new_abstract(name) складывает имя у клиента (nix 0.31.3:
 * «The leading nul byte for the abstract namespace is automatically added»). */
static int connect_uds(const char *name, int retry_seconds) {
    size_t name_len = strlen(name);
    if (name_len >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        fprintf(stderr, "[ОШИБКА] имя UDS слишком длинное: %s\n", name);
        return -1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    addr.sun_path[0] = '\0';
    memcpy(addr.sun_path + 1, name, name_len);
    socklen_t addr_len = offsetof(struct sockaddr_un, sun_path) + 1 + name_len;

    int deadline = retry_seconds;
    for (;;) {
        int s = socket(AF_UNIX, SOCK_STREAM, 0);
        if (s < 0) {
            fprintf(stderr, "[ОШИБКА] socket(AF_UNIX): %s\n", strerror(errno));
            return -1;
        }
        if (connect(s, (struct sockaddr *)&addr, addr_len) == 0) {
            return s;
        }
        int err = errno;
        close(s);
        if (err != ECONNREFUSED && err != ENOENT && err != EADDRNOTAVAIL) {
            fprintf(stderr, "[ОШИБКА] connect(abstract %s): %s\n", name, strerror(err));
            return -1;
        }
        if (deadline <= 0) {
            fprintf(stderr, "[ОШИБКА] абстрактный UDS %s недоступен %d c — запущен ли ros-qtt с --tun-uds %s?\n",
                    name, retry_seconds, name);
            return -1;
        }
        /* Водянку дублируем редким пиканьем, чтобы в /log RouterOS был виден прогресс. */
        if (deadline == retry_seconds) watermark("жду клиент: connect к abstract UDS…");
        sleep(1);
        deadline--;
    }
}

/* Передать fd по SCM_RIGHTS: один байт полезной нагрузки + ancillary-сообщение. */
static int send_fd(int sock, int fd) {
    struct iovec iov = { .iov_base = "X", .iov_len = 1 };
    char cbuf[CMSG_SPACE(sizeof(int))];
    memset(cbuf, 0, sizeof(cbuf));
    struct msghdr msgh;
    memset(&msgh, 0, sizeof(msgh));
    msgh.msg_iov = &iov;
    msgh.msg_iovlen = 1;
    msgh.msg_control = cbuf;
    msgh.msg_controllen = sizeof(cbuf);
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msgh);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &fd, sizeof(int));
    if (sendmsg(sock, &msgh, 0) < 0) {
        fprintf(stderr, "[ОШИБКА] sendmsg(SCM_RIGHTS): %s\n", strerror(errno));
        return -1;
    }
    return 0;
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);

    if (argc < 2 || strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
        fprintf(stderr,
                "ROS-qtt tun-dispatch (qwe203, 2026) · ядро csqtt © amurcanov (PolyForm-NC)\n"
                "Синтаксис: tun-dispatch <uds-имя> [--addr A.B.C.D/p] [--mtu N]\n"
                "           [--retry С] [--hold]\n"
                "  --addr  адрес TUN (по умолчанию " DEFAULT_TUN_IP "/" "24); маска из префикса\n"
                "  --mtu   MTU TUN (по умолчанию %d, как в Android-приложении csqtt)\n"
                "  --retry сколько секунд ждать, пока ros-qtt забиндит abstract UDS\n"
                "  --hold  после передачи fd не выходить, а держать свою копию fd открытым\n",
                DEFAULT_MTU);
        return argc < 2 ? 1 : 0;
    }
    const char *uds_name  = argv[1];
    const char *ip        = DEFAULT_TUN_IP;
    const char *mask      = DEFAULT_MASK;
    int mtu               = DEFAULT_MTU;
    int retry_seconds     = 30;
    int hold              = 0;

    for (int i = 2; i < argc; i++) {
        const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;
        if (strcmp(argv[i], "--addr") == 0 && v) {
            char buf[64];
            snprintf(buf, sizeof(buf), "%s", v);
            char *slash = strchr(buf, '/');
            if (slash) *slash = '\0';
            ip = strdup(buf);
            /* Маска: /30 → 255.255.255.252, /24 → 255.255.255.0 и т.п. */
            int prefix = slash ? atoi(slash + 1) : 24;
            if (prefix < 0 || prefix > 32) {
                fprintf(stderr, "[ОШИБКА] префикс /%d вне 0..32\n", prefix);
                return 1;
            }
            static char mask_buf[16];
            uint32_t m = prefix == 0 ? 0u : (0xFFFFFFFFu << (32 - prefix));
            unsigned char o[4];
            for (int k = 0; k < 4; k++) o[k] = (unsigned char)((m >> (24 - 8 * k)) & 0xFF);
            snprintf(mask_buf, sizeof(mask_buf), "%u.%u.%u.%u", o[0], o[1], o[2], o[3]);
            mask = mask_buf;
            i++;
        } else if (strcmp(argv[i], "--mtu") == 0 && v) {
            mtu = atoi(v);
            i++;
        } else if (strcmp(argv[i], "--retry") == 0 && v) {
            retry_seconds = atoi(v);
            i++;
        } else if (strcmp(argv[i], "--hold") == 0) {
            hold = 1;
        } else {
            fprintf(stderr, "[ОШИБКА] непонятный аргумент: %s\n", argv[i]);
            return 1;
        }
    }

    watermark("запуск tun-dispatch: /dev/net/tun → rosqtt0");

    int tun_fd = open(TUN_DEV, O_RDWR);
    if (tun_fd < 0) {
        fprintf(stderr, "[ОШИБКА] open(" TUN_DEV "): %s — в контейнере RouterOS %s\n",
                strerror(errno),
                "нет /dev/net/tun? Проверь container-пакет и device-mode container=yes; "
                "в активных /dev должен быть /dev/net/tun");
        return 1;
    }

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_flags = IFF_TUN_NO_PI;
    snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", TUN_IFACE);
    if (ioctl(tun_fd, TUNSETIFF_IOW, &ifr) < 0) {
        fprintf(stderr, "[ОШИБКА] TUNSETIFF: %s (интерфейс " TUN_IFACE " занят?\n", strerror(errno));
        close(tun_fd);
        return 1;
    }

    if (configure_iface(ip, mask, mtu) < 0) {
        close(tun_fd);
        return 1;
    }

    int sock = connect_uds(uds_name, retry_seconds);
    if (sock < 0) {
        close(tun_fd);
        return 1;
    }
    if (send_fd(sock, tun_fd) < 0) {
        close(sock);
        close(tun_fd);
        return 1;
    }
    watermark("TUN rosqtt0 готов, fd передан клиенту (UDS)");

    if (!hold) {
        /* Своя копия fd закрыта: интерфейс держит клиент — выхода хелпера он не заметит. */
        close(sock);
        close(tun_fd);
        return 0;
    }
    char line[256];
    snprintf(line, sizeof(line), "--hold: держу fd до SIGTERM (PID %d, TUN %s на %s/%s)",
             (int)getpid(), TUN_IFACE, ip, mask);
    watermark(line);
    for (;;) pause();
    return 0;
}
