#!/usr/bin/env bash
# pack.sh — ROS-qtt (by qwe203, 2026): собрать образ контейнера для RouterOS.
# Результат: ros-qtt-<arch>.tar — загружаете на роутер и указываете в install-ros-qtt.rsc.
#
# Usage: bash pack.sh [arm64|amd64] [bin-dir]
#   bin-dir  — каталог с ros-qtt-linux-<arch> и tun-dispatch-linux-<arch> от build.sh
# Needs: docker с buildx (или podman). Ни docker, ни podman? Отстылайте Dockerfile
#   в CI-сборку (GitHub Actions и т.п.) — команда упаковки описана в README.
#
# ROS-qtt · ядро: csqtt v2.5.0 © amurcanov (PolyForm-Noncommercial-1.0.0)
set -euo pipefail

ARCH="${1:-arm64}"
BINDIR="${2:-./dist}"
HEREDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

case "$ARCH" in
  amd64) PLAT="linux/amd64"; SLASH="amd64" ;;
  arm64) PLAT="linux/arm64"; SLASH="arm64" ;;
  *) echo "arch must be amd64|arm64" >&2; exit 2 ;;
esac

CLI="$BINDIR/ros-qtt-linux-$ARCH"
DSP="$BINDIR/tun-dispatch-linux-$ARCH"
[ -x "$CLI" ] || { echo "нет $CLI — сначала запустите build.sh (см. README)"; exit 1; }
[ -x "$DSP" ] || { echo "нет $DSP — сначала запустите build.sh"; exit 1; }

cp "$CLI" "$STAGE/ros-qtt"
cp "$DSP" "$STAGE/tun-dispatch"
cp "$HEREDIR/container/entrypoint.sh" "$STAGE/entrypoint.sh"
cp "$HEREDIR/container/Dockerfile" "$STAGE/Dockerfile"

echo "▸ ROS-qtt · by qwe203: сборка образа $PLAT (ядро csqtt © amurcanov)…"
cd "$STAGE"
docker buildx build --platform "$PLAT" --build-arg "TARGETPLATFORM=$PLAT" \
  --output=type=docker --tag "ros-qtt:0.1.0-$SLASH" .
docker save "ros-qtt:0.1.0-$SLASH" > "$HEREDIR/ros-qtt-$SLASH.tar"
echo "▸ готово: $HEREDIR/ros-qtt-$SLASH.tar"
echo "  залейте на роутер (rsync/Winbox), поместите как $ROSQTTDisk/ros-qtt.tar и запустите install-ros-qtt.rsc"
