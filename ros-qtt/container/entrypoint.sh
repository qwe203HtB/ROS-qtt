#!/bin/sh
# ══════════════════════════════════════════════════════════════════════════════
# ROS-qtt entrypoint — контейнер MikroTik RouterOS · by qwe203 · 2026
# Ядро: csqtt v2.5.0 © amurcanov (PolyForm-Noncommercial-1.0.0)
#
# Что делает:
#   1. читает /ros-qtt/ros-qtt.conf (строки KEY=VAL; см. ros-qtt.conf.example);
#   2. если задан SOURCE — ссылка csqtt://connect?… от swg-панели: разбирает её
#      (host, peer=DTLS-порт, password, hashes) ровно как делает приложение CSQTT
#      (формат по CsqttLinkTest.kt: хеши разделены '+', литеральный '+' — %2B);
#   3. экспортирует CSQTT_PASSWORD и запускает ядро ros-qtt В ФОНЕ
#      (--peer host:порт --vk хеши --vk-hash-mode manual --tun-uds ros-qtt-tun);
#   4. tun-dispatch создаёт TUN rosqtt0 и передаёт fd ядру (роль Android
#      VpnService);
#   5. маршруты + MASQUERADE: трафик LAN, направленный в контейнер маршрутом
#      RouterOS, уходит в csqtt с одним источником — адресом TUN-устройства
#      (роутер = одна учётка csqtt, так его видит сервер).
# ══════════════════════════════════════════════════════════════════════════════

set -u

echo "ROS-qtt 0.1.0 · RouterOS-клиент csqtt · by qwe203 · ядро amurcanov/csqtt (PolyForm-NC)"

: "${ROSQTT_HOME:=/ros-qtt}"
CONF="$ROSQTT_HOME/ros-qtt.conf"
UDS="ros-qtt-tun"

die() { echo "[ROS-qtt][ОШИБКА] $*" >&2; sleep 30; exit 1; }

# URL-decode %XX/+ → байт. Чистый awk (есть в любом alpine). Значение идёт на stdin —
# никакой обработки-убегов от shell/awk -v не происходит.
urldecode() {
    LC_ALL=C awk '{
        hex = "0123456789abcdef"
        s   = $0
        out = ""
        for (i = 1; i <= length(s); ) {
            c = substr(s, i, 1)
            if (c == "%") {
                d1 = substr(s, i + 1, 1); d2 = substr(s, i + 2, 1)
                v1 = index(hex, tolower(d1)); v2 = index(hex, tolower(d2))
                if (v1 > 0 && v2 > 0 && i + 2 <= length(s)) {
                    out = out sprintf("%c", v1 * 16 + v2 - 17)
                    i += 3
                    continue
                }
            }
            if (c == "+") { c = " " }
            out = out c
            i++
        }
        printf "%s", out
    }'
}
urldecode_line() { printf '%s' "$1" | urldecode; }

[ -r "$CONF" ] || die "нет $CONF — сделай mount (см. install-ros-qtt.rsc: /container/mounts … dst=$ROSQTT_HOME) и положи ros-qtt.conf"

# Парсер конфига без «. $CONF»: значения (например, csqtt://…&peer=…) содержат
# спецсимволы, которые сломались бы в шелл при простом source. Формат файла:
# непустые строки KEY=VAL, «#» — комментарий. Кавычки не нужны и НЕ снимаются.
SOURCE=""; HOST=""; PEER_PORT=""; PASSWORD=""; HASHES=""
TUN_ADDR=""; TUN_MTU=""; WORKERS=""
GATEWAY=""; EXCLUDE_SUBNETS=""
while IFS= read -r line || [ -n "$line" ]; do
    # отступы слева: обрежем через awk-обрезку
    line=$(printf '%s' "$line" | sed 's/^[\t ]*//')
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) : ;; *) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    # инлайновый комментарий « # …» в хвосте значения — вырезать (сами «#»
    # внутри значений не встречаются: пароли/хеши/сети их не содержат)
    val="${val%% #*}"
    # тримим пробелы с обоих концов значения
    val=$(printf '%s' "$val" | sed 's/^[ \t]*//; s/[ \t]*$//')
    case "$key" in
        SOURCE)          SOURCE="$val" ;;
        HOST)            HOST="$val" ;;
        PEER_PORT)       PEER_PORT="$val" ;;
        PASSWORD)        PASSWORD="$val" ;;
        HASHES)          HASHES="$val" ;;
        TUN_ADDR)        TUN_ADDR="$val" ;;
        TUN_MTU)         TUN_MTU="$val" ;;
        WORKERS)         WORKERS="$val" ;;
        GATEWAY)         GATEWAY="$val" ;;
        EXCLUDE_SUBNETS) EXCLUDE_SUBNETS="$val" ;;
        EXTRA_ARGS)      EXTRA_ARGS="${EXTRA_ARGS:-$val}" ;;
    esac
