#!/usr/bin/env bash
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
#   --auto-proxy                Использовать список доступных публичных прокси (автоматическое переключение)
#   --help                      Показать справку
#
# Примеры:
#   ./scripts/download-offline-artifacts.sh
#   ./scripts/download-offline-artifacts.sh --kube-version 1.35.0 --cni calico
#   ./scripts/download-offline-artifacts.sh --package-type deb --cni flannel
#   ./scripts/download-offline-artifacts.sh --kube-version 1.36.1 --cni calico  --socks5 "192.168.0.150:9050" --proxy-user tgproxy:xVGavfDim6nxSv
#   ./scripts/download-offline-artifacts.sh --kube-version 1.36.1 --auto-proxy
# ============================================================

set -euo pipefail

# Значения по умолчанию
KUBE_VERSION="1.36.1"
CRI="containerd"
CNI="calico"
HELM_VERSION="v4.0.4"
CERT_MANAGER_VERSION="v1.19.2"
METALLB_CHART_VERSION="0.15.3"
INGRESS_NGINX_CHART_VERSION="4.12.0"
ARGOCD_CHART_VERSION="9.5.14"
NFS_CSI_DRIVER_VERSION="4.13.2"
RELOADER_CHART_VERSION="2.2.11"
ENVOY_GATEWAY_VERSION="v1.8.0"
OUTPUT_DIR="tmp/offline"
PACKAGE_TYPE="deb"
SOCKS5_PROXY=""
PROXY_USER=""
USE_AUTO_PROXY=0
CURL_PROXY_OPTS=""
CURRENT_PROXY_INDEX=0

# Список доступных публичных SOCKS5 прокси (проверены на 2024)
# Формат: "ip:port:user:password" или "ip:port" (без авторизации)
declare -a PUBLIC_PROXIES=(
    "192.168.0.150:9050:proxy:xVGavfDim6nxSv"      # Приватный
    "138.201.243.73:1080"                          # SOCKS5 proxy
    "103.145.45.97:55443"                          # Public proxy
    "45.129.201.238:7777"                          # SOCKS5
    "185.220.101.45:9050"                          # Tor exit node (может быть медленным)
    
)

# Функция логирования
log_info() {
    echo "[INFO] $*"
}

log_warn() {
    echo "[WARN] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        --kube-version)   KUBE_VERSION="$2"; shift 2 ;;
        --cri)            CRI="$2"; shift 2 ;;
        --cni)            CNI="$2"; shift 2 ;;
        --helm-version)   HELM_VERSION="$2"; shift 2 ;;
        --cert-manager-version) CERT_MANAGER_VERSION="$2"; shift 2 ;;
        --metallb-chart-version) METALLB_CHART_VERSION="$2"; shift 2 ;;
        --argocd-chart-version) ARGOCD_CHART_VERSION="$2"; shift 2 ;;
        --nfs-csi-driver-version) NFS_CSI_DRIVER_VERSION="$2"; shift 2 ;;
        --output)         OUTPUT_DIR="$2"; shift 2 ;;
        --package-type)   PACKAGE_TYPE="$2"; shift 2 ;;
        --socks5)         SOCKS5_PROXY="$2"; shift 2 ;;
        --proxy-user)     PROXY_USER="$2"; shift 2 ;;
        --auto-proxy)     USE_AUTO_PROXY=1; shift ;;
        --help)
            head -n 32 "$0" | tail -n 29 | sed 's/^# //'
            exit 0
            ;;
        *) log_error "Неизвестная опция: $1"; exit 1 ;;
    esac
done

# Валидация типа пакетов
if [[ "$PACKAGE_TYPE" != "deb" && "$PACKAGE_TYPE" != "rpm" ]]; then
    log_error "--package-type должен быть 'deb' или 'rpm', получено: $PACKAGE_TYPE"
    exit 1
fi

# ============================================================
# Функции управления прокси
# ============================================================

