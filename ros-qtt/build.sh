#!/usr/bin/env bash
# Build ROS-qtt (by qwe203, 2026): клиент csqtt v2.5.0 © amurcanov, пересобранный
# под MikroTik RouterOS (container) — статический musl-бинарник + tun-dispatch.
# Проверенный zigbuild-рецепт (cargo-zigbuild, статические musl-бинарники).
#
# Usage:   bash build.sh <out-dir> [amd64|arm64]     (default arch: amd64)
# Needs:   cargo + rustup (toolchain 1.97.1) + zig + cargo-zigbuild on PATH.
# Лицензия: csqtt — PolyForm-Noncommercial-1.0.0, СБОРКА И ИСПОЛЬЗОВАНИЕ —
# только в некоммерческих целях. ROS-qtt-патч добавляет подпись by qwe203.
set -euo pipefail

# Пин апстрима: amurcanov/csqtt v2.5.0 (репозиторий запечатан 2026-10-20)
PIN="d02da9bd9d8926969b766e197c434d830a83dbd8"
REPO="https://github.com/amurcanov/csqtt.git"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:?usage: build.sh <out-dir> [amd64|arm64]}"
ARCH="${2:-amd64}"
case "$ARCH" in
  amd64) TARGET="x86_64-unknown-linux-musl";  ZIGTGT="x86_64-linux-musl";  ENVA="X86_64_UNKNOWN_LINUX_MUSL";  CENV="x86_64_unknown_linux_musl" ;;
  arm64) TARGET="aarch64-unknown-linux-musl"; ZIGTGT="aarch64-linux-musl"; ENVA="AARCH64_UNKNOWN_LINUX_MUSL"; CENV="aarch64_unknown_linux_musl" ;;
  *) echo "arch must be amd64|arm64 (RouterOS container: x86|arm64; arm/EN7562CT — не поддерживается этим рецептом)" >&2; exit 2 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git clone -q "$REPO" "$WORK/csqtt"
git -C "$WORK/csqtt" checkout -q "$PIN"
git -C "$WORK/csqtt" apply "$HERE/ros-qtt.patch"

rustup toolchain install 1.97.1 --profile minimal >/dev/null 2>&1 || true
rustup target add "$TARGET" --toolchain 1.97.1 >/dev/null 2>&1 || true

# У ядра есть C-зависимости (aws-lc-sys и пр.) — cargo-zigbuild сам их не разведёт:
# «cc» crate в trường кросс-сборки требует явного компилятора. Обёртки zig cc/
# zig c++/zig ar путают таргет-флаг ржаного rustc — идентично forks/csqtt/build.sh.
WRAP="$WORK/zig-wrappers"; mkdir -p "$WRAP"
cat > "$WRAP/zigcc" <<SH
#!/usr/bin/env bash
args=(); for a in "\$@"; do [[ "\$a" == "--target=$TARGET" ]] || args+=("\$a"); done
exec zig cc -target $ZIGTGT "\${args[@]}"
SH
cat > "$WRAP/zigcxx" <<SH
#!/usr/bin/env bash
args=(); for a in "\$@"; do [[ "\$a" == "--target=$TARGET" ]] || args+=("\$a"); done
exec zig c++ -target $ZIGTGT "\${args[@]}"
SH
printf '#!/usr/bin/env bash\nexec zig ar "$@"\n' > "$WRAP/zigar"
chmod +x "$WRAP"/zig*
export CC_$CENV="$WRAP/zigcc" CXX_$CENV="$WRAP/zigcxx" AR_$CENV="$WRAP/zigar"
export CARGO_TARGET_${ENVA}_LINKER="$WRAP/zigcc"
# Апстрим сам собирает только x86_64 (.cargo/config.toml: link-self-contained=no лишь
# для x86_64). БЕЗ этой строки ld.lld ржёт: `duplicate symbol: _start`. Ставим обеим
# аркам — сборки остаются симметричными и проверяемыми.
export CARGO_TARGET_${ENVA}_RUSTFLAGS="-C link-self-contained=no"

( cd "$WORK/csqtt/rust-client" && cargo +1.97.1 zigbuild --release --target "$TARGET" )

# tun-dispatch — тот же статический musl через zig cc, без зависимостей
( cd "$HERE" && zig cc -target "$ZIGTGT" -static -O2 -o "$WORK/tun-dispatch" tun-dispatch.c )

mkdir -p "$OUT"
cp "$WORK/csqtt/rust-client/target/$TARGET/release/ros-qtt" "$OUT/ros-qtt-linux-$ARCH"
cp "$WORK/tun-dispatch" "$OUT/tun-dispatch-linux-$ARCH"
echo "ROS-qtt · by qwe203: собрано на ядре csqtt v2.5.0 © amurcanov"
echo "built: $OUT/ros-qtt-linux-$ARCH"
echo "built: $OUT/tun-dispatch-linux-$ARCH"
file "$OUT/ros-qtt-linux-$ARCH" "$OUT/tun-dispatch-linux-$ARCH"
