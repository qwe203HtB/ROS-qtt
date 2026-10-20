# ══════════════════════════════════════════════════════════════════════════════
# ROS-qtt 0.1.0 — клиент csqtt на MikroTik RouterOS (пакет container)
# by qwe203 · 2026 · ядро: csqtt v2.5.0 © amurcanov (PolyForm-Noncommercial-1.0.0)
#
# ЧТО ЭТО. Роутер становится одним абонентом csqtt-туннеля (как телефон с
# приложением CSQTT): ВСЕ устройства, подключённые к роутеру, уходят в туннель
# (полный туннель = маршруты 0.0.0.0/1 + 128.0.0.0/1 через контейнер, дефолт).
# Трафик уходит в VK-TURN, замаскированный под медиатрафик звонка, с одним
# источником — адресом TUN контейнера. Ключ/конфиг живут в ros-qtt/ros-qtt.conf
# (см. пример).
#
# ПРЕДТРЕБОВАНИЯ (один раз, руками):
#   1. RouterOS >= 7.5 и пакет `container` (Packages → .npk вашей архитектуры).
#   2. ФИЗИЧЕСКИ на устройстве: /system/device-mode/update container=yes
#      + подтверждение (кнопка reset / холодная перезагрузка на x86). Без этого
#      контейнеры не стартуют (ограничение device-mode, дока MikroTik).
#   3. На диске ($ROSQTTDisk) должны лежать:
#        ros-qtt.tar            — образ контейнера (docker buildx + save, см. README)
#        ros-qtt/ros-qtt.conf   — ключ: csqtt:// ссылка от панели или поля
#
# ПРИМЕНЕНИЕ: правьте ОПЦИИ ниже и выполняйте /import file-name=install-ros-qtt.rsc.
# Скрипт идемпотентен: существующее не дублирует. Смена ключа — переписать
# ros-qtt.conf на диске и: /container stop ros-qtt; /container start ros-qtt
# ══════════════════════════════════════════════════════════════════════════════

# ── ОПЦИИ ────────────────────────────────────────────────────────────────────
:global ROSQTTDisk      "disk1"         ; # диск с файлами и томами (usb1/mdisk1…)
:global ROSQTTNet       "172.20.0.0/24"  ; # сеть контейнера ROS-qtt
:global ROSQTTClientIP  "172.20.0.2"     ; # IP контейнера
:global ROSQTTGatewayIP "172.20.0.1"     ; # IP моста; ТО ЖЕ ЧИСЛО в ros-qtt.conf (GATEWAY=)
:global ROSQTTImageFile "ros-qtt.tar"    ; # имя образа на диске
:global ROSQTTDNS       "1.1.1.1,8.8.8.8"  # DNS контейнера
# Маршруты, завернутые в ROS-qtt («;»-разделённый список):
#   полный туннель (по умолчанию): "0.0.0.0/1;128.0.0.0/1"
#     half-пути 0/1+128/1 перекрывают ЛЮБОЙ дефолт-маршрут, но сам дефолт и
#     доступ к роутеру не трогают — откат: просто удалить эти два маршрута;
#   только выбранное (пример): "192.168.20.0/24;10.55.0.0/16"
#     (тогда клиентские «исключения» смотрите в ros-qtt.conf: EXCLUDE_SUBNETS)
:global ROSQTTRoutesFor "0.0.0.0/1;128.0.0.0/1"

:local disk    $ROSQTTDisk
:local net     $ROSQTTNet
:local cip     $ROSQTTClientIP
:local gw      $ROSQTTGatewayIP
:local vethName "ros-qtt-veth"
:local brName   ("ros-qtt-br")
:local imgName  "ros-qtt"

:log warning "ROS-qtt (qwe203): установка; ядро csqtt © amurcanov (PolyForm-NC)"

# ── 1. Сеть контейнера: veth + мост + адрес + NAT на WAN ─────────────────────
/interface veth
:if ([:len [find where name=$vethName]] = 0) do={ \
    add name=$vethName address=($cip."/24") gateway=$gw }
