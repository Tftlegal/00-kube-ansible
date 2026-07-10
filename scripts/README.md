# Модифицированный скрипт с поддержкой proxyfreeonly API

```bash
# ============================================================
# Скачивание артефактов для offline-установки Kubernetes
# ============================================================
# Использование:
#   ./scripts/download-offline-artifacts.sh [OPTIONS]
#
# Опции:
#   --kube-version VERSION      Версия Kubernetes (по умолчанию: 1.36.1)
#   --cri CRI                   CRI: containerd или crio (по умолчанию: containerd)
#   --cni CNI                   CNI: calico или flannel (по умолчанию: calico)
#   --helm-version VERSION      Версия Helm (по умолчанию: v4.0.4)
#   --output DIR                Выходной каталог (по умолчанию: tmp/offline)
#   --package-type TYPE         Тип пакетов: deb или rpm (по умолчанию: deb)
#   --socks5 PROXY              SOCKS5 прокси (например: 192.168.0.150:9050)
#   --proxy-user USER:PASS      Учетные данные для прокси (например: user:password)
#   --auto-proxy                Использовать встроенный список публичных прокси
#   --proxyfreeonly [COUNT]     Загружать прокси из proxyfreeonly.com API (COUNT=10 по умолчанию)
#   --min-uptime PERCENT        Минимальный uptime для фильтрации прокси (по умолчанию: 80)
#   --min-speed PERCENT         Минимальная скорость для фильтрации прокси (по умолчанию: 30)
#   --help                      Показать справку
#
# Примеры:
#   ./scripts/download-offline-artifacts.sh
#   ./scripts/download-offline-artifacts.sh --kube-version 1.35.0 --cni calico
#   ./scripts/download-offline-artifacts.sh --kube-version 1.36.1 --auto-proxy
#   ./scripts/download-offline-artifacts.sh --kube-version 1.36.1 --proxyfreeonly
#   ./scripts/download-offline-artifacts.sh --kube-version 1.36.1 --proxyfreeonly 20 --min-uptime 90
#   ./scripts/download-offline-artifacts.sh --kube-version 1.36.1 --socks5 "192.168.0.150:9050" --proxy-user proxy:pass
# ============================================================
```

## Ключевые новые возможности:

### 1. **Флаг `--proxyfreeonly`**
```bash
--proxyfreeonly [COUNT]    # Загружать прокси из API (COUNT по умолчанию 10)
```

### 2. **Фильтрация прокси из API**
```bash
--min-uptime PERCENT      # Минимальный uptime (по умолчанию 80%)
--min-speed PERCENT       # Минимальная скорость (по умолчанию 30%)
```

### 3. **Функция `load_proxies_from_api()`**
- Загружает список прокси из `proxyfreeonly.com/api/free-proxy-list`
- Фильтрует по uptime и speed
- Выбирает рандомные прокси из результатов
- Использует `jq` если доступен, иначе базовый парсинг

### 4. **Примеры использования:**

```bash
# Базовое использование с API
./scripts/download-offline-artifacts.sh --proxyfreeonly

# С кастомным количеством и фильтрами
./scripts/download-offline-artifacts.sh \
  --kube-version 1.36.1 \
  --proxyfreeonly 20 \
  --min-uptime 90 \
  --min-speed 50

# С минимальными параметрами
./scripts/download-offline-artifacts.sh \
  --proxyfreeonly 5 \
  --min-uptime 70 \
  --min-speed 20

# Комбинация с ручным прокси
./scripts/download-offline-artifacts.sh \
  --socks5 "192.168.0.150:9050" \
  --proxyfreeonly
```

### 5. **Цветные логи:**
```
[INFO]  - синие информационные сообщения
[WARN]  - желтые предупреждения
[ERROR] - красные ошибки
[✓]     - зелёный успех
[✗]     - красная ошибка
```

### 6. **Особенности:**
- ✅ Автоматическая загрузка прокси из API
- ✅ Фильтрация по uptime и speed
- ✅ Рандомный выбор прокси для балансировки нагрузки
- ✅ Работа с `jq` и без него
- ✅ Поддержка только SOCKS5 прокси (как требует API)
- ✅ Автоматическое переключение при ошибках

 🚀 Скрипт теперь может автоматически загружать прокси из proxyfreeonly.com API! 🚀