# Функция для проверки доступности прокси
test_proxy() {
    local proxy_string="$1"
    local test_url="https://example.com"
    
    local socks5_addr=""
    local proxy_user_creds=""
    
    # Парсим строку прокси
    IFS=':' read -r host port user pass <<< "$proxy_string"
    
    if [[ -z "$user" ]] || [[ "$user" == "$pass" ]]; then
        # Без авторизации
        socks5_addr="$host:$port"
    else
        # С авторизацией
        socks5_addr="$host:$port"
        proxy_user_creds="$user:$pass"
    fi
    
    local curl_cmd="curl -s --connect-timeout 5 --max-time 10 --socks5 $socks5_addr"
    if [[ -n "$proxy_user_creds" ]]; then
        curl_cmd="$curl_cmd --proxy-user $proxy_user_creds"
    fi
    curl_cmd="$curl_cmd -o /dev/null -w '%{http_code}' $test_url"
    
    local http_code=$(eval "$curl_cmd" 2>/dev/null || echo "000")
    
    if [[ "$http_code" == "200" ]]; then
        return 0
    else
        return 1
    fi
}

# Функция для установки текущего прокси
set_proxy() {
    local proxy_string="$1"
    local host port user pass
    
    IFS=':' read -r host port user pass <<< "$proxy_string"
    
    SOCKS5_PROXY="$host:$port"
    
    if [[ -z "$user" ]] || [[ "$user" == "$pass" ]]; then
        PROXY_USER=""
    else
        PROXY_USER="$user:$pass"
    fi
    
    update_curl_proxy_opts
}

# Функция обновления опций curl прокси
update_curl_proxy_opts() {
    CURL_PROXY_OPTS=""
    if [[ -n "$SOCKS5_PROXY" ]]; then
        CURL_PROXY_OPTS="--socks5 $SOCKS5_PROXY"
        if [[ -n "$PROXY_USER" ]]; then
            CURL_PROXY_OPTS="$CURL_PROXY_OPTS --proxy-user $PROXY_USER"
        fi
    fi
}

# Функция для поиска работающего прокси
find_working_proxy() {
    log_info "Поиск доступного прокси..."
    
    for i in "${!PUBLIC_PROXIES[@]}"; do
        local proxy="${PUBLIC_PROXIES[$i]}"
        log_info "Проверка прокси [$((i+1))/${#PUBLIC_PROXIES[@]}]: $proxy"
        
        if test_proxy "$proxy"; then
            log_info "✓ Прокси доступен: $proxy"
            set_proxy "$proxy"
            CURRENT_PROXY_INDEX=$i
            return 0
        else
            log_warn "✗ Прокси недоступен: $proxy"
        fi
    done
    
    log_error "Не найдено ни одного доступного прокси"
    return 1
}

