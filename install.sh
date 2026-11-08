#!/bin/sh
# install.sh — установщик утилит из rival-afk/dls
#
# Использование:
#   curl -fsSL https://raw.githubusercontent.com/rival-afk/dls/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/rival-afk/dls/main/install.sh | sh -s -- ytd ttd
#   ./install.sh              # интерактивное меню
#   ./install.sh all          # установить всё без вопросов
#   ./install.sh ytd scd      # установить только указанные
#
# Переменные окружения:
#   INSTALL_DIR  — куда класть исполняемые файлы (по умолчанию ~/.local/bin)
#   BRANCH       — ветка репозитория (по умолчанию main)
set -eu

REPO="rival-afk/dls"
BRANCH="${BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/$REPO/$BRANCH}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

# Цвета (только если вывод в терминал)
if [ -t 1 ]; then
    C_BOLD='\033[1m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RED='\033[31m'; C_OFF='\033[0m'
else
    C_BOLD=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_OFF=''
fi
info()  { printf "%b==>%b %s\n" "$C_BOLD" "$C_OFF" "$*"; }
ok()    { printf "%b  ✓%b %s\n" "$C_GREEN" "$C_OFF" "$*"; }
warn()  { printf "%b  !%b %s\n" "$C_YELLOW" "$C_OFF" "$*" >&2; }
err()   { printf "%b  ✗%b %s\n" "$C_RED" "$C_OFF" "$*" >&2; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

download() { # download <url> <dest>
    if need_cmd curl; then
        curl -fsSL "$1" -o "$2"
    elif need_cmd wget; then
        wget -qO "$2" "$1"
    else
        err "нужен curl или wget для скачивания файлов."
        exit 1
    fi
}

# --- Пакетный менеджер -------------------------------------------------------

# sudo, если нужно и есть (на Termux и под root sudo не требуется)
SUDO=""
if [ "$(id -u)" != "0" ] && need_cmd sudo; then
    SUDO="sudo"
fi

# Определяем доступный пакетный менеджер и пакетные имена.
# pkg_names <имя-ffmpeg> <имя-jq> <имя-python3>  → выводит "PM_CMD <базовые аргументы>"
detect_pm() {
    PM=""
    PM_INSTALL=""
    PM_CHECK=""
    if [ -x /data/data/com.termux/files/usr/bin/pkg ]; then
        PM="pkg"; PM_INSTALL="pkg install -y"; PM_CHECK="pkg list-installed"
    elif need_cmd apt-get; then
        PM="apt"; PM_INSTALL="$SUDO apt-get install -y -q"; PM_CHECK="dpkg -s"
    elif need_cmd apt; then
        PM="apt"; PM_INSTALL="$SUDO apt install -y -q"; PM_CHECK="dpkg -s"
    elif need_cmd dnf; then
        PM="dnf"; PM_INSTALL="$SUDO dnf install -y"; PM_CHECK="rpm -q"
    elif need_cmd yum; then
        PM="yum"; PM_INSTALL="$SUDO yum install -y"; PM_CHECK="rpm -q"
    elif need_cmd pacman; then
        PM="pacman"; PM_INSTALL="$SUDO pacman -S --noconfirm --needed"; PM_CHECK="pacman -Q"
    elif need_cmd zypper; then
        PM="zypper"; PM_INSTALL="$SUDO zypper --non-interactive install"; PM_CHECK="rpm -q"
    elif need_cmd apk; then
        PM="apk"; PM_INSTALL="$SUDO apk add"; PM_CHECK="apk info -e"
    elif [ -x /data/data/com.termux/files/usr/bin/bash ] && need_cmd pkg; then
        PM="pkg"; PM_INSTALL="pkg install -y"; PM_CHECK="pkg list-installed"
    elif need_cmd brew; then
        PM="brew"; PM_INSTALL="brew install"; PM_CHECK="brew list --formula"
    elif need_cmd nix-shell; then
        PM="nix"; PM_INSTALL="nix-shell -p"; PM_CHECK="command -v"
    fi
}

# pkg_is_installed <пакет> <команда> — пакет установлен или команда уже доступна
pkg_is_installed() {
    if need_cmd "$2"; then
        return 0
    fi
    case "$PM" in
        "") return 1 ;;
        apt|pkg) $PM_CHECK "$1" >/dev/null 2>&1 ;;
        dnf|yum|zypper) $PM_CHECK "$1" >/dev/null 2>&1 ;;
        pacman) $PM_CHECK -q "$1" >/dev/null 2>&1 ;;
        apk) $PM_CHECK "$1" >/dev/null 2>&1 ;;
        brew) $PM_CHECK "$1" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