/interface bridge
:if ([:len [find where name=$brName]] = 0) do={ \
    add name=$brName comment="ROS-qtt · qwe203 · ядро csqtt © amurcanov" }
/ip address
:if ([:len [find where interface=$brName and address=($gw."/24")]] = 0) do={ \
    add address=($gw."/24") interface=$brName }
/interface bridge port
:if ([:len [find where interface=$vethName and bridge=$brName]] = 0) do={ \
    add bridge=$brName interface=$vethName }
/ip firewall nat
:if ([:len [find where chain=srcnat and action=masquerade and comment~"ROS-qtt"]] = 0) do={ \
    add chain=srcnat action=masquerade src-address=$net out-interface-list=WAN \
        comment="ROS-qtt · qwe203" }

# ── 2. Том конфига: $disk/ros-qtt на роутере → /ros-qtt в контейнере ────────
/container/mounts
:if ([:len [find where src=($disk."/ros-qtt")]] = 0) do={ \
    add src=($disk."/ros-qtt") dst="/ros-qtt" }
:local mountIds [/container/mounts/find where src=($disk."/ros-qtt")]

# ── 3. Контейнер: образ из файла; user root (нужен TUN и MASQ); логи; автостарт
/container
:if ([:len [find where name=$imgName]] = 0) do={ \
    add file=($disk."/".$ROSQTTImageFile) name=$imgName \
        interface=$vethName \
        root-dir=($disk."/ros-qtt-rootfs") \
        mounts=$mountIds \
        dns=$ROSQTTDNS \
        user=0:0 \
        logging=yes start-on-boot=yes auto-restart-interval=30s \
        comment="ROS-qtt (qwe203) · ядро csqtt © amurcanov" }

# ── 4. Пуск: распаковка образа занимает минуты; ждём status=stopped и стартуем
:local imageFile ($disk."/".$ROSQTTImageFile)
:local started false
:if ([:len [/file find where name=$imageFile]] = 0) do={ \
    :log error ("ROS-qtt: не найден " . $imageFile . " — залейте образ и повторите import") \
} else={ \
    :foreach i in={1;2;3;4;5;6;7;8;9;10;11;12} do={ \
        :if (!$started) do={ \
            :local st [/container get [find where name=$imgName] status]
            :if ($st = "stopped") do={ \
                :do { /container start [find where name=$imgName]; :set started true } \
                    on-error={ :log error "ROS-qtt: start не прошёл — смотри /log" }
            } else={ :delay 10s }
        }
    }
    :if ($started) do={ \
        :delay 5s
        # ── 5. Маршруты: весь LAN-трафик роутера — в туннель (полный туннель по умолчанию)
        :foreach r in=[:toarray $ROSQTTRoutesFor] do={ \
            :if ([:len [/ip route find where dst-address=$r and comment~"ROS-qtt"]] = 0) do={ \
                /ip route add dst-address=$r gateway=$cip comment="ROS-qtt via ros-qtt (qwe203) · ядро csqtt © amurcanov" \
            } \
        }
        :log warning ("ROS-qtt: контейнер запущен (" . $imgName . "). ROS-qtt · by qwe203 · ядро csqtt © amurcanov — в /log print where message~\"ROS-qtt\"") \
    } else={ \
        :log warning ("ROS-qtt: контейнер не в stopped за разумное время (extracting?) — повторите " . \
            "import через пару минут или запустите вручную: /container start ros-qtt") \
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# ДИАГНОСТИКА (Winbox/Terminal):
#   /container print                       — статус контейнера
#   /log print where message~\"ROS-qtt\"    — подпись: ROS-qtt · by qwe203 · ядро csqtt © amurcanov
#   /container/shell 0                     — внутри: `ip route`, `iptables -t nat -S`
#   /ip route print where comment~\"ROS-qtt\" — что завернуто; удалить — откат
# ПОЛНЫЙ ОТКАТ:
#   /ip route remove [find where comment~\"ROS-qtt\"]
#   /firewall nat remove [find where comment~\"ROS-qtt\"]
#   /container remove ros-qtt; /interface veth remove ros-qtt-veth
#   /interface bridge remove ros-qtt-br
# ══════════════════════════════════════════════════════════════════════════════
