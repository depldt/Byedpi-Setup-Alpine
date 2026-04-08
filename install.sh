#!/bin/bash
# Глобальные константы
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
readonly SCRIPT_NAME=$(basename "$0")
readonly LOG_FILE="/tmp/${SCRIPT_NAME}.log"
readonly CONFIG_FILE="/etc/conf.d/ciadpi"
readonly BYEDPI_DIR="$HOME/ciadpi"
readonly TEMP_DIR=$(mktemp -d)
readonly setup_repo="https://github.com/fatyzzz/Byedpi-Setup/archive/refs/heads/main.zip"

# Цвета для логирования
readonly COLOR_GREEN='\e[32m'
readonly COLOR_RED='\e[31m'
readonly COLOR_YELLOW='\e[33m'
readonly COLOR_RESET='\e[0m'

# Функция логирования с поддержкой цветов и файла
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

# Функция безопасного создания директории
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

# Установка пакетов для Arch Linux
install_arch() {
    local packages=("$@")
    log green "Обнаружен Arch Linux. Устанавливаю пакеты: ${packages[*]}"
    log yellow "Требуются права суперпользователя. Введите пароль root:"
    su -c "pacman -S --noconfirm ${packages[*]}"
}

# Установка пакетов для Debian
install_debian() {
    local packages=("$@")
    log green "Обнаружен Debian. Устанавливаю пакеты: ${packages[*]}"
    log yellow "Требуются права суперпользователя. Введите пароль root:"
    su -c "apt update && apt install -y ${packages[*]}" || {
        log red "Ошибка установки пакетов"
        exit 1
    }
    log green "Установка завершена."
}

# Установка пакетов для Ubuntu
install_ubuntu() {
    local packages=("$@")
    log green "Обнаружен Ubuntu. Устанавливаю пакеты: ${packages[*]}"
    su -c "apt update && apt install -y ${packages[*]}" || {
        log red "Ошибка установки пакетов"
        exit 1
    }
    log green "Установка завершена."
}

# Универсальная установка для других дистрибутивов
install_other() {
    local packages=("$@")
    log yellow "Ваш дистрибутив ($DISTRO) не поддерживается напрямую."
    if command -v zypper >/dev/null 2>&1; then
        su -c "zypper install -y ${packages[*]}"
    elif command -v dnf >/dev/null 2>&1; then
        su -c "dnf install -y ${packages[*]}"
    elif command -v yum >/dev/null 2>&1; then
        su -c "yum install -y ${packages[*]}"
    else
        log red "Не удалось найти менеджер пакетов. Установите вручную: ${packages[*]}"
        exit 1
    fi
}

# Проверка и установка зависимостей (Адаптировано под Alpine)
check_dependencies() {
    detect_distro
    local dependencies=("gcc" "make" "unzip" "curl")
    if [[ "$DISTRO" == "alpine" ]]; then
        dependencies+=("openrc" "linux-headers" "openssl-dev" "zlib-dev" "build-base")
    fi

    local missing=()
    for dep in "${dependencies[@]}"; do
        if [[ "$DISTRO" == "alpine" ]] && command -v apk &> /dev/null; then
            if ! apk info -e "$dep" &> /dev/null 2>&1; then
                missing+=("$dep")
            fi
        else
            if ! command -v "$dep" &> /dev/null; then
                missing+=("$dep")
            fi
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
                su -c "apk update && apk add --no-cache ${missing[*]}" || {
                    log red "Ошибка установки пакетов через apk"
                    exit 1
                }
                log green "Установка зависимостей завершена."
                ;;
            *) install_other "${missing[@]}" ;;
        esac
    else
        log green "Все необходимые пакеты установлены."
    fi

    # Гарантируем наличие /sbin и /usr/sbin в PATH для работы rc-update/rc-service
    if [[ "$DISTRO" == "alpine" ]]; then
        [[ ":$PATH:" != *":/sbin:"* ]] && export PATH="/sbin:$PATH"
        [[ ":$PATH:" != *":/usr/sbin:"* ]] && export PATH="/usr/sbin:$PATH"
    fi
}