# install_pkg <пакет> <команда> [доп. имена пакетов...] — ставит, если команды нет
install_pkg() {
    cmd="$2"
    shift 2
    [ -n "$cmd" ] || cmd="$1"
    if need_cmd "$cmd"; then
        ok "$cmd уже установлен"
        return 0
    fi
    detect_pm
    if [ -z "$PM" ]; then
        warn "не найден пакетный менеджер — поставь '$cmd' (пакеты: $*) вручную."
        return 1
    fi
    info "Ставлю $cmd через $PM…"
    if $PM_INSTALL "$@"; then
        if need_cmd "$cmd"; then
            ok "$cmd установлен ($PM)"
            return 0
        fi
        warn "$PM отработал, но '$cmd' не найден — возможно, нужен перезапуск терминала."
        return 0
    fi
    warn "не удалось поставить '$cmd' через $PM — поставь руками (пакеты: $*)."
    return 1
}

# yt-dlp: отдельно, т.к. ставится и через pip
install_ytdlp() {
    if need_cmd yt-dlp; then
        ok "yt-dlp уже установлен"
        return 0
    fi
    detect_pm
    # у большинства дистрибутивов есть готовый пакет
    case "$PM" in
        pkg)    install_pkg yt-dlp "" yt-dlp && return 0 ;;
        pacman) install_pkg yt-dlp "" yt-dlp && return 0 ;;
        brew)   install_pkg yt-dlp "" yt-dlp && return 0 ;;
        apt)
            # в Debian 12+ пакет есть; пробуем его преждевременно не затыкаемся на пир-рекомендациях
            if (apt-cache show yt-dlp >/dev/null 2>&1) && $SUDO apt-get install -y -q yt-dlp 2>/dev/null; then
                ok "yt-dlp установлен (apt)"
                return 0
            fi
            ;;
    esac
    # fallback: pip
    if need_cmd pip3; then
        info "Ставлю yt-dlp через pip3…"
        if pip3 install -q --user yt-dlp 2>/dev/null || pip3 install -q --break-system-packages --user yt-dlp 2>/dev/null; then
            ok "yt-dlp установлен (pip --user)"
            case ":$PATH:" in
                *":$HOME/.local/bin:"*) ;;
                *) warn "pip положил yt-dlp в ~/.local/bin — добавь её в PATH (установщик сделает это ниже)." ;;
            esac
            return 0
        fi
    fi
    warn "не удалось поставить yt-dlp автоматически. Поставь руками: pip3 install yt-dlp"
    return 1
}

# Зависимости всех утилит: bash, curl/wget, python3, ffmpeg, jq, yt-dlp
ensure_deps() {
    detect_pm
    install_pkg bash   ""   bash || true
    install_pkg ffmpeg ""   ffmpeg || true
    install_pkg jq     ""   jq || true
    case "$PM" in
        apt|dnf|yum|zypper|apk)
            install_pkg python3 "" python3 || true
            ;;
        *)
            install_pkg python3 "" python python3 || true
            ;;
    esac
    install_ytdlp || true
}

# --- Установщики -------------------------------------------------------------

# Скачивает утилиту и адаптирует шебанг под текущую систему.
install_file() { # install_file <имя>
    target="$INSTALL_DIR/$1"
    info "Скачиваю $1…"
    if ! download "$RAW_BASE/$1" "$target"; then
        err "не удалось скачать $RAW_BASE/$1"
        return 1
    fi
    chmod 755 "$target"

    # Шебанг в репозитории термуксовый — заменяем на bash этой системы.
    if bash_path=$(command -v bash 2>/dev/null); then
        new_shebang="#!$bash_path"
    else
        new_shebang="#!/usr/bin/env bash"
        warn "не найден bash — оставляю #!/usr/bin/env bash (баш всё равно нужен)."
    fi
    # -i.bak работает и в GNU sed, и в BSD/macOS sed
    if sed -i.bak "1s|^#!.*|$new_shebang|" "$target" 2>/dev/null; then
        rm -f "$target.bak"
        ok "$1 установлен в $target (шебанг: $new_shebang)"
    else
        rm -f "$target.bak"
        ok "$1 установлен в $target (шебанг не изменён)"
    fi
}

install_ytd_tool() { install_file ytd; }
install_ttd_tool() { install_file ttd; }
install_scd_tool() { install_file scd; }

install_one() {
    case "$1" in
        ytd)    install_ytd_tool ;;
        ttd)    install_ttd_tool ;;
        scd)    install_scd_tool ;;
        all)    install_ytd_tool; install_ttd_tool; install_scd_tool ;;
        *)      err "неизвестная утилита: '$1' (доступны: ytd, ttd, scd, all)"; return 1 ;;
    esac
}

# --- Выбор утилит ------------------------------------------------------------