done < "$CONF"
: "${EXTRA_ARGS:=}"

# ── Разбор csqtt:// ссылки, если задана (явные поля важнее полей ссылки) ─────
if [ -n "${SOURCE:-}" ]; then
    case "$SOURCE" in
        csqtt://connect\?*) : ;;
        *) die "SOURCE — не csqtt://connect?… ссылка ($SOURCE)" ;;
    esac
    QUERY="${SOURCE#csqtt://connect?}"
    QUERY=$(printf '%s' "$QUERY" | tr '&' ' ')
    LINK_HOST=""; LINK_PORT=""; LINK_PASS=""; LINK_HASHES=""
    for kv in $QUERY; do
        key="${kv%%=*}"
        val="${kv#*=}"
        case "$key" in
            host)     LINK_HOST="$val" ;;
            peer)     LINK_PORT="$val" ;;
            password) LINK_PASS="$val" ;;
            hashes)   LINK_HASHES="$val" ;;
        esac
    done
    LC_PASS=$(urldecode_line "$LINK_PASS")
    [ -n "$LC_PASS" ] && LINK_PASS="$LC_PASS"
    # хеши: разделитель '+', литеральный + внутри хеша передаётся как %2B
    if [ -n "$LINK_HASHES" ]; then
        LC_HASHES=$(urldecode_line "$(printf '%s' "$LINK_HASHES" | tr '+' ' ')")
        [ -n "$LC_HASHES" ] && LINK_HASHES="$LC_HASHES"
    fi
    HOST="${HOST:-$LINK_HOST}"
    PEER_PORT="${PEER_PORT:-$LINK_PORT}"
    PASSWORD="${PASSWORD:-$LINK_PASS}"
    HASHES="${HASHES:-$LINK_HASHES}"
fi

[ -n "${HOST:-}" ]      || die "нет HOST (адрес csqtt-сервера)"
[ -n "${PEER_PORT:-}" ] || die "нет PEER_PORT (DTLS-порт csqtt-сервера)"
[ -n "${PASSWORD:-}" ]  || die "нет PASSWORD (ключ доступа от swg-панели)"
[ -n "${HASHES:-}" ]    || die "нет HASHES (VK-хеши из csqtt:// ссылки — TURN-креденшл)"

TUN_ADDR="${TUN_ADDR:-26.26.26.2/24}"   # адрес TUN; роутер-клиент MASQ-ится к нему
TUN_MTU="${TUN_MTU:-1300}"              # Constants.Vpn.DEFAULT_MTU как в приложении
N_WORKERS="${WORKERS:-18}"              # дефолт ядра апстрима
GATEWAY="${GATEWAY:-172.20.0.1}"        # veth-шлюз контейнера (см. install-ros-qtt.rsc)
# сети, которые ходят мимо туннеля (обратный путь до LAN-клиентов; иначе петля)
EXCLUDE_SUBNETS="${EXCLUDE_SUBNETS:-192.168.0.0/16 10.0.0.0/8 172.16.0.0/12}"

