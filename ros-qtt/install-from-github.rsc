# ══════════════════════════════════════════════════════════════════════════════
# ROS-qtt 0.1.0 — установка с GitHub в одну команду: скрипт сам скачивает
# образ контейнера из Releases этого репозитория и запускает всё. Класть файлы
# на флешку/диск роутера не нужно — ключ передаётся прямо в команде.
# by qwe203 · 2026 · ядро: csqtt v2.5.0 © amurcanov (PolyForm-Noncommercial-1.0.0)
#
# ОДНА КОМАНДА (терминал RouterOS; ключ — csqtt:// ссылка от панели):
#   :global ROSQTTKey "csqtt://connect?v=2&host=…&peer=…&password=…&hashes=…"; /tool fetch url="https://raw.githubusercontent.com/qwe203HtB/ROS-qtt/main/ros-qtt/install-from-github.rsc" dst-path=ros-qtt-from-github.rsc; /import file-name=ros-qtt-from-github.rsc
#
#   Литеральный «+» внутри хешей в ссылке записывается панелью как %2B — так и
#   оставляйте. Кавычек/процентов больше в ключе не бывает.
#
# Без ключа в переменной тоже можно: скрипт подхватит уже лежащий файл ключа
#   ($ROSQTTDisk/ros-qtt/ros-qtt.conf — скопировать туда через Winbox Files,
#   флешка не нужна) — тогда env-переменная не будет использована.
#
# ТРЕБОВАНИЯ (развернуто — см. README):
#   0. АРХИТЕКТУРА: пакет container MikroTik выпускает только для arm/arm64/x86 —
#      mipsbe/mmips/smips НЕ поддерживаются (проверка arch в скрипте есть:
#      на неподдерживаемом железе просто ошибка в /log, ничего не ломается).
#   1. RouterOS >= 7.5, пакет `container` (Packages → .npk вашей архитектуры).
#   2. Физически: /system/device-mode/update container=yes + подтверждение.
#
# Смена ключа: выполнить ту же одну команду с новым ROSQTTKey (скрипт
#   перезапишет переменную SOURCE и перезапустит контейнер).
#
# ХОДИТ ЧЕРЕЗ ТУННЕЛЬ ТОЛЬКО ВЫБРАННОЕ (не весь роутер): добавьте к той же
#   команде два глобальных перед /import:
#   :global ROSQTTMode "devices"; :global ROSQTTDevices "192.168.8.20;192.168.8.0/24"
#   (выбор по IP/подсети УСТРОЙСТВА: телефон/ПК/камера с таким адресом уйдут в
#   туннель, остальные — напрямую. Выбор между приложениями на одном устройстве
#   роутером не делается — маршрутизация работает по IP. Полный туннель, как
#   раньше: ROSQTTMode="full" или не задавать ничего. По сетям назначения:
#   ROSQTTMode="nets"; ROSQTTRoutesFor="192.168.20.0/24;10.55.0.0/16".)
# ══════════════════════════════════════════════════════════════════════════════

:global ROSQTTKey

:local disk "disk1"
:local net "172.20.0.0/24"
:local cip "172.20.0.2"
:local gw "172.20.0.1"
:local vethName "ros-qtt-veth"
:local brName "ros-qtt-br"
:local imgName "ros-qtt"
:local dnsServers "1.1.1.1,8.8.8.8"
# ── РЕЖИМ ЗАВОРОТА (см. одноимённый блок в шапке и install-ros-qtt.rsc) ─────
# Задайте ПЕРЕД import глобальные из терминала (необязательно):
#   :global ROSQTTMode   "devices"   — по устройствам (только они в туннеле)
#   :global ROSQTTDevices "192.168.8.20;192.168.8.0/24"
#   :global ROSQTTMode   "nets"      — по сетям назначения
#   :global ROSQTTRoutesFor "192.168.20.0/24;10.55.0.0/16"
# Не задали ничего → полный туннель (как раньше, 0/1+128/1).
:global ROSQTTMode
:global ROSQTTDevices
:global ROSQTTRoutesFor
:local mode $ROSQTTMode
:if ([:typeof $mode] = "nil") do={ :set mode "full" }
:local devices ""
:if ([:typeof $ROSQTTDevices] != "nil") do={ :set devices $ROSQTTDevices }
:local routesFor "0.0.0.0/1;128.0.0.0/1"
:if ([:typeof $ROSQTTRoutesFor] != "nil") do={ :set routesFor $ROSQTTRoutesFor }

:log warning "ROS-qtt: установка с GitHub; ядро csqtt © amurcanov (PolyForm-NC)"