print_menu() {
    printf "\n%bДоступные утилиты:%b\n" "$C_BOLD" "$C_OFF"
    cat <<'EOF'
  1) ytd — загрузчик треков/видео с YouTube Music (mp3/mp4, обложка, теги, SponsorBlock)
  2) ttd — загрузчик треков/видео с TikTok (mp3/mp4, обложка и метаданные)
  3) scd — загрузчик треков с SoundCloud (mp3 + обложка и теги, треки/сеты/профили)
EOF
}

# Читаем ответ из /dev/tty, если он доступен (важно для «curl … | sh»),
# иначе из stdin.
read_reply() {
    if ( : < /dev/tty ) 2>/dev/null; then
        read -r REPLY < /dev/tty
    else
        read -r REPLY
    fi
}

pick_interactive() {
    print_menu
    printf "\nЧто установить? Номера через пробел/запятую (напр.: 1 3), 'all' — всё, 'q' — выход:\n> "
    read_reply || { echo; return 1; }
    REPLY=$(printf '%s' "$REPLY" | tr ',' ' ')
    set -- $REPLY
    [ $# -eq 0 ] && { warn "ничего не выбрано"; exit 0; }

    selected=""
    for tok in "$@"; do
        case "$tok" in
            1) name=ytd ;;
            2) name=ttd ;;
            3) name=scd ;;
            ytd|ttd|scd|all) name=$tok ;;
            q|quit|exit) info "Выход."; exit 0 ;;
            *) err "непонятный выбор: '$tok'"; exit 1 ;;
        esac
        selected="$selected $name"
    done

    failed=0
    for name in $selected; do
        install_one "$name" || failed=1
    done
    return $failed
}

# --- main --------------------------------------------------------------------

usage() {
    cat <<EOF
Использование:
  $0 [утилиты...]

Примеры:
  $0                 интерактивное меню
  $0 all             установить все три утилиты
  $0 ytd scd         установить только указанные

Через curl:
  curl -fsSL https://raw.githubusercontent.com/$REPO/$BRANCH/install.sh | sh
  curl -fsSL https://raw.githubusercontent.com/$REPO/$BRANCH/install.sh | sh -s -- ytd ttd scd

Переменные: INSTALL_DIR ($INSTALL_DIR), BRANCH ($BRANCH)
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
    esac
done

mkdir -p "$INSTALL_DIR"
if [ ! -w "$INSTALL_DIR" ]; then
    err "директория '$INSTALL_DIR' недоступна для записи."
    exit 1
fi

ensure_deps

if [ $# -gt 0 ]; then
    failed=0
    for arg in "$@"; do
        install_one "$arg" || failed=1
    done
    [ "$failed" -eq 0 ] || exit 1
else
    pick_interactive
fi

# Добавление INSTALL_DIR в PATH (автоматически для bash/zsh/sh/fish)

add_path_line() { # add_path_line <путь к файлу> <строка>
    [ -f "$1" ] || return 1
    if ! grep -qsF "$2" "$1"; then
        printf '\n# >>> dls PATH >>>\n%s\n# <<< dls PATH <<<\n' "$2" >> "$1"
        ok "$1: добавлено '$2'"
        return 0
    fi
    return 1
}

setup_path() {
    case ":$PATH:" in
        *":$INSTALL_DIR:"*) ok "INSTALL_DIR уже в PATH"; return 0 ;;
    esac

    added=0

    # fish: fish_add_path пишет в universal variables, rc-файл не нужен
    if need_cmd fish >/dev/null 2>&1 && fish -c "fish_add_path -U '$INSTALL_DIR'" >/dev/null 2>&1; then
        ok "fish: '$INSTALL_DIR' добавлен в PATH (universal)"
        added=1
    fi

    PATH_LINE="export PATH=\"$INSTALL_DIR:\$PATH\""
    add_path_line "$HOME/.bashrc"  "$PATH_LINE" && added=1
    add_path_line "$HOME/.zshrc"   "$PATH_LINE" && added=1
    add_path_line "$HOME/.profile" "$PATH_LINE" && added=1

    if [ "$added" -eq 0 ] && ! need_cmd fish; then
        printf 'export PATH="%s:$PATH"\n' "$INSTALL_DIR" > "$HOME/.profile"
        ok "Создан $HOME/.profile с PATH"
        added=1
    fi

    if [ "$added" -eq 1 ]; then
        warn "Открой новое окно терминала или выполни: source ~/.bashrc (или zshrc/profile) — чтобы PATH применился."
    fi
}

setup_path

printf "\n%bГотово!%b Утилиты вызываются по имени (ytd, ttd, scd).\n" "$C_GREEN" "$C_OFF"