# Функция безопасной загрузки с кэшированием
safe_download() {
    local url=$1
    local output=$2
    local cache_dir="/tmp/cache/byedpi"
    safe_mkdir "$cache_dir"
    local cache_file="$cache_dir/$(basename "$output")"
    if [[ -f "$cache_file" ]]; then
        log yellow "Используем кэшированную версию: $cache_file"
        cp "$cache_file" "$output"
    else
        log green "Загрузка: $url"
        if ! curl -L -o "$output" "$url"; then
            log red "Не удалось загрузить $url"
            return 1
        fi
        cp "$output" "$cache_file"
    fi
}

# Компиляция и установка ByeDPI (Исправлено извлечение директории)
install_byedpi() {
    local repo_url="https://github.com/hufrea/byedpi/archive/refs/tags/v0.17.3.zip"
    local zip_file="$TEMP_DIR/byedpi-release.zip"
    safe_download "$repo_url" "$zip_file"
    unzip -q "$zip_file" -d "$TEMP_DIR"
    
    # Динамически находим извлечённую директорию (работает для веток и тегов)
    local extracted_dir
    extracted_dir=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "byedpi-*" | head -n1)
    
    if [[ -z "$extracted_dir" || ! -d "$extracted_dir" ]]; then
        log red "Не удалось найти извлечённую директорию в $TEMP_DIR"
        exit 1
    fi
    
    cd "$extracted_dir" || exit 1
    log yellow "Компиляция ByeDPI..."
    if make; then
        safe_mkdir "$BYEDPI_DIR"
        mv ciadpi "$BYEDPI_DIR/ciadpi-core"
        log green "ByeDPI успешно установлен в $BYEDPI_DIR"
    else
        log red "Ошибка компиляции ByeDPI"
        exit 1
    fi
}

# Загрузка и обработка списков
fetch_configuration_lists() {
    local setup_zip="$TEMP_DIR/Byedpi-Setup-main.zip"
    safe_download "$setup_repo" "$setup_zip"
    unzip -q "$setup_zip" -d "$TEMP_DIR"
    cd "$TEMP_DIR/Byedpi-Setup-main/assets" || exit 1
    bash link_get.sh
    
    log yellow "Проверка файла settings.txt:"
    if [[ -f settings.txt ]]; then
        log green "Файл settings.txt существует"
        log green "Количество настроек: $(wc -l < settings.txt)"
    else
        log red "Файл settings.txt не найден"
    fi
    log yellow "Проверка файла links.txt:"
    if [[ -f links.txt ]]; then
        log green "Файл links.txt существует"
        log green "Количество доменов: $(wc -l < links.txt)"
    else
        log red "Файл links.txt не найден"
    fi
    if [[ ! -f links.txt || ! -f settings.txt ]]; then
        log red "Не удалось создать конфигурационные файлы"
        exit 1
    fi
}

# Интерактивный выбор порта
select_port() {
    local port
    read -p "Введите порт для Byedpi (по умолчанию 14228): " port
    port=${port:-14228}
    if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1024 || "$port" -gt 65535 ]]; then
        log red "Некорректный порт. Используется порт по умолчанию: 14228"
        port=14228
    fi
    echo "$port"
}

select_port_test() {
    local port_test
    read -p "Введите порт для ТЕСТА Byedpi (по умолчанию 10200): " port_test
    port_test=${port_test:-10200}
    if [[ ! "$port_test" =~ ^[0-9]+$ || "$port_test" -lt 1024 || "$port_test" -gt 65535 ]]; then
        log red "Некорректный порт. Используется порт по умолчанию: 10200"
        port_test=10200
    fi
    echo "$port_test"
}