# ── 0. Проверки: пакет container + device-mode ───────────────────────────────
:do { /container print count-only } on-error={
    :log error "ROS-qtt: пакет container не установлен (System → Packages → npk вашей архитектуры)" ; :error "no container"
}
:do { :if ([/system/device-mode/get container] != "yes") do={ \
        :log error "ROS-qtt: device-mode container=yes не подтверждён — выполните /system/device-mode/update container=yes (+ reset/перезагрузка), иначе контейнер не стартует" } \
} on-error={ }

# ── 1. Архитектура роутера → имя образа с GitHub ─────────────────────────────
:local cpu [:tolower [/system/resource/get cpu]]
:local imgArch ""
:if ([:typeof [:find $cpu "arm64"]] != "nil") do={ :set imgArch "arm64" }
:if ([:typeof [:find $cpu "x86"]] != "nil") do={ :set imgArch "amd64" }
:if ([:len $imgArch] = 0) do={
    :log error ("ROS-qtt: не знаю эту архитектуру (cpu=\"" . $cpu . "\") — только amd64 и arm64; спросите автора порта")
    :error "unsupported arch"
}
:local imgUrl ("https://github.com/qwe203HtB/ROS-qtt/releases/latest/download/ros-qtt-" . $imgArch . ".tar")
:local imgFile ($disk . "/ros-qtt.tar")
:log warning ("ROS-qtt: качаю образ для " . $imgArch . " с GitHub (~20–30 МБ)…")

:do { /tool fetch url=$imgUrl dst-path=$imgFile } on-error={
    :log error "ROS-qtt: /tool fetch не смог скачать образ — проверьте DNS и WAN, или скачайте ros-qtt-<arch>.tar вручную (Winbox → Files)"
    :error "fetch failed"
}
:if ([:len [/file find where name=$imgFile]] = 0) do={
    :log error "ROS-qtt: образ не появился на диске — смотрите /log"
    :error "no image file"
}

# ── 2. Сеть контейнера: veth + мост + адрес + NAT на WAN ─────────────────────
/interface veth
:if ([:len [find where name=$vethName]] = 0) do={ \
    add name=$vethName address=($cip."/24") gateway=$gw }
/interface bridge
:if ([:len [find where name=$brName]] = 0) do={ \
    add name=$brName comment="ROS-qtt · ядро csqtt © amurcanov" }
/ip address
:if ([:len [find where interface=$brName and address=($gw."/24")]] = 0) do={ \
    add address=($gw."/24") interface=$brName }
/interface bridge port
:if ([:len [find where interface=$vethName and bridge=$brName]] = 0) do={ \
    add bridge=$brName interface=$vethName }
/ip firewall nat
:if ([:len [find where chain=srcnat and action=masquerade and comment~"ROS-qtt"]] = 0) do={ \
    add chain=srcnat action=masquerade src-address=$net out-interface-list=WAN \
        comment="ROS-qtt · by qwe203" }

# ── 3. Ключ: envlist (SOURCE) или уже лежащий ros-qtt.conf ───────────────────
:local key ""
:if ([:typeof $ROSQTTKey] != "nil") do={ :set key $ROSQTTKey }
:local confFile ($disk . "/ros-qtt/ros-qtt.conf")
:local haveConf false
:if ([:len [/file find where name=$confFile]] > 0) do={ :set haveConf true }

:if ([:len $key] = 0 and not $haveConf) do={
    :log error "ROS-qtt: нет ключа. Повторите команду с :global ROSQTTKey \"csqtt://…\", либо положите ros-qtt/ros-qtt.conf на " . $disk . " через Winbox Files (drag&drop, без флешки)"
    :error "no key"
}

:local envListId ""
:local mountsParam ""
:if ($haveConf) do={
    # ключ из файла: монтируем каталог с ros-qtt.conf, env-переменная не нужна
    /container envs
    :if ([:len [find where list="ROSQTT" and key="SOURCE"]] > 0) do={ \
        remove [find where list="ROSQTT" and key="SOURCE"] }
    /container mounts
    :if ([:len [find where src=($disk."/ros-qtt")]] = 0) do={ \
        add list="ROSQTT-mounts" src=($disk."/ros-qtt") dst="/ros-qtt" }
    :set mountsParam "ROSQTT-mounts"
    :log warning "ROS-qtt: ключ из файла " . $confFile
} else={
    # ключ из команды: SOURCE=csqtt://… в переменных контейнера, файлов не нужно
    /container envs
    :if ([:len [find where list="ROSQTT" and key="SOURCE"]] = 0) do={ \
        add list="ROSQTT" key="SOURCE" value=$key } else={ \
        set [find where list="ROSQTT" and key="SOURCE"] value=$key }
    :set envListId "ROSQTT"
    :log warning "ROS-qtt: ключ передан через переменные контейнера (SOURCE) — файл ключа на диске не нужен"
}

