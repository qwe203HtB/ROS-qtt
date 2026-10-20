# ══════════════════════════════════════════════════════════════════════════
# ROS-qtt — контейнер для MikroTik RouterOS (пакет `container`)
# клиент csqtt (ядро amurcanov/csqtt v2.5.0) · порт под RouterOS: by qwe203, 2026
#
# Сборка образа (в РЯДУ с Dockerfile, рядом лежат собранные build.sh бинарЫ):
#   docker buildx build --platform linux/arm64 --output=type=docker \
#     --build-arg TARGETPLATFORM=linux/arm64 -t ros-qtt:0.1.0-arm64 .
#   docker save ros-qtt:0.1.0-arm64 > ros-qtt-arm64.tar
#   (для x86-роутеров то же с linux/amd64)
#
# Требования RouterOS: ≥7.5-beta, пакет container, device-mode container=yes
# (физический доступ: кнопка reset / холодная перезагрузка — см. доку MikroTik).
# RouterOS отдаёт контейнерам /dev/net/tun и root (user=0:0) — ровно то, что
# нужно клиенту csqtt под raw-IP TUN.
# ══════════════════════════════════════════════════════════════════════════

FROM --platform=${TARGETPLATFORM:-linux/arm64} alpine:3.21

LABEL org.opencontainers.image.title="ROS-qtt" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.description="Клиент csqtt (© amurcanov, PolyForm-Noncommercial) для MikroTik RouterOS (container). Порт: by qwe203, 2026." \
      org.opencontainers.image.authors="qwe203"

# iptables — MASQUERADE внутрь туннеля (развратка LAN-трафика к одному источнику
# TUN); iproute2 — маршруты 0/1+128/1 в TUN и обратки LAN; всё на этапе сборки,
# во время работы контейнер ничего из сети не ставит.
RUN apk add --no-cache iptables iproute2

# Рядом с Dockerfile обязаны лежать (см. build.sh ROS-qtt):
#   ros-qtt        — статический musl-бинарник ядра csqtt (v2.5.0, ROS-qtt-патч)
#   tun-dispatch   — статический musl-хелпер: создаёт TUN + передаёт fd клиенту
#   entrypoint.sh  — разбор csqtt:// ключа и сшивка всего
COPY ros-qtt       /usr/local/bin/ros-qtt
COPY tun-dispatch  /usr/local/bin/tun-dispatch
COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /usr/local/bin/ros-qtt /usr/local/bin/tun-dispatch /entrypoint.sh

# Конфиг/ключ живут в /ros-qtt — монтируется с роутера (/container/mounts:
# src=disk1/ros-qtt dst=/ros-qtt), меняется БЕЗ пересборки контейнера.
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
