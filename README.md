<!--
═════════════════════════════════════════════════════════════════════════════════
 ROS-qtt · клиент csqtt под MikroTik RouterOS · форк amurcanov/csqtt
 порт: by qwe203 (2026) · ядро: csqtt v2.5.0 © amurcanov (PolyForm-Noncommercial-1.0.0)
═════════════════════════════════════════════════════════════════════════════════
-->

<div align="center">

# ROS-qtt

**Клиент [CSQTT](https://github.com/amurcanov/csqtt) под MikroTik RouterOS.**

`ROS-qtt · by qwe203 · ядро: csqtt v2.5.0 © amurcanov (PolyForm-Noncommercial-1.0.0)`

[![MikroTik RouterOS](https://img.shields.io/badge/MikroTik-RouterOS_7.5%2B-E21B23?style=for-the-badge&logo=linux&logoColor=white)](https://help.mikrotik.com/docs/display/ROS/Container)
[![Rust Core](https://img.shields.io/badge/Rust-2024-000000?style=for-the-badge&logo=rust&logoColor=white)](https://www.rust-lang.org)
[![License](https://img.shields.io/badge/License-PolyForm--Noncommercial--1.0.0-8A2BE2?style=for-the-badge)](LICENSE)
[![Fork](https://img.shields.io/badge/fork%20of-amurcanov%2Fcsqtt-24292e?style=for-the-badge&logo=github)](https://github.com/amurcanov/csqtt)

</div>

---

## Что это

Форк [**csqtt**](https://github.com/amurcanov/csqtt) © amurcanov — Android-приложения и
ядра для защищённого туннеля поверх TURN/RTP (VK-TURN, транспорт замаскирован под
медиатрафик звонка), **приспособленный под MikroTik RouterOS**: порт **by qwe203**
превращает этот форк в репозиторий, где ядро csqtt собирается как обычный
Linux-бинарник и живёт в **контейнере RouterOS**. Роутер MikroTik сам становится
абонентом csqtt-туннеля — как телефон с приложением CSQTT, только на роутере:
ключ кладётся в файл на диске, и весь роутер уходит в туннель.

Апстрим-репозиторий **запечатан** (архивирован read-only 2026-10-20), точка входа
форка — его финальный коммит, пин
[`d02da9bd9d8926969b766e197c434d830a83dbd8`](https://github.com/amurcanov/csqtt/commit/d02da9bd9d8926969b766e197c434d830a83dbd8)
(csqtt v2.5.0).

> ⚠️ **Лицензия.** Ядро csqtt — **PolyForm Noncommercial 1.0.0** (© amurcanov):
> использование строго некоммерческое. ROS-qtt наследует то же.

## Что изменено относительно апстрима

| Компонент | Апстрим (amurcanov) | В этом форке |
|---|---|---|
| `rust-client/` (ядро) | Android-клиент csqtt, raw-IP TUN | **без правки логики** — тот же апстрим v2.5.0; поверх — патч [`ros-qtt/ros-qtt.patch`]
| `ros-qtt/` | — | **новая папка порта под RouterOS**: сборка, C-хелпер TUN, контейнер, инсталлер, документация |
| `app/`, `rust-server/` | Android-приложение и сервер | не тронуты (можно собирать как в апстриме) |
| `README.md` | описание CSQTT | этот файл; апстримный сохранён как [`README.upstream.md`](README.upstream.md) |
| `LICENSE` | PolyForm-NC | сохранён без изменений |

## Состав папки `ros-qtt/`

| Файл | Что это |
|---|---|
| [`ros-qtt/README.md`](ros-qtt/README.md) | **Главная документация порта** — полная: архитектура, quickstart, все шаги, FAQ |
| [`ros-qtt/ros-qtt.patch`](ros-qtt/ros-qtt.patch) | патч ядра + переименование (ядро собирается как `ros-qtt`, версия `2.5.0-rosqtt.1`) |
| [`ros-qtt/build.sh`](ros-qtt/build.sh) | сборка ядра из пина апстрима: musl, статика, amd64 + arm64 |
| [`ros-qtt/tun-dispatch.c`](ros-qtt/tun-dispatch.c) | C-хелпер : открывает `/dev/net/tun`, создаёт `rosqtt0` и передаёт fd ядру через абстрактный UDS — ровно роль, которую на Android играет VpnService |
| [`ros-qtt/container/`](ros-qtt/container) | Dockerfile (alpine 3.21 + iptables + iproute2) и entrypoint: разбор csqtt-ключа, TUN, маршруты, MASQ LAN-трафика к адресу TUN |
| [`ros-qtt/install-ros-qtt.rsc`](ros-qtt/install-ros-qtt.rsc) | идемпотентный инсталлер RouterOS (`/import`, проверяем idempotent: повторный запуск ничего не ломает) |
| [`ros-qtt/ros-qtt.conf.example`](ros-qtt/ros-qtt.conf.example) | пример ключа доступа (формат `csqtt://connect?v=2&…`) |
| [`ros-qtt/pack.sh`](ros-qtt/pack.sh) | упаковка готового контейнера под RouterOS |

## Кратко: как это работает

Роутер не умеет запускать сторонний софт напрямую — но с пакетом **container**
(RouterOS 7.5+) он умеет запускать контейнеры, отдаёт им `/dev/net/tun` и root.
Этого хватает ядру csqtt:

```
 ┌────────────────────────────── MikroTik RouterOS ────────────────────────────┐
 │  LAN-клиент → маршрут роутера → ros-qtt-br → контейнер ros-qtt              │
 │                                              ├─ ros-qtt  (ядро csqtt 2.5.0)│
 │                                              │   · raw-IP TUN rosqtt0      │
 │                                              │   · MTU 1300 как в приложении│
 │                                              │   · MASQ LAN-трафика → адрес│
 │                                              │     TUN (роутер = 1 учётка) │
 │                                              └─ tun-dispatch: TUN + fd    │
 │  veth контейнера → NAT → WAN  (UDP DTLS/TURN к серверу csqtt)               │
 └────────────────────────────────────────────────────────────────────────────┘
```

При каждом запуске ядро пишет строку авторства (она же попадает в `/log`
роутера): `ROS-qtt · by qwe203 · ядро: csqtt v2.5.0 © amurcanov (PolyForm-Noncommercial-1.0.0)`.

**Быстрый старт** — смотрите [`ros-qtt/README.md`](ros-qtt/README.md) (полная
инструкция, включая сборку под arm64 и настройки `container` в RouterOS).

## Кросс-проекты с поддержкой CSQTT (от апстрима)

- Windows & Linux порт — [luminescq/focsq](https://github.com/luminescq/focsq)
- iOS-совместимый клиент — [anton48/vk-turn-proxy-ios](https://github.com/anton48/vk-turn-proxy-ios)
- Прекрасный аналог csqtt / wdtt — [hackdiaz-dev/turn-proxy-android](https://github.com/hackdiaz-dev/turn-proxy-android)

## Лицензия и авторство

- **Ядро / апстрим: [csqtt](https://github.com/amurcanov/csqtt) © amurcanov** —
  PolyForm-Noncommercial-1.0.0. Вся идея, протокол и датаплейн — его: кредит
  ядра читается в строке старта ядра, в `LICENSE` и в шапках файлов форка.
- **ROS-qtt (порт под RouterOS): by qwe203, 2026** — сборка, tun-dispatch,
  контейнер, инсталлер, документация и настоящий README.
- Использование — **только некоммерческое** (условия апстрима сохранены
  без изменений, см. [`LICENSE`](LICENSE)).

---

<!-- ═ ROS-qtt · by qwe203 · ядро csqtt © amurcanov · 2026 ═ -->