# ── 4. Контейнер (идемпотентно: пересоздаём, чтобы применился свежий ключ) ───
:local rootDir ($disk . "/ros-qtt-rootfs")
:if ([:len [/container find where name=$imgName]] > 0) do={
    :do { /container stop [find where name=$imgName] } on-error={ }
    /container remove [find where name=$imgName]
}
# распаковка образа занимает минуты; ждём status=stopped, потом стартуем
:if ([:len $mountsParam] > 0) do={
    /container add file=$imgFile name=$imgName interface=$vethName \
        root-dir=$rootDir mounts=$mountsParam dns=$dnsServers \
        user=0:0 logging=yes start-on-boot=yes auto-restart-interval=30s \
        comment="ROS-qtt · by qwe203 · ядро csqtt © amurcanov (PolyForm-NC)"
} else={
    /container add file=$imgFile name=$imgName interface=$vethName \
        root-dir=$rootDir envlist=$envListId dns=$dnsServers \
        user=0:0 logging=yes start-on-boot=yes auto-restart-interval=30s \
        comment="ROS-qtt · by qwe203 · ядро csqtt © amurcanov (PolyForm-NC)"
}

:local started false
:local st ""
:foreach i in={1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20} do={ \
    :if (!$started) do={ \
        :do { :set st [/container/get [find where name=$imgName] status] } on-error={ :set st "" }
        :if ($st = "stopped") do={ \
            :do { /container/start [find where name=$imgName]; :set started true } \
                on-error={ :log error "ROS-qtt: start не прошёл — смотри /log" } \
        } else={ :delay 10s } \
    } \
}
:if (!$started) do={
    :log warning "ROS-qtt: контейнер не дошёл до stopped за разумное время (extracting?) — повторите import через пару минут; либо запустите вручную: /container start ros-qtt"
    :error "not started"
}

# ── 5. Маршруты по режиму: devices | nets | full ─────────────────────────────
:delay 5s
:if ($mode = "devices") do={
    :if ([:len $devices] = 0) do={ \
        :log error "ROS-qtt (devices): пусто ROSQTTDevices — задайте список IP/подсетей через «;» и повторите import; маршруты не менялись" \
    } else={
        /routing table
        :if ([:len [find where name="ROSQTT-rt"]] = 0) do={ \
            add name="ROSQTT-rt" fib }
        :foreach d in=[:toarray $devices] do={ \
            :if ([:len [/ip firewall mangle find where src-address=$d and comment~"ROS-qtt"]] = 0) do={ \
                /ip firewall mangle add chain=prerouting src-address=$d \
                    action=mark-routing new-routing-mark="ROSQTT-rt" passthrough=yes \
                    comment="ROS-qtt device · by qwe203" \
            } \
        }
        :if ([:len [/ip route find where routing-table="ROSQTT-rt" and comment~"ROS-qtt"]] = 0) do={ \
            /ip route add dst-address=0.0.0.0/0 gateway=$cip routing-table="ROSQTT-rt" \
                comment="ROS-qtt devices (qwe203) · ядро csqtt © amurcanov" \
        }
        :log warning ("ROS-qtt (devices): в туннель завёрнуты только " . $devices . " — остальной трафик идёт напрямую")
    }
}
:if (($mode = "nets") or ($mode = "full")) do={
    :foreach r in=[:toarray $routesFor] do={ \
        :if ([:len [/ip route find where dst-address=$r and comment~"ROS-qtt"]] = 0) do={ \
            /ip route add dst-address=$r gateway=$cip \
                comment="ROS-qtt via ros-qtt (qwe203) · ядро csqtt © amurcanov" \
        } \
    }
    :if ($mode = "nets") do={ \
        :log warning ("ROS-qtt (nets): в туннель завёрнуты только сети " . $routesFor) \
    } else={ \
        :log warning "ROS-qtt (full): ВСЕ устройства роутера завёрнуты в туннель (0/1+128/1)" \
    }
}
:if ($mode != "devices" and $mode != "nets" and $mode != "full") do={ \
    :log error ("ROS-qtt: неизвестный ROSQTTMode=" . $mode . " — маршруты не менялись (devices|nets|full)") \
}

# ══════════════════════════════════════════════════════════════════════════════
# ДИАГНОСТИКА:
#   /container print                       — статус контейнера
#   /log print where message~"ROS-qtt"     — подпись ROS-qtt · by qwe203 + логи ядра
#   /container/shell 0                     — внутри: ip route; iptables -t nat -S
# ПОЛНЫЙ ОТКАТ (убрать туннель у всех устройств):
#   /ip route remove [find where comment~"ROS-qtt"]
#   /container stop ros-qtt
# ══════════════════════════════════════════════════════════════════════════════