# Обновление конфигурации OpenRC и службы
update_service() {
    local port=$1
    local setting=$2
    if [[ -z "$port" ]] || [[ -z "$setting" ]]; then
        log red "Ошибка: не указан порт или настройки"
        return 1
    fi
    
    safe_mkdir_no_rm "/etc/conf.d"
    {
        echo "SEL_PORT=\"$port\""
        echo "SEL_SETTINGS=\"$setting\""
    } > "/etc/conf.d/ciadpi"

    cat > "/etc/init.d/ciadpi" <<EOF
#!/sbin/openrc-run
description="ByeDPI Proxy Service"
command="$HOME/ciadpi/ciadpi-core"
command_args="--ip 127.0.0.1 --port \${SEL_PORT} \${SEL_SETTINGS}"
command_background="yes"
pidfile="/run/ciadpi.pid"
depend() {
    need net localmount
    use dns
}
start_pre() {
    if [ -z "\$SEL_PORT" ] || [ -z "\$SEL_SETTINGS" ]; then
        eerror "Не заданы SEL_PORT или SEL_SETTINGS в /etc/conf.d/ciadpi"
        return 1
    fi
}
EOF
    chmod +x "/etc/init.d/ciadpi"

    if command -v rc-update >/dev/null 2>&1; then
        rc-update add ciadpi default || {
            log red "Ошибка добавления в автозапуск"
            return 1
        }
    else
        log yellow "rc-update не найден. Используем /etc/local.d для автозапуска..."
        mkdir -p /etc/local.d
        cat > "/etc/local.d/ciadpi.start" <<EOF
#!/bin/sh
$HOME/ciadpi/ciadpi-core --ip 127.0.0.1 --port $port $setting &
EOF
        chmod +x "/etc/local.d/ciadpi.start"
    fi

    if command -v rc-service >/dev/null 2>&1; then
        rc-service ciadpi restart || {
            log red "Ошибка запуска службы"
            return 1
        }
    else
        log yellow "Запускаем службу напрямую через init-скрипт..."
        /etc/init.d/ciadpi start || {
            log red "Не удалось запустить службу"
            return 1
        }
    fi
    log green "Служба добавлена в автозапуск и запущена"
    return 0
}