# ── 1. Ядро клиента В ФОНЕ: оно биндит abstract UDS $UDS и ждёт fd ──────────
export CSQTT_PASSWORD="$PASSWORD"
echo "[ROS-qtt] ядро: ros-qtt --peer $HOST:$PEER_PORT --workers $N_WORKERS --vk-hash-mode manual (--vk: ${#HASHES} симв.)"

CLIENT_ARGS="--peer $HOST:$PEER_PORT --vk-hash-mode manual --workers $N_WORKERS"
if [ -n "${EXTRA_ARGS:-}" ]; then
    # расширенные флаги ядра апстрима: --obfs --turn-transport --srtp-mode
    # --domain-routing --ip-routing --direct-domains --domains-file --direct-ips …
    CLIENT_ARGS="$CLIENT_ARGS $EXTRA_ARGS"
fi
: "${ROSQTT_BIN:=/usr/local/bin/ros-qtt}"          # подменяемо — для rig-тестов
: "${ROSQTT_DISPATCH:=/usr/local/bin/tun-dispatch}"
: "${ROSQTT_IPTABLES:=iptables}"                   # rig-тест подменяет на стаб
: "${ROSQTT_IP:=ip}"
: "${ROSQTT_SYS:=/sys/class/net/rosqtt0}"      # замена для rig-тестов

"$ROSQTT_BIN" $CLIENT_ARGS --tun-uds "$UDS" --vk "$HASHES" &
CLIENT_PID=$!

# ── 2. tun-dispatch: TUN rosqtt0 + передача fd (роль Android VpnService) ────
"$ROSQTT_DISPATCH" "$UDS" --addr "$TUN_ADDR" --mtu "$TUN_MTU" --retry 60 &
DISPATCH_PID=$!
if ! wait "$DISPATCH_PID"; then
    kill "$CLIENT_PID" 2>/dev/null
    die "tun-dispatch не смог создать TUN/передать fd — смотри лог выше (нет /dev/net/tun? device-mode container=yes?)"
fi

# ── 3. Маршруты контейнера: TUN перехватывает всё, кроме LAN-обраток ────────
I=0
while [ "$I" -lt 40 ]; do
    [ -e "$ROSQTT_SYS" ] && break
    sleep 0.25
    I=$((I + 1))
done
[ -e "$ROSQTT_SYS" ] || die "TUN rosqtt0 не появился"
# форвардинг LAN→TUN внутри контейнера требует ip_forward
if [ -w /proc/sys/net/ipv4/ip_forward ]; then
    echo 1 > /proc/sys/net/ipv4/ip_forward
else
    echo "[ROS-qtt][ПРЕДУПРЕЖДЕНИЕ] не доступен /proc/sys/net/ipv4/ip_forward — форвардинг LAN может не работать"
fi

TUN_IP="${TUN_ADDR%%/*}"
for subnet in $EXCLUDE_SUBNETS; do
    "$ROSQTT_IP" route add "$subnet" via "$GATEWAY" 2>/dev/null || true
done
"$ROSQTT_IP" route add 0.0.0.0/1 dev rosqtt0
"$ROSQTT_IP" route add 128.0.0.0/1 dev rosqtt0

# ── 4. MASQUERADE внутрь туннеля: зафорwardенный LAN-трафик получает source
#    = адрес TUN (роутер = одна учётка csqtt; сервер видит стабильный IP) ────
"$ROSQTT_IPTABLES" -t nat -C POSTROUTING -o rosqtt0 -j MASQUERADE 2>/dev/null || \
    "$ROSQTT_IPTABLES" -t nat -A POSTROUTING -o rosqtt0 -j MASQUERADE

# ═══ ROS-qtt · qwe203 · ядро csqtt © amurcanov ═══
echo "[ROS-qtt] туннель собран: rosqtt0 на $TUN_ADDR (MTU $TUN_MTU), правило MASQUERADE стоит, ядро PID $CLIENT_PID"
trap 'echo "[ROS-qtt] SIGTERM: гасим ядро (PID $CLIENT_PID) · ROS-qtt by qwe203"; kill "$CLIENT_PID" 2>/dev/null' TERM INT
wait "$CLIENT_PID"
