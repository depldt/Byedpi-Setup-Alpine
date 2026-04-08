#!/bin/bash
# Глобальные константы
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
readonly SCRIPT_NAME=$(basename "$0")
readonly LOG_FILE="/tmp/${SCRIPT_NAME}.log"
readonly CONFIG_FILE="/etc/conf.d/ciadpi"
readonly BYEDPI_DIR="$HOME/ciadpi"
readonly TEMP_DIR=$(mktemp -d)
readonly setup_repo="https://github.com/depldt/Byedpi-Setup-Alpine/raw/refs/heads/main/assets/Byedpi-Setup-main.zip"

# Проверка Docker (совместимо с cgroups v1/v2)
is_docker() {
    [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null || grep -q docker /proc/self/cgroup 2>/dev/null
}

# Цвета для логирования
readonly COLOR_GREEN='\e[32m'
readonly COLOR_RED='\e[31m'
readonly COLOR_YELLOW='\e[33m'
readonly COLOR_RESET='\e[0m'

log() {
    local color=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    case $color in
        green) echo -e "${COLOR_GREEN}[INFO] $timestamp: $message${COLOR_RESET}" | tee -a "$LOG_FILE" ;;
        red)   echo -e "${COLOR_RED}[ERROR] $timestamp: $message${COLOR_RESET}" >&2 | tee -a "$LOG_FILE" ;;
        yellow)echo -e "${COLOR_YELLOW}[WARN] $timestamp: $message${COLOR_RESET}" | tee -a "$LOG_FILE" ;;
        *)     echo "[LOG] $timestamp: $message" | tee -a "$LOG_FILE" ;;
    esac
}

safe_mkdir() {
    local dir_path=$1
    if [[ -d "$dir_path" ]]; then
        log yellow "Директория $dir_path уже существует. Очистка..."
        rm -rf "$dir_path"
    fi
    mkdir -p "$dir_path"
    log green "Создана директория: $dir_path"
}

safe_mkdir_no_rm() {
    local dir_path=$1
    if [[ -d "$dir_path" ]]; then
        log yellow "Директория $dir_path уже существует."
    else
        mkdir -p "$dir_path"
        log green "Создана директория: $dir_path"
    fi
}

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO=$ID
    else
        log red "Не могу определить дистрибутив. Проверьте файл /etc/os-release."
        exit 1
    fi
}

install_arch() {
    local packages=("$@")
    log green "Обнаружен Arch Linux. Устанавливаю пакеты: ${packages[*]}"
    log yellow "Требуются права суперпользователя. Введите пароль root:"
    su -c "pacman -S --noconfirm ${packages[*]}"
}

install_debian() {
    local packages=("$@")
    log green "Обнаружен Debian. Устанавливаю пакеты: ${packages[*]}"
    su -c "apt update && apt install -y ${packages[*]}" || { log red "Ошибка установки пакетов"; exit 1; }
    log green "Установка завершена."
}

install_ubuntu() {
    local packages=("$@")
    log green "Обнаружен Ubuntu. Устанавливаю пакеты: ${packages[*]}"
    su -c "apt update && apt install -y ${packages[*]}" || { log red "Ошибка установки пакетов"; exit 1; }
    log green "Установка завершена."
}

install_other() {
    local packages=("$@")
    log yellow "Ваш дистрибутив ($DISTRO) не поддерживается напрямую."
    if command -v zypper >/dev/null 2>&1; then su -c "zypper install -y ${packages[*]}"
    elif command -v dnf >/dev/null 2>&1; then su -c "dnf install -y ${packages[*]}"
    elif command -v yum >/dev/null 2>&1; then su -c "yum install -y ${packages[*]}"
    else log red "Не удалось найти менеджер пакетов. Установите вручную: ${packages[*]}"; exit 1; fi
}