# Тестирование конфигураций (Без systemd, прямой запуск в фоне)
test_configurations() {
    local port_test=$1
    log green "=== Начало тестирования ==="
    log green "Используемый порт: $port_test"
    mapfile -t settings < <(grep -v '^[[:space:]]*$' settings.txt)
    mapfile -t links < <(grep -v '^[[:space:]]*$' links.txt)
    log yellow "Загружено настроек: ${#settings[@]}"
    log yellow "Загружено доменов: ${#links[@]}"

    # Останавливаем тестовые процессы, если остались
    pkill -f "ciadpi-core.*--port $port_test" 2>/dev/null || true

    local -a results=()
    local max_parallel=${#links[@]}
    local setting_number=1

    for setting in "${settings[@]}"; do
        [[ -z "$setting" ]] && continue
        log yellow "================================================"
        log yellow "Тестирование настройки [$setting_number/${#settings[@]}]"
        log green "Настройка: $setting"

        log green "Запускаем прокси в фоне для теста..."
        "$BYEDPI_DIR/ciadpi-core" --ip 127.0.0.1 --port "$port_test" $setting &
        local test_pid=$!
        log yellow "Ожидание запуска прокси..."
        for i in {1..5}; do
            if kill -0 $test_pid 2>/dev/null; then
                log green "Прокси успешно запущен (PID: $test_pid)"
                break
            fi
            sleep 1
        done
        if ! kill -0 $test_pid 2>/dev/null; then
            log red "Прокси не запустился для настройки $setting, пропускаем..."
            continue
        fi

        local success_count=0
        local total_count=0
        local failed_links=()
        local temp_dir=$(mktemp -d)
        local -a pids=()
        sleep 2
        log green "Начинаем параллельную проверку доменов..."
        local domain_number=1
        for link in "${links[@]}"; do
            [[ -z "$link" ]] && continue
            local https_link="https://$link"
            (
                local http_code
                http_code=$(curl -x socks5h://127.0.0.1:"$port_test" \
                    -o /dev/null -s -w "%{http_code}" "$https_link" \
                    --connect-timeout 2 --max-time 3) || http_code="000"
                if [[ "$http_code" == "200" || "$http_code" == "404" || "$http_code" == "400" || "$http_code" == "405" || "$http_code" == "403" || "$http_code" == "302" || "$http_code" == "301" ]]; then
                    log green "  ✓ OK ($https_link: $http_code)"
                    echo "success" > "$temp_dir/result_$domain_number"
                else
                    log red "  ✗ FAILED ($https_link: $http_code)"
                    echo "failure#$https_link#$http_code" > "$temp_dir/result_$domain_number"
                fi
            ) &
            pids+=($!)
            ((domain_number++))
            if ((${#pids[@]} >= max_parallel)); then
                wait "${pids[0]}" 2>/dev/null || true
                pids=("${pids[@]:1}")
            fi
        done
        wait "${pids[@]}" 2>/dev/null || true

        for res_file in "$temp_dir"/result_*; do
            [[ -f "$res_file" ]] || continue
            local content=$(cat "$res_file")
            ((total_count++))
            if [[ "$content" == "success" ]]; then
                ((success_count++))
            else
                failed_links+=("${content#failure#}")
            fi
        done
        rm -rf "$temp_dir"

        log yellow "Останавливаем тестовый прокси..."
        kill $test_pid 2>/dev/null || true
        wait $test_pid 2>/dev/null || true

        local success_rate=0
        [[ $total_count -gt 0 ]] && success_rate=$((success_count * 100 / total_count))
        results+=("$setting#$success_rate#$success_count#$total_count#${#failed_links[@]}")
        log green "Результаты для настройки [$setting_number/${#settings[@]}]:"
        log green "- Успешно: $success_count из $total_count ($success_rate%)"
        log yellow "- Неудачно: ${#failed_links[@]}"
        log yellow "================================================"
        echo
        ((setting_number++))
    done
    printf "RESULTS_START\n%s\nRESULTS_END\n" "$(printf '%s\n' "${results[@]}")"
}

# Основная функция
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
    echo -e "\e[36m"
    echo "Byedpi-Setup (Alpine/OpenRC Edition)"
    echo "github.com/fatyzzz/Byedpi-Setup"
    echo -e "\e[0m"
    sleep 2
    check_dependencies

    trap '
    log red "Скрипт прерван";
    read -p "Вы хотите отключить службу ciadpi? (y/n): " choice
    if [[ $choice =~ ^[Yy]$ ]]; then
        log yellow "Отключение службы ciadpi..."
        if command -v rc-service >/dev/null 2>&1; then
            rc-service ciadpi stop 2>/dev/null || log red "Не удалось остановить службу."
        else
            /etc/init.d/ciadpi stop 2>/dev/null || log red "Не удалось остановить службу."
        fi
    else
        log green "Служба оставлена включенной."
    fi
    exit 1
    ' SIGINT SIGTERM ERR

    local port
    local selector
    local port_test
    echo
    log green "Выберите действие:"
    echo
    log yellow "1 - Установка ByeDPI"
    log yellow "2 - Только тестирование конфигурации"
    log yellow "3 - Поменять порт у службы"
    read selector
    case "$selector" in
        "1")
            if [[ -f /etc/init.d/ciadpi ]]; then
                log yellow "Служба ciadpi уже существует."
                port_test=$(select_port_test)
                port=$(sed -n 's/.*SEL_PORT="\([0-9]*\)".*/\1/p' /etc/conf.d/ciadpi 2>/dev/null)
                [[ -z "$port" ]] && port=14228
            else
                port=$(select_port)
                port_test=$port
            fi
            ;;
        "2")
            port_test=$(select_port_test)
            ;;
        "3")
            if [[ ! -f /etc/init.d/ciadpi ]]; then
                log red "Служба ciadpi не найдена. Пожалуйста, выберите другое действие."
                exit 1
            fi
            stop_service() {
                if command -v rc-service >/dev/null 2>&1; then rc-service ciadpi stop 2>/dev/null || true
                else /etc/init.d/ciadpi stop 2>/dev/null || true; fi
            }
            update_service_port() {
                local new_port=$1
                stop_service
                sed -i "s/SEL_PORT=\"[0-9]*\"/SEL_PORT=\"$new_port\"/" "/etc/conf.d/ciadpi"
                if command -v rc-service >/dev/null 2>&1; then rc-service ciadpi start
                else /etc/init.d/ciadpi start; fi
            }
            new_port=$(select_port)
            update_service_port "$new_port"
            log green "Служба ciadpi успешно обновлена с новым портом: $new_port"
            exit 0
            ;;
        *)
            log red "Некорректный выбор действия"
            exit 1
            ;;
    esac

    log green "Начало установки ByeDPI"
    safe_mkdir "$TEMP_DIR"
    install_byedpi
    fetch_configuration_lists

    local results_file=$(mktemp)
    test_configurations "$port_test" | tee "$results_file"
    local -a test_results
    local capture=0
    while IFS= read -r line; do
        if [[ "$line" == "RESULTS_START" ]]; then
            capture=1
            continue
        elif [[ "$line" == "RESULTS_END" ]]; then
            break
        elif [[ $capture -eq 1 ]]; then
            test_results+=("$line")
        fi
    done < "$results_file"
    rm -f "$results_file"

    if [[ ${#test_results[@]} -eq 0 ]]; then
        log red "Не найдено рабочих конфигураций"
        exit 1
    fi

    log yellow "Топ 10 конфигураций:"
    local -a sorted_results=()
    for result in "${test_results[@]}"; do
        IFS='#' read -r setting success_rate success_count total_count failed_count <<< "$result"
        sorted_results+=("$success_rate:${#setting}:$result")
    done

    local -a filtered_results=()
    while IFS=: read -r _ _ setting success_rate success_count total_count failed_count; do
        filtered_results+=("$setting#$success_rate#$success_count#$total_count#$failed_count")
    done < <(printf '%s\n' "${sorted_results[@]}" | sort -t: -k1,1nr -k2,2n | head -n 10)

    for i in "${!filtered_results[@]}"; do
        IFS='#' read -r setting success_rate success_count total_count failed_count <<< "${filtered_results[i]}"
        if ((success_rate >= 80)); then color="${COLOR_GREEN}"
        elif ((success_rate >= 50)); then color="${COLOR_YELLOW}"
        else color="${COLOR_RED}"
        fi
        echo -e "$i) ${color}$setting (Успех: $success_rate%, $success_count/$total_count, Неуспешно: $failed_count)${COLOR_RESET}"
    done

    if [[ "$selector" == "1" ]]; then
        read -p "Выберите номер конфигурации: " selected_index
        if [[ ! "$selected_index" =~ ^[0-9]+$ || "$selected_index" -ge "${#filtered_results[@]}" ]]; then
            log red "Некорректный выбор"
            exit 1
        fi
        IFS='#' read -r selected_setting _ _ _ _ <<< "${filtered_results[selected_index]}"
        update_service "$port" "$selected_setting"
        log green "Установка ByeDPI завершена. Служба ciadpi запущена с настройкой: $selected_setting"
        log yellow "Информация для подключения Socks5 прокси"
        log yellow "Айпи: 127.0.0.1"
        log yellow "Порт: $port"
    else
        log green "t.me/fatyzzz"
    fi

    rm -rf "$TEMP_DIR"
}

main