# Функция для переключения на следующий прокси
switch_to_next_proxy() {
    local next_index=$(( (CURRENT_PROXY_INDEX + 1) % ${#PUBLIC_PROXIES[@]} ))
    
    if [[ $next_index -eq $CURRENT_PROXY_INDEX ]]; then
        log_error "Все прокси исчерпаны"
        return 1
    fi
    
    local next_proxy="${PUBLIC_PROXIES[$next_index]}"
    log_warn "Переключение на следующий прокси: $next_proxy"
    
    if test_proxy "$next_proxy"; then
        set_proxy "$next_proxy"
        CURRENT_PROXY_INDEX=$next_index
        return 0
    else
        return 1
    fi
}

# Инициализация прокси
if [[ $USE_AUTO_PROXY -eq 1 ]]; then
    find_working_proxy || {
        log_error "Не удалось найти работающий прокси. Продолжу без прокси."
        SOCKS5_PROXY=""
        PROXY_USER=""
    }
elif [[ -n "$SOCKS5_PROXY" ]]; then
    update_curl_proxy_opts
fi

KUBE_MAJOR_MINOR=$(echo "$KUBE_VERSION" | grep -oP '^\d+\.\d+')

echo "============================================================"
echo " Скачивание offline-артефактов"
echo "============================================================"
echo " Kubernetes : $KUBE_VERSION"
echo " CRI        : $CRI"
echo " CNI        : $CNI"
echo " Helm       : $HELM_VERSION"
echo " cert-manager: $CERT_MANAGER_VERSION (OCI)"
echo " MetalLB    : $METALLB_CHART_VERSION"
echo " ArgoCD     : $ARGOCD_CHART_VERSION"
echo " NFS CSI    : $NFS_CSI_DRIVER_VERSION"
echo " Reloader   : $RELOADER_CHART_VERSION"
echo " Envoy GW   : $ENVOY_GATEWAY_VERSION"
echo " Тип пакетов: $PACKAGE_TYPE (${PACKAGE_TYPE^^})"
if [[ -n "$SOCKS5_PROXY" ]]; then
    echo " SOCKS5     : $SOCKS5_PROXY"
    if [[ -n "$PROXY_USER" ]]; then
        echo " Прокси-юзер: ${PROXY_USER%:*}"
    fi
fi
echo " Авто-прокси: $([[ $USE_AUTO_PROXY -eq 1 ]] && echo 'ДА' || echo 'НЕТ')"
echo " Выходной каталог: $OUTPUT_DIR"
echo "============================================================"

# Создание структуры каталогов
mkdir -p "$OUTPUT_DIR"/{packages,cri/{containerd,crio},cni,images,utils/helm-charts,utils/helm-plugins/helm-diff}

# ============================================================
# Функция скачивания с проверкой и автопереключением прокси
# ============================================================
download() {
    local url="$1"
    local dest="$2"
    local desc="$3"
    local max_retries=3
    local retry_count=0

    if [[ -f "$dest" ]]; then
        echo "  [SKIP] $desc (уже существует: $dest)"
        return 0
    fi

    echo "  [GET]  $desc"
    echo "        URL: $url"
    
    while [[ $retry_count -lt $max_retries ]]; do
        # Формирование команды curl с опциями прокси
        local curl_cmd="curl -fSL --connect-timeout 30 --max-time 600"
        if [[ -n "$CURL_PROXY_OPTS" ]]; then
            curl_cmd="$curl_cmd $CURL_PROXY_OPTS"
        fi
        curl_cmd="$curl_cmd -o \"$dest\" \"$url\""
        
        if eval "$curl_cmd"; then
            echo "        OK: $(du -h "$dest" | cut -f1)"
            return 0
        else
            local curl_exit_code=$?
            retry_count=$((retry_count + 1))
            
            # Проверяем код ошибки
            if [[ $curl_exit_code -eq 22 ]]; then
                # HTTP ошибка (403, 404 и т.д.)
                echo "        HTTP ошибка. Попытка переключения прокси... ($retry_count/$max_retries)"
                rm -f "$dest"
                
                if [[ $USE_AUTO_PROXY -eq 1 ]]; then
                    if ! switch_to_next_proxy; then
                        break
                    fi
                    update_curl_proxy_opts
                else
                    break
                fi
            elif [[ $curl_exit_code -eq 7 ]]; then
                # Ошибка соединения
                echo "        Ошибка соединения. Повтор... ($retry_count/$max_retries)"
                rm -f "$dest"
                sleep 2
            else
                echo "        Ошибка curl ($curl_exit_code). Повтор... ($retry_count/$max_retries)"
                rm -f "$dest"
                sleep 1
            fi
        fi
    done
    
    echo "        ОШИБКА: не удалось скачать $url"
    rm -f "$dest"
    return 1
}

# ============================================================
# Функция скачивания Helm-чарта
# ============================================================
download_helm_chart() {
    local repo_url="$1"
    local chart_name="$2"
    local chart_version="$3"
    local dest="$4"
    local desc="$5"
    local max_retries=3
    local retry_count=0

    if [[ -f "$dest" ]]; then
        echo "  [SKIP] $desc (уже существует: $dest)"
        return 0
    fi

    echo "  [HELM] $desc"
    
    while [[ $retry_count -lt $max_retries ]]; do
        # Конфигурация прокси для helm если необходимо
        if [[ -n "$CURL_PROXY_OPTS" ]]; then
            export HTTP_PROXY="socks5://${SOCKS5_PROXY}"
            if [[ -n "$PROXY_USER" ]]; then
                export HTTP_PROXY="socks5://${PROXY_USER}@${SOCKS5_PROXY}"
            fi
            export HTTPS_PROXY="$HTTP_PROXY"
        fi
        
        helm repo add _tmp "$repo_url" 2>/dev/null || true
        helm repo update _tmp 2>/dev/null || true
        
        if helm pull _tmp/"$chart_name" --version "$chart_version" --destination "$(dirname "$dest")" 2>/dev/null; then
            mv "$(dirname "$dest")"/"${chart_name}-${chart_version}.tgz" "$dest" 2>/dev/null || \
            mv "$(dirname "$dest")"/"${chart_name#*/}-${chart_version}.tgz" "$dest" 2>/dev/null || true
            
            if [[ -f "$dest" ]]; then
                echo "        OK: $(du -h "$dest" | cut -f1)"
                helm repo remove _tmp 2>/dev/null || true
                unset HTTP_PROXY HTTPS_PROXY
                return 0
            fi
        fi
        
        retry_count=$((retry_count + 1))
        if [[ $retry_count -lt $max_retries ]]; then
            echo "        Ошибка при скачивании чарта. Повтор... ($retry_count/$max_retries)"
            
            if [[ $USE_AUTO_PROXY -eq 1 ]]; then
                if switch_to_next_proxy; then
                    update_curl_proxy_opts
                fi
            fi
            sleep 2
        fi
    done
    
    echo "        ОШИБКА: не удалось скачать чарт $chart_name"
    helm repo remove _tmp 2>/dev/null || true
    unset HTTP_PROXY HTTPS_PROXY
    return 1
}

# ============================================================
# 1. Kubernetes пакеты (RPM или DEB в зависимости от выбора)
# ============================================================
echo ""
echo ">>> Пакеты Kubernetes v$KUBE_VERSION ($PACKAGE_TYPE)"

if [[ "$PACKAGE_TYPE" == "deb" ]]; then
    # DEB пакеты
    download \
        "https://pkgs.k8s.io/core:/stable:/v${KUBE_MAJOR_MINOR}/deb/amd64/kubeadm_${KUBE_VERSION}-1.1_amd64.deb" \
        "$OUTPUT_DIR/packages/kubeadm_${KUBE_VERSION}-1.1_amd64.deb" \
        "kubeadm DEB"

    download \
        "https://pkgs.k8s.io/core:/stable:/v${KUBE_MAJOR_MINOR}/deb/amd64/kubelet_${KUBE_VERSION}-1.1_amd64.deb" \
        "$OUTPUT_DIR/packages/kubelet_${KUBE_VERSION}-1.1_amd64.deb" \
        "kubelet DEB"

    download \
        "https://pkgs.k8s.io/core:/stable:/v${KUBE_MAJOR_MINOR}/deb/amd64/kubectl_${KUBE_VERSION}-1.1_amd64.deb" \
        "$OUTPUT_DIR/packages/kubectl_${KUBE_VERSION}-1.1_amd64.deb" \
        "kubectl DEB"

else
    # RPM пакеты
    download \
        "https://pkgs.k8s.io/core:/stable:/v${KUBE_MAJOR_MINOR}/rpm/x86_64/kubeadm-${KUBE_VERSION}-150000.1.1.x86_64.rpm" \
        "$OUTPUT_DIR/packages/kubeadm-${KUBE_VERSION}.x86_64.rpm" \
        "kubeadm RPM"

    download \
        "https://pkgs.k8s.io/core:/stable:/v${KUBE_MAJOR_MINOR}/rpm/x86_64/kubelet-${KUBE_VERSION}-150000.1.1.x86_64.rpm" \
        "$OUTPUT_DIR/packages/kubelet-${KUBE_VERSION}.x86_64.rpm" \
        "kubelet RPM"

    download \
        "https://pkgs.k8s.io/core:/stable:/v${KUBE_MAJOR_MINOR}/rpm/x86_64/kubectl-${KUBE_VERSION}-150000.1.1.x86_64.rpm" \
        "$OUTPUT_DIR/packages/kubectl-${KUBE_VERSION}.x86_64.rpm" \
        "kubectl RPM"
fi

# ============================================================
# 2. CNI манифесты
# ============================================================
echo ""
echo ">>> CNI: $CNI"

if [[ "$CNI" == "calico" ]]; then
    # Определяем версию Calico по матрице
    declare -A CALICO_MATRIX=(
        ["1.28"]="v3.26.4" ["1.29"]="v3.27.0" ["1.30"]="v3.27.3"
        ["1.31"]="v3.28.0" ["1.32"]="v3.28.1" ["1.33"]="v3.29.0"
        ["1.34"]="v3.29.1" ["1.35"]="v3.29.2" ["1.36"]="v3.30.0"
    )
    CALICO_VERSION="${CALICO_MATRIX[$KUBE_MAJOR_MINOR]:-v3.30.0}"

    download \
        "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" \
        "$OUTPUT_DIR/cni/tigera-operator.yaml" \
        "Calico tigera-operator v${CALICO_VERSION}"

elif [[ "$CNI" == "cilium" ]]; then
    # Определяем версию Cilium по матрице
    declare -A CILIUM_MATRIX=(
        ["1.28"]="1.16.7" ["1.29"]="1.16.7" ["1.30"]="1.17.8"
        ["1.31"]="1.17.8" ["1.32"]="1.18.9" ["1.33"]="1.18.9"
        ["1.34"]="1.19.3" ["1.35"]="1.19.3" ["1.36"]="1.19.3"
    )
    CILIUM_VERSION="${CILIUM_MATRIX[$KUBE_MAJOR_MINOR]:-1.19.3}"

    download \
        "https://helm.cilium.io/cilium-${CILIUM_VERSION}.tgz" \
        "$OUTPUT_DIR/cni/cilium-${CILIUM_VERSION}.tgz" \
        "Cilium helm chart v${CILIUM_VERSION}"
fi

# ============================================================
# 3. Утилиты
# ============================================================
echo ""
echo ">>> Утилиты"

# Helm
download \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    "$OUTPUT_DIR/utils/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    "Helm $HELM_VERSION"

# cert-manager (OCI chart — скачиваем через helm pull)
echo ""
echo ">>> cert-manager (OCI chart)"
if [[ ! -f "$OUTPUT_DIR/utils/cert-manager-${CERT_MANAGER_VERSION}.tgz" ]]; then
    echo "  [HELM] cert-manager $CERT_MANAGER_VERSION (OCI)"
    
    # Конфигурация прокси для helm
    if [[ -n "$CURL_PROXY_OPTS" ]]; then
        export HTTP_PROXY="socks5://${SOCKS5_PROXY}"
        if [[ -n "$PROXY_USER" ]]; then
            export HTTP_PROXY="socks5://${PROXY_USER}@${SOCKS5_PROXY}"
        fi
        export HTTPS_PROXY="$HTTP_PROXY"
    fi
    
    helm pull "oci://quay.io/jetstack/charts/cert-manager" \
        --version "$CERT_MANAGER_VERSION" \
        --destination "$OUTPUT_DIR/utils/" 2>/dev/null || \
    echo "  [WARN] Не удалось скачать cert-manager OCI chart — требуется helm v3.8+"
    
    unset HTTP_PROXY HTTPS_PROXY
else
    echo "  [SKIP] cert-manager (уже существует)"
fi

# ============================================================
# 4. Helm-чарты
# ============================================================
echo ""
echo ">>> Helm-чарты"

# MetalLB
download_helm_chart \
    "https://metallb.github.io/metallb" \
    "metallb" \
    "$METALLB_CHART_VERSION" \
    "$OUTPUT_DIR/utils/helm-charts/metallb-${METALLB_CHART_VERSION}.tgz" \
    "MetalLB Helm chart v${METALLB_CHART_VERSION}" || true

# Ingress Nginx
download_helm_chart \
    "https://kubernetes.github.io/ingress-nginx" \
    "ingress-nginx" \
    "$INGRESS_NGINX_CHART_VERSION" \
    "$OUTPUT_DIR/utils/helm-charts/ingress-nginx-${INGRESS_NGINX_CHART_VERSION}.tgz" \
    "Ingress Nginx Helm chart ${INGRESS_NGINX_CHART_VERSION}" || true

# ArgoCD
download_helm_chart \
    "https://argoproj.github.io/argo-helm" \
    "argo-cd" \
    "$ARGOCD_CHART_VERSION" \
    "$OUTPUT_DIR/utils/helm-charts/argo-cd-${ARGOCD_CHART_VERSION}.tgz" \
    "ArgoCD Helm chart ${ARGOCD_CHART_VERSION}" || true

# NFS CSI Driver
download_helm_chart \
    "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts" \
    "csi-driver-nfs" \
    "$NFS_CSI_DRIVER_VERSION" \
    "$OUTPUT_DIR/utils/helm-charts/csi-driver-nfs-${NFS_CSI_DRIVER_VERSION}.tgz" \
    "NFS CSI Driver Helm chart v${NFS_CSI_DRIVER_VERSION}" || true

# Stakater Reloader
download_helm_chart \
    "https://stakater.github.io/stakater-charts" \
    "reloader" \
    "$RELOADER_CHART_VERSION" \
    "$OUTPUT_DIR/utils/helm-charts/reloader-${RELOADER_CHART_VERSION}.tgz" \
    "Stakater Reloader Helm chart v${RELOADER_CHART_VERSION}" || true

# Envoy Gateway (OCI chart)
echo ""
echo ">>> Envoy Gateway (OCI chart)"
if [[ ! -f "$OUTPUT_DIR/utils/helm-charts/envoy-gateway-${ENVOY_GATEWAY_VERSION}.tgz" ]]; then
    echo "  [HELM] Envoy Gateway $ENVOY_GATEWAY_VERSION (OCI)"
    
    # Конфигурация прокси для helm
    if [[ -n "$CURL_PROXY_OPTS" ]]; then
        export HTTP_PROXY="socks5://${SOCKS5_PROXY}"
        if [[ -n "$PROXY_USER" ]]; then
            export HTTP_PROXY="socks5://${PROXY_USER}@${SOCKS5_PROXY}"
        fi
        export HTTPS_PROXY="$HTTP_PROXY"
    fi
    
    helm pull "oci://docker.io/envoyproxy/gateway-helm" \
        --version "$ENVOY_GATEWAY_VERSION" \
        --destination "$OUTPUT_DIR/utils/helm-charts/" 2>/dev/null || \
    echo "  [WARN] Не удалось скачать Envoy Gateway OCI chart — требуется helm v3.8+"
    
    unset HTTP_PROXY HTTPS_PROXY
else
    echo "  [SKIP] Envoy Gateway (уже существует)"
fi

# ============================================================
# 5. Helm-плагин helm-diff
# ============================================================
echo ""
echo ">>> Helm-плагины"

HELM_DIFF_DIR="$OUTPUT_DIR/utils/helm-plugins/helm-diff"
if [[ ! -d "$HELM_DIFF_DIR/.git" ]]; then
    echo "  [GET]  helm-diff plugin"
    
    # Конфигурация прокси для git если необходимо
    if [[ -n "$CURL_PROXY_OPTS" ]]; then
        export HTTP_PROXY="socks5://${SOCKS5_PROXY}"
        if [[ -n "$PROXY_USER" ]]; then
            export HTTP_PROXY="socks5://${PROXY_USER}@${SOCKS5_PROXY}"
        fi
        export HTTPS_PROXY="$HTTP_PROXY"
    fi
    
    rm -rf "$HELM_DIFF_DIR"
    git clone --depth 1 https://github.com/databus23/helm-diff.git "$HELM_DIFF_DIR" || true
    
    unset HTTP_PROXY HTTPS_PROXY
else
    echo "  [SKIP] helm-diff plugin (уже существует)"
fi

# ============================================================
# Итоги
# ============================================================
echo ""
echo "============================================================"
echo " Скачивание завершено"
echo "============================================================"
echo ""
echo "Структура каталога $OUTPUT_DIR/:"
if command -v tree &>/dev/null; then
    tree -h "$OUTPUT_DIR" 2>/dev/null || find "$OUTPUT_DIR" -type f | sort
else
    find "$OUTPUT_DIR" -type f | sort
fi
echo ""
echo "Следующие шаги:"
echo "  1. Перенесите каталог $OUTPUT_DIR/ на все ноды кластера"
echo "  2. Запустите установку с флагом:"
echo "     make install ENV=homelab EXTRA='-e \"k8s_install_mode=offline\"'"
echo ""
echo "ПРИМЕЧАНИЕ: Образы Kubernetes (k8s-images.tar) нужно создать"
echo "отдельно на машине с доступом в интернет:"
echo ""
echo "  kubeadm config images pull --kubernetes-version=$KUBE_VERSION"
echo "  ctr -n k8s.io images export $OUTPUT_DIR/images/k8s-images.tar \\"
echo "    \$(ctr -n k8s.io images list -q | grep -v sha256)"
echo ""
if [[ "$CNI" == "calico" ]]; then
    echo "Для Calico-образов:"
    echo "  ctr -n k8s.io images pull quay.io/tigera/operator:\${CALICO_VERSION}"
    echo "  ctr -n k8s.io images export $OUTPUT_DIR/images/calico-images.tar \\"
    echo "    \$(ctr -n k8s.io images list -q | grep -E 'calico|tigera')"
    echo ""
elif [[ "$CNI" == "cilium" ]]; then
    echo "Для Cilium-образов:"
    echo "  helm template cilium cilium/cilium --version \${CILIUM_VERSION} |"
    echo "    grep 'image:' | awk '{print \$2}' | sed 's/\"//g' | sort -u"
    echo "  # затем pull каждого образа и export в cilium-images.tar:"
    echo "  ctr -n k8s.io images export $OUTPUT_DIR/images/cilium-images.tar \\"
    echo "    \$(ctr -n k8s.io images list -q | grep -E 'cilium')"
    echo ""
fi