check_dependencies() {
    detect_distro
    local dependencies=("gcc" "make" "unzip" "curl")
    if [[ "$DISTRO" == "alpine" ]]; then
        dependencies+=("openrc" "linux-headers" "openssl-dev" "zlib-dev" "build-base")
    fi

    local missing=()
    for dep in "${dependencies[@]}"; do
        if [[ "$DISTRO" == "alpine" ]] && command -v apk &> /dev/null; then
            if ! apk info -e "$dep" &> /dev/null 2>&1; then missing+=("$dep"); fi
        else
            if ! command -v "$dep" &> /dev/null; then missing+=("$dep"); fi
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log yellow "Не найдены необходимые зависимости: ${missing[*]}"
        case "$DISTRO" in
            arch) install_arch "${missing[@]}" ;;
            debian) install_debian "${missing[@]}" ;;
            ubuntu) install_ubuntu "${missing[@]}" ;;
            alpine)
                log green "Обнаружен Alpine Linux. Устанавливаю пакеты через apk..."
                su -c "apk update && apk add --no-cache ${missing[*]}" || { log red "Ошибка установки пакетов через apk"; exit 1; }
                log green "Установка зависимостей завершена."
                ;;
            *) install_other "${missing[@]}" ;;
        esac
    else
        log green "Все необходимые пакеты установлены."
    fi

    if [[ "$DISTRO" == "alpine" ]]; then
        [[ ":$PATH:" != *":/sbin:"* ]] && export PATH="/sbin:$PATH"
        [[ ":$PATH:" != *":/usr/sbin:"* ]] && export PATH="/usr/sbin:$PATH"
    fi
}

safe_download() {
    local url=$1 output=$2 cache_dir="/tmp/cache/byedpi"
    safe_mkdir "$cache_dir"
    local cache_file="$cache_dir/$(basename "$output")"
    if [[ -f "$cache_file" ]]; then
        log yellow "Используем кэшированную версию: $cache_file"
        cp "$cache_file" "$output"
    else
        log green "Загрузка: $url"
        if ! curl -L -o "$output" "$url"; then log red "Не удалось загрузить $url"; return 1; fi
        cp "$output" "$cache_file"
    fi
}

install_byedpi() {
    local repo_url="https://github.com/hufrea/byedpi/archive/refs/tags/v0.17.3.zip"
    local zip_file="$TEMP_DIR/byedpi-release.zip"
    safe_download "$repo_url" "$zip_file"
    unzip -q "$zip_file" -d "$TEMP_DIR"
    
    local extracted_dir
    extracted_dir=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "byedpi-*" | head -n1)
    if [[ -z "$extracted_dir" || ! -d "$extracted_dir" ]]; then
        log red "Не удалось найти извлечённую директорию в $TEMP_DIR"; exit 1
    fi
    
    cd "$extracted_dir" || exit 1
    log yellow "Компиляция ByeDPI..."
    if make; then
        safe_mkdir "$BYEDPI_DIR"
        mv ciadpi "$BYEDPI_DIR/ciadpi-core"
        log green "ByeDPI успешно установлен в $BYEDPI_DIR"
    else
        log red "Ошибка компиляции ByeDPI"; exit 1
    fi
}

fetch_configuration_lists() {
    local setup_zip="$TEMP_DIR/Byedpi-Setup-main.zip"
    safe_download "$setup_repo" "$setup_zip"
    unzip -q "$setup_zip" -d "$TEMP_DIR"
    cd "$TEMP_DIR/Byedpi-Setup-main/assets" || exit 1
    bash link_get.sh
    
    log yellow "Проверка файлов конфигурации:"
    [[ -f settings.txt ]] && log green "settings.txt: $(wc -l < settings.txt) настроек" || { log red "settings.txt не найден"; exit 1; }
    [[ -f links.txt ]] && log green "links.txt: $(wc -l < links.txt) доменов" || { log red "links.txt не найден"; exit 1; }
}

select_port() {
    local port; read -p "Введите порт для Byedpi (по умолчанию 1080): " port
    port=${port:-1080}
    if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1024 || "$port" -gt 65535 ]]; then
        log red "Некорректный порт. Используется 1080"; port=1080
    fi
    echo "$port"
}

select_port_test() {
    local port_test; read -p "Введите порт для ТЕСТА Byedpi (по умолчанию 10200): " port_test
    port_test=${port_test:-10200}
    if [[ ! "$port_test" =~ ^[0-9]+$ || "$port_test" -lt 1024 || "$port_test" -gt 65535 ]]; then
        log red "Некорректный порт. Используется 10200"; port_test=10200
    fi
    echo "$port_test"
}

update_service() {
    local port=$1 setting=$2
    if [[ -z "$port" ]] || [[ -z "$setting" ]]; then log red "Ошибка: не указан порт или настройки"; return 1; fi
    
    mkdir -p /run 2>/dev/null || true
    safe_mkdir_no_rm "/etc/conf.d"
    {
        echo "SEL_PORT=\"$port\""
        echo "SEL_SETTINGS=\"$setting\""
    } > "/etc/conf.d/ciadpi"

    cat > "/etc/init.d/ciadpi" <<EOF
#!/sbin/openrc-run
description="ByeDPI Proxy Service"
command="$HOME/ciadpi/ciadpi-core"
command_args="--ip 0.0.0.0 --port \${SEL_PORT} \${SEL_SETTINGS}"
command_background="yes"
pidfile="/run/ciadpi.pid"
depend() {
    need net localmount
    use dns
}
start_pre() {
    mkdir -p /run 2>/dev/null || true
    if [ -z "\$SEL_PORT" ] || [ -z "\$SEL_SETTINGS" ]; then
        eerror "Не заданы SEL_PORT или SEL_SETTINGS в /etc/conf.d/ciadpi"
        return 1
    fi
}
EOF
    chmod +x "/etc/init.d/ciadpi"

    # Автозапуск (не критично для Docker)
    if command -v rc-update >/dev/null 2>&1; then
        rc-update add ciadpi default 2>/dev/null || log yellow "rc-update недоступен или не работает в данной среде. Пропускаем."
    else
        log yellow "rc-update не найден. Используем /etc/local.d для автозапуска..."
        mkdir -p /etc/local.d
        cat > "/etc/local.d/ciadpi.start" <<EOF
#!/bin/sh
$HOME/ciadpi/ciadpi-core --ip 0.0.0.0 --port $port $setting &
EOF
        chmod +x "/etc/local.d/ciadpi.start"
    fi

    start_ciadpi() {
        if is_docker; then
            log yellow "Обнаружен Docker — запускаем без OpenRC"
            pkill -f "ciadpi-core.*--port $port" >/dev/null 2>&1 || true
            sleep 1
            # Отключаем globbing, чтобы флаги из $setting не интерпретировались как шаблоны
            set -f
            nohup "$HOME/ciadpi/ciadpi-core" --ip 0.0.0.0 --port "$port" $setting >/var/log/ciadpi.log 2>&1 &
            set +f
            local pid=$!
            echo $pid > /run/ciadpi.pid
            sleep 1
            if kill -0 $pid 2>/dev/null; then
                log green "ciadpi запущен (Docker режим, PID: $pid)"; return 0
            else
                log red "Не удалось запустить ciadpi"; return 1
            fi
        else
            log yellow "Используем OpenRC"
            rm -f /run/openrc/started/ciadpi /run/openrc/starting/ciadpi 2>/dev/null
            sleep 1
            if command -v rc-service >/dev/null 2>&1; then
                rc-service ciadpi stop 2>/dev/null || true
                sleep 1
                rc-service ciadpi start || { log red "Ошибка запуска службы"; return 1; }
            else
                /etc/init.d/ciadpi restart || { log red "Ошибка запуска службы"; return 1; }
            fi
            log green "Служба запущена через OpenRC"; return 0
        fi
    }

    start_ciadpi || { log red "Скрипт прерван"; exit 1; }
    log green "Служба перезапущена и добавлена в автозапуск"
    return 0
}

test_configurations() {
    local port_test=$1
    log green "=== Начало тестирования ==="
    log green "Используемый порт: $port_test"
    mapfile -t settings < <(grep -v '^[[:space:]]*$' settings.txt)
    mapfile -t links < <(grep -v '^[[:space:]]*$' links.txt)
    log yellow "Загружено настроек: ${#settings[@]} | доменов: ${#links[@]}"

    pkill -f "ciadpi-core.*--port $port_test" 2>/dev/null || true
    local -a results=()
    local max_parallel=${#links[@]}
    local setting_number=1

    for setting in "${settings[@]}"; do
        [[ -z "$setting" ]] && continue
        log yellow "================================================"
        log yellow "Тест [$setting_number/${#settings[@]}]: $setting"
        
        "$BYEDPI_DIR/ciadpi-core" --ip 0.0.0.0 --port "$port_test" $setting &
        local test_pid=$!
        for i in {1..5}; do
            kill -0 $test_pid 2>/dev/null && { log green "Прокси запущен (PID: $test_pid)"; break; }
            sleep 1
        done
        if ! kill -0 $test_pid 2>/dev/null; then
            log red "Прокси не запустился"; continue
        fi

        local success_count=0 total_count=0
        local temp_dir=$(mktemp -d)
        local -a pids=()
        sleep 2

        local domain_number=1
        for link in "${links[@]}"; do
            [[ -z "$link" ]] && continue
            (
                local http_code
                http_code=$(curl -x socks5h://0.0.0.0:"$port_test" -o /dev/null -s -w "%{http_code}" "https://$link" \
                    --connect-timeout 2 --max-time 3) || http_code="000"
                case "$http_code" in
                    200|404|400|405|403|302|301) echo "success" > "$temp_dir/result_$domain_number" ;;
                    *) echo "failure#$https_link#$http_code" > "$temp_dir/result_$domain_number" ;;
                esac
            ) &
            pids+=($!)
            ((domain_number++))
            ((${#pids[@]} >= max_parallel)) && { wait "${pids[0]}" 2>/dev/null || true; pids=("${pids[@]:1}"); }
        done
        wait "${pids[@]}" 2>/dev/null || true

        for res_file in "$temp_dir"/result_*; do
            [[ -f "$res_file" ]] || continue
            local content=$(cat "$res_file")
            ((total_count++))
            [[ "$content" == "success" ]] && ((success_count++))
        done
        rm -rf "$temp_dir"

        kill $test_pid 2>/dev/null || true
        wait $test_pid 2>/dev/null || true

        local success_rate=$(( total_count > 0 ? success_count * 100 / total_count : 0 ))
        results+=("$setting#$success_rate#$success_count#$total_count")
        log green "- Успешно: $success_count/$total_count ($success_rate%)"
        log yellow "================================================"
        echo
        ((setting_number++))
    done
    printf "RESULTS_START\n%s\nRESULTS_END\n" "$(printf '%s\n' "${results[@]}")"
}

main() {
    echo -e "\e[32m"
    cat << "EOF"
⠀⣀⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣀⣀⠀⠀
⢾⣿⣿⣿⣿⣶⣤⡀⠀⠀⠀⠀⠀⠀⠀⠀⠄⠀⣀⣴⣶⣿⣿⣿⣿⡇⠀
⠈⢿⣿⣿⣿⡛⠛⠈⠳⣄⠂⠀⠀⠀⠀⠀⣠⠞⠉⠛⢻⣿⣿⣿⡟⠀⠀
⠀⠸⣿⣿⣿⠥⠀⠀⠀⠈⢢⠀⠀⠀⠀⡜⠁⠀⠀⠀⢸⣿⣿⣿⠁⠀⠀
⠀⠀⣿⣿⣯⠭⠤⠀⠀⠀⠀⠃⣰⡄⠌⠀⠀⠀⠀⠨⢭⣿⣿⣿⠀⠀⠀
⠀⠀⠹⢿⣿⣈⣀⣀⠀⠀⠠⢴⣿⣿⡦⠀⠀⠀⣀⣈⣱⣿⠿⠃⠀⠀⠀
⠀⠀⠀⢠⣾⣿⡟⠁⠀⠀⠀⠀⣿⣏⠀⠀⠀⠀⠘⣻⣿⣶⠀⠀⠀⠀⠀
⠀⠀⠀⢸⣿⣿⢂⠀⠀⠀⠀⠘⢸⡇⠆⠀⠀⠀⢀⠰⣿⣿⠀⠀⠀⠀⠀
⠀⠀⠀⠈⣿⣷⣿⣆⡀⠀⠀⠁⠈⠀⠠⠀⠀⢀⣶⣿⣿⠏⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠘⣿⣿⣿⣷⣴⡜⠀⠀⠀⠀⣦⣤⣾⣿⣿⡏⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⢀⡿⠛⠿⠿⠿⠛⠁⠀⠀⠀⠀⠘⠿⠿⠿⠿⢧⠀⠀⠀⠀⠀
⠀⠀⠀⠀⣾⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠘⣧⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠀⠀⠀⠀⠀
EOF
    echo -e "\e[36m\nByedpi-Setup (Alpine/OpenRC & Docker Edition)\ngithub.com/fatyzzz/Byedpi-Setup\n\e[0m"
    sleep 2
    check_dependencies

    trap '
    log red "Скрипт прерван";
    read -p "Отключить службу ciadpi? (y/n): " choice
    if [[ $choice =~ ^[Yy]$ ]]; then
        command -v rc-service >/dev/null 2>&1 && rc-service ciadpi stop 2>/dev/null || /etc/init.d/ciadpi stop 2>/dev/null || true
    fi
    exit 1
    ' SIGINT SIGTERM ERR

    local port selector port_test
    echo; log green "Выберите действие:"
    log yellow "1 - Установка ByeDPI"
    log yellow "2 - Только тестирование конфигурации"
    log yellow "3 - Поменять порт у службы"
    read selector

    case "$selector" in
        "1")
            if [[ -f /etc/init.d/ciadpi ]]; then
                log yellow "Служба уже существует."
                port_test=$(select_port_test)
                port=$(sed -n 's/.*SEL_PORT="\([0-9]*\)".*/\1/p' /etc/conf.d/ciadpi 2>/dev/null)
                [[ -z "$port" ]] && port=1080
            else
                port=$(select_port); port_test=$port
            fi ;;
        "2") port_test=$(select_port_test) ;;
        "3")
            [[ ! -f /etc/init.d/ciadpi ]] && { log red "Служба не найдена"; exit 1; }
            stop_service() { command -v rc-service >/dev/null 2>&1 && rc-service ciadpi stop 2>/dev/null || /etc/init.d/ciadpi stop 2>/dev/null || true; }
            update_service_port() {
                local new_port=$1; stop_service
                sed -i "s/SEL_PORT=\"[0-9]*\"/SEL_PORT=\"$new_port\"/" "/etc/conf.d/ciadpi"
                command -v rc-service >/dev/null 2>&1 && rc-service ciadpi start || /etc/init.d/ciadpi start
            }
            new_port=$(select_port); update_service_port "$new_port"
            log green "Порт обновлён: $new_port"; exit 0 ;;
        *) log red "Некорректный выбор"; exit 1 ;;
    esac

    log green "Начало установки"
    safe_mkdir "$TEMP_DIR"
    install_byedpi
    fetch_configuration_lists

    local results_file=$(mktemp)
    test_configurations "$port_test" | tee "$results_file"
    local -a test_results; local capture=0
    while IFS= read -r line; do
        [[ "$line" == "RESULTS_START" ]] && { capture=1; continue; }
        [[ "$line" == "RESULTS_END" ]] && break
        [[ $capture -eq 1 ]] && test_results+=("$line")
    done < "$results_file"
    rm -f "$results_file"

    [[ ${#test_results[@]} -eq 0 ]] && { log red "Нет рабочих конфигураций"; exit 1; }

    log yellow "Топ 10 конфигураций:"
    local -a sorted_results=()
    for result in "${test_results[@]}"; do
        IFS='#' read -r setting success_rate success_count total_count _ <<< "$result"
        sorted_results+=("$success_rate:${#setting}:$result")
    done

    local -a filtered_results=()
    while IFS=: read -r _ _ setting success_rate success_count total_count _; do
        filtered_results+=("$setting#$success_rate#$success_count#$total_count")
    done < <(printf '%s\n' "${sorted_results[@]}" | sort -t: -k1,1nr -k2,2n | head -n 10)

    for i in "${!filtered_results[@]}"; do
        IFS='#' read -r setting success_rate success_count total_count _ <<< "${filtered_results[i]}"
        if ((success_rate >= 80)); then color="${COLOR_GREEN}"
        elif ((success_rate >= 50)); then color="${COLOR_YELLOW}"
        else color="${COLOR_RED}"; fi
        echo -e "$i) ${color}$setting (Успех: $success_rate%, $success_count/$total_count)${COLOR_RESET}"
    done

    if [[ "$selector" == "1" ]]; then
        read -p "Выберите номер конфигурации: " selected_index
        if [[ ! "$selected_index" =~ ^[0-9]+$ || "$selected_index" -ge "${#filtered_results[@]}" ]]; then
            log red "Некорректный выбор"; exit 1
        fi
        IFS='#' read -r selected_setting _ _ _ _ <<< "${filtered_results[selected_index]}"
        update_service "$port" "$selected_setting"
        log green "Установка завершена. Прокси: 0.0.0.0:$port"
    else
        log green "t.me/fatyzzz"
    fi
    rm -rf "$TEMP_DIR"
}

main
