#!/data/data/com.termux/files/usr/bin/bash
#
# scd — загрузчик треков с SoundCloud (см. scd -h).
# Файлы создаются в текущей папке: название, обложка, метаданные.

set -euo pipefail

CACHE_DIR="$HOME/.cache/scd"
mkdir -p "$CACHE_DIR"
rm -f "$CACHE_DIR/meta.json" "$CACHE_DIR"/meta_cover*.jpg

show_help() {
    cat <<'EOF'
scd — загрузчик треков с SoundCloud

Использование:
  scd                       спросить URL
  scd <URL>                 скачать mp3 (обложка + метаданные)
  scd <любой текст>         из текста вырезается всё до https:// — можно
                            вставлять шаринг SoundCloud целиком, даже если
                            URL приклеен к словам. Если shell съел ссылку
                            как комментарий (в шаринге есть #), scd достаёт
                            её из последней записи истории команд.

Флаги:
  -m, --metadata <SRC>      название файла, теги и обложку взять из <SRC>
                            (ссылка на SoundCloud/YouTube, аудио/видеофайл
                            или картинка)
  -h, --help                эта справка

Плейлисты:
  сет (soundcloud.com/artist/sets/...), профиль soundcloud.com/artist,
  лайки soundcloud.com/artist/likes — скачиваются построчно, каждый трек
  отдельным mp3 в текущую папку. Вложенные сеты внутри профиля тоже
  скачиваются построчно. Треки, требующие SoundCloud Go+/DRM или
  недоступные, пропускаются с предупреждением.

  Обложка и теги каждого трека берутся с самого SoundCloud;
  -m к плейлисту не применяется (все треки получили бы одно имя).

Переменные окружения:
  SCD_COOKIES               путь к cookies.txt для yt-dlp
                            (приватные треки, «оригинальное» качество)

Примеры:
  scd https://soundcloud.com/artist/track
  scd https://soundcloud.com/artist/track -m ./track.mp3
  scd https://soundcloud.com/artist/sets/my-set
  scd Listen to track by artist on #SoundCloudhttps://on.soundcloud.com/abc123

Обложка обрезается от одноцветных полей по краям и встраивается в файл,
после чего её временные файлы удаляются.
EOF
}

COOKIES_FILE="${SCD_COOKIES:-$HOME/projects/scd/cookies.txt}"
META_SRC_PATH=""

is_soundcloud() {
    [[ "$1" =~ (^|://)([a-z0-9-]+\.)*soundcloud\.com/ ]]
}

is_playlist() {
    local url="$1"
    [[ "$url" == *"/sets/"* ]] && return 0
    [[ "$url" =~ soundcloud\.com/[^/?#]+/(likes|tracks|albums|playlists|reposts|popular-tracks|following|followers|history)(/|$|\?|#) ]] && return 0
    [[ "$url" =~ soundcloud\.com/(discover|charts|stream)(/|$|\?|#) ]] && return 0
    # профиль: только имя исполнителя, без конкретного трека/сета
    [[ "$url" =~ ^https?://(www\.|m\.)?soundcloud\.com/[^/?#]+/?$ ]] && return 0
    return 1
}

expand_short_url() {
    local url="$1"
    [[ "$url" == *on.soundcloud.com/* ]] || { printf '%s\n' "$url"; return 0; }
    local out
    out=$(curl -sSIL --max-time 15 -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null || true)
    if [[ -n "$out" && "$out" != *on.soundcloud.com* ]]; then
        printf '%s\n' "$out"
    else
        printf '%s\n' "$url"
    fi
}

# Обрезает всё до ссылки: "Listen ... #SoundCloudhttps://on.soundcloud.com/x"
# превращается в "https://on.soundcloud.com/x". Без ссылки — код 1.
extract_url() {
    local text="$1" url

    case "$text" in
        *https://*) url="https://${text#*https://}" ;;
        *http://*)  url="http://${text#*http://}" ;;
        *) return 1 ;;
    esac

    url="${url%% *}"
    url="${url%%$'\t'*}"
    url="${url%%$'\n'*}"
    url="${url%%$'\r'*}"
    [[ -n "${url#*://}" ]] || return 1
    printf '%s\n' "$url"
}

# Последняя запись истории (zsh дописывает её до запуска команды).
# Нужна, когда shell съел хвост строки как комментарий (# в шаринге SoundCloud).
last_history_command() {
    local f="" cand
    for cand in "${HISTFILE:-}" "$HOME/.zsh_history" \
                "$HOME/.local/share/zsh/history" "$HOME/.bash_history"; do
        [[ -n "$cand" && -r "$cand" && -s "$cand" ]] || continue
        f="$cand"
        break
    done
    [[ -n "$f" ]] || return 1

    # берём только если файл дописан только что (то есть там текущая команда)
    local now mtime
    now=$(date +%s)
    mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    (( now - mtime <= 60 )) || return 1

    tail -c 16384 "$f" 2>/dev/null | awk '
        { line[NR] = $0 }
        END {
            s = 1
            for (i = NR; i >= 1; i--) {
                if (line[i] ~ /^: [0-9]+:[0-9]+;/) { s = i; break }
                if (line[i] ~ /^#[0-9]+$/ && i < NR) { s = i + 1; break }
            }
            for (i = s; i <= NR; i++) print line[i]
        }' \
        | sed -e ':a' -e 'N' -e '$!ba' \
              -e 's/^: [0-9][0-9]*:[0-9][0-9]*;//' \
              -e 's/\\\n/ /g' -e 's/\\\(.\)/\1/g'
}

url_from_history() {
    local need="${1:-}" cmd
    cmd=$(last_history_command) || return 1
    cmd="${cmd//$'\r'/}"
    [[ "$cmd" =~ ^scd([[:space:]]|$) ]] || return 1
    # запись должна относиться к текущему запуску, а не к прошлому
    [[ -z "$need" || "$cmd" == *"$need"* ]] || return 1
    extract_url "$cmd"
}

fetch_playlist() {
    local url="$1"
    local err="$CACHE_DIR/.playlist.err"
    local args=(--flat-playlist -J)
    [[ -f "$COOKIES_FILE" ]] && args+=(--cookies "$COOKIES_FILE")
    if ! yt-dlp "${args[@]}" "$url" 2>"$err"; then
        sed 's/^/  /' "$err" >&2 || true
        rm -f "$err"
        return 1
    fi
    rm -f "$err"
}

trim_thumbnail() {
    local img="$1"
    python3 -c "
from PIL import Image
import sys

def is_solid(col_pixels, tol=3):
    r0, g0, b0 = col_pixels[0]
    return all(abs(r - r0) <= tol and abs(g - g0) <= tol and abs(b - b0) <= tol
               for r, g, b in col_pixels)

img = Image.open(sys.argv[1]).convert('RGB')
px = img.load()
w, h = img.size
cols = [[px[x, y] for y in range(h)] for x in range(w)]

left = 0
while left < w:
    if is_solid(cols[left]):
        left += 1
    else:
        break

right = w - 1
while right > left:
    if is_solid(cols[right]):
        right -= 1
    else:
        break

if left > 0 or right < w - 1:
    img = img.crop((left, 0, right + 1, h))

out = sys.argv[1].rsplit('.', 1)[0] + '_trimmed.jpg'
img.save(out, 'JPEG', quality=95)
print(out)
" "$img"
}

has_meta() {
    [[ -s "$CACHE_DIR/meta.json" ]]
}

meta_get() {
    jq -r --arg k "$1" '.[$k] // empty' "$CACHE_DIR/meta.json" 2>/dev/null || true
}

meta_cover() {
    if [[ -f "$CACHE_DIR/meta_cover.jpg" ]]; then
        echo "$CACHE_DIR/meta_cover.jpg"
    fi
}

rename_to_meta() {
    local file="$1"
    has_meta || { echo "$file"; return; }
    local title
    title=$(meta_get title)
    [[ -n "$title" ]] || { echo "$file"; return; }

    title="${title//\//}"
    local dir ext target
    dir=$(dirname "$file")
    ext="${file##*.}"

    # защита от "Название.mp3.mp3":
    # убираем любое медиа-расширение в конце названия
    local media_ext='mp3|mp4|m4a|webm|opus|ogg|oga|flac|wav|aac|mkv|mov|avi|jpg|jpeg|png|webp'
    if [[ "${title,,}" =~ \.($media_ext)$ ]]; then
        title="${title%.*}"
    fi
    [[ -n "$title" ]] || { echo "$file"; return; }

    target="$dir/$title.$ext"
    if [[ "$target" == "$file" ]]; then
        echo "$file"
        return
    fi
    # не затираем сам файл-источник метаданных
    if [[ -n "${META_SRC_PATH:-}" && "$target" == "$META_SRC_PATH" ]]; then
        echo "$file"
        return
    fi
    mv -f "$file" "$target" 2>/dev/null && echo "$target" || echo "$file"
}

finalize() {
    local file="$1"
    local cover="${2:-}"
    local tmp="${file}.tmp.${file##*.}"
    local -a md=()

    if has_meta; then
        local key src
        for key in title artist album album_artist track genre; do
            src=$(meta_get "$key")
            [[ -n "$src" ]] && md+=(-metadata "$key=$src")
        done
        src=$(meta_get release_year)
        [[ -n "$src" ]] && md+=(-metadata "date=$src")
    fi

    if [[ -n "$cover" && -f "$cover" && -f "$file" ]]; then
        ffmpeg -y -i "$file" -i "$cover" \
            -map 0:a -map 1:v -c:a copy -c:v copy \
            -id3v2_version 3 -disposition:v:0 attached_pic \
            -metadata:s:v title="Album cover" \
            -metadata:s:v comment="Cover (front)" \
            ${md[@]+"${md[@]}"} \
            "$tmp" 2>/dev/null || true
    elif [[ ${#md[@]} -gt 0 ]]; then
        ffmpeg -y -i "$file" -c copy ${md[@]+"${md[@]}"} "$tmp" 2>/dev/null || true
    else
        return 0
    fi

    if [[ -f "$tmp" ]]; then
        mv -f "$tmp" "$file"
    else
        rm -f "$tmp"
    fi
}

meta_from() {
    local src="$1"
    local out="$CACHE_DIR/meta.json"
    local cover="$CACHE_DIR/meta_cover.jpg"
    rm -f "$out" "$cover"

    if [[ -f "$src" ]]; then
        ffprobe -v quiet -print_format json -show_format "$src" 2>/dev/null \
            | jq '{
                title: .format.tags.title,
                artist: .format.tags.artist,
                album: .format.tags.album,
                album_artist: .format.tags.album_artist,
                track: .format.tags.track,
                release_year: .format.tags.date,
                genre: .format.tags.genre
            } | with_entries(select(.value != null and .value != ""))' > "$out"

        ffmpeg -y -i "$src" -an -c:v copy "$cover" 2>/dev/null || rm -f "$cover"
        if [[ -f "$cover" ]]; then
            jq --arg c "$cover" '. + {thumbnail: $c}' "$out" > "$out.tmp" \
                && mv "$out.tmp" "$out"
        fi
    else
        # источник может быть где угодно (в т.ч. YouTube) — ютубовские опции не мешают
        local args=(
            --skip-download -J
            --js-runtimes node
            --remote-components ejs:github
            --extractor-args 'youtube:player_client=web_embedded'
        )
        [[ -f "$COOKIES_FILE" ]] && args+=(--cookies "$COOKIES_FILE")
        yt-dlp "${args[@]}" "$src" 2>/dev/null | jq '{
            title, artist, album, album_artist, track, track_number,
            release_year, genre, thumbnail, thumbnails
        } | with_entries(select(.value != null))' > "$out"

        local thumb_url
        thumb_url=$(jq -r '.thumbnail // (.thumbnails | last | .url) // empty' "$out" 2>/dev/null || true)
        if [[ -n "$thumb_url" ]]; then
            ffmpeg -y -i "$thumb_url" -frames:v 1 -q:v 2 "$cover" 2>/dev/null \
                || curl -fsSL --max-time 30 "$thumb_url" -o "$cover" 2>/dev/null \
                || rm -f "$cover"
        fi
    fi

    [[ -s "$out" ]]
}

prepare_meta() {
    local src="$1"
    [[ -n "$src" ]] || return 1
    if meta_from "$src"; then
        return 0
    fi
    rm -f "$CACHE_DIR/meta.json" "$CACHE_DIR"/meta_cover*.jpg
    return 1
}

dedupe_ext() {
    local ext="$1"
    local f
    shopt -s nullglob
    for f in *."$ext"."$ext"; do
        mv -f "$f" "${f%."$ext"}"
    done
    shopt -u nullglob
}

resolve_cover() {
    local file="$1"
    local raw=""
    if has_meta; then
        raw=$(meta_cover)
    else
        # обложка пишется yt-dlp с тем же именем, что и трек
        local base="${file%.mp3}"
        if [[ -f "$base.jpg" ]]; then
            raw="$base.jpg"
        else
            raw=$(find "$PWD" -maxdepth 1 -name '*.jpg' -newer "$CACHE_DIR/.marker" -print 2>/dev/null | head -n 1 || true)
        fi
    fi
    [[ -n "$raw" && -f "$raw" ]] || return 0

    local trimmed
    trimmed=$(trim_thumbnail "$raw" || true)
    if [[ -n "$trimmed" && -f "$trimmed" ]]; then
        rm -f "$raw"
        printf '%s\n' "$trimmed"
    elif [[ -f "$raw" ]]; then
        printf '%s\n' "$raw"
    fi
}

clean_thumbnail() {
    # обложки, записанные текущим запуском yt-dlp (новее маркера), — наши;
    # после встраивания в файл они больше не нужны
    local f
    while IFS= read -r f; do
        [[ -n "$f" && "$f" != "${META_SRC_PATH:-}" ]] && rm -f "$f"
    done < <(find "$PWD" -maxdepth 1 \( -name '*.jpg' -o -name '*.webp' \) \
                 -newer "$CACHE_DIR/.marker" -print 2>/dev/null)
    rm -f "$CACHE_DIR/meta_cover.jpg" "$CACHE_DIR/meta_cover_trimmed.jpg"
}

locate_output() {
    local ext="$1"
    local f=""

    if [[ -f "$CACHE_DIR/.lastfile" ]]; then
        f=$(grep -E "\.${ext}\$" "$CACHE_DIR/.lastfile" 2>/dev/null | tail -n 1 || true)
    fi
    if [[ -z "$f" || ! -f "$f" ]]; then
        f=$(find "$PWD" -maxdepth 1 -name "*.${ext}" -newer "$CACHE_DIR/.marker" -print 2>/dev/null | head -n 1 || true)
    fi
    printf '%s\n' "$f"
}

download_track() {
    local url="$1"
    echo
    echo "▶ Скачиваю (mp3): $url"

    local args=(
        -x
        --audio-format mp3
        --audio-quality 0
        --embed-metadata
        --no-playlist
        --newline
        --print-to-file after_move:filepath "$CACHE_DIR/.lastfile"
        -o '%(title)s.%(ext)s'
    )
    if ! has_meta; then
        args+=(--write-thumbnail --convert-thumbnails jpg)
    fi
    [[ -f "$COOKIES_FILE" ]] && args+=(--cookies "$COOKIES_FILE")
    rm -f "$CACHE_DIR/.lastfile"
    touch "$CACHE_DIR/.marker"
    if ! yt-dlp "${args[@]}" "$url"; then
        echo "✖ Не удалось скачать (mp3): $url" >&2
        clean_thumbnail
        return 1
    fi

    local new
    new=$(locate_output mp3)
    if [[ -z "$new" ]]; then
        # yt-dlp мог оставить только обложку (например, если mp3 не создался)
        clean_thumbnail
        echo "✓ Готово (mp3 в текущей папке)."
        return
    fi

    if has_meta; then
        new=$(rename_to_meta "$new")
        dedupe_ext mp3
        [[ -f "$new" ]] || new=$(locate_output mp3)
        [[ -n "$new" && -f "$new" ]] || { clean_thumbnail; echo "✓ Готово (mp3 в текущей папке)."; return; }
    fi

    local cover
    cover=$(resolve_cover "$new" || true)
    echo "▶ Встраиваю обложку и метаданные..."
    finalize "$new" "$cover"
    [[ -n "$cover" ]] && rm -f "$cover"
    clean_thumbnail
    dedupe_ext mp3

    echo "✓ Сохранено: $new"
}

entry_title() {
    local url="$1"
    local title="$2"
    if [[ -n "$title" ]]; then
        printf '%s\n' "$title"
    else
        # у сетов в плоском списке названия нет — берём из адреса
        local slug="${url%%\?*}"
        slug="${slug%/}"
        slug="${slug##*/}"
        printf '%s\n' "${slug//-/ }"
    fi
}

download_playlist() {
    local url="$1"
    local depth="${2:-0}"
    echo
    echo "▶ Обнаружен плейлист, получаю список треков..."
    local json
    json=$(fetch_playlist "$url") || {
        echo "✖ Не удалось получить плейлист"
        return 1
    }

    local count
    count=$(echo "$json" | jq '.entries | length' 2>/dev/null || echo 0)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0

    if [[ "$count" -eq 0 ]]; then
        echo "✖ Плейлист пуст или недоступен"
        return 1
    fi

    local name
    name=$(echo "$json" | jq -r '.title // empty' 2>/dev/null || true)
    [[ -n "$name" ]] && echo "▶ $name"
    echo "▶ Найдено треков: $count"
    echo

    local i=1 ok=0 fail=0
    while IFS=$'\t' read -r track_url title; do
        [[ -n "$track_url" ]] || continue
        echo "[$i/$count] $(entry_title "$track_url" "$title")"
        if download "$track_url" "$((depth + 1))"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
            echo "⚠ Пропущен: $(entry_title "$track_url" "$title")" >&2
        fi
        i=$((i + 1))
    done < <(echo "$json" | jq -r '.entries[] | [(.webpage_url // .url // ""), (.title // "")] | @tsv' 2>/dev/null)

    echo
    if (( fail > 0 )); then
        echo "✓ Плейлист: загружено $ok из $count (пропущено $fail)"
    else
        echo "✓ Плейлист загружен: $count треков"
    fi
}

download() {
    local url="$1"
    local depth="${2:-0}"
    url=$(expand_short_url "$url")

    if is_playlist "$url"; then
        if (( depth >= 3 )); then
            echo "✖ Вложенных плейлистов слишком много, пропускаю: $url" >&2
            return 1
        fi
        if has_meta; then
            echo "⚠ -m не применяется к плейлисту (все треки получили бы одно имя)," >&2
            echo "  скачиваю с метаданными с SoundCloud" >&2
rm -f "$CACHE_DIR/meta.json" "$CACHE_DIR"/meta_cover*.jpg
        fi
        download_playlist "$url" "$depth"
    else
        download_track "$url"
    fi
}

if (( $# >= 1 )); then
    url=""
    meta_src=""
    text=""
    pos=()

    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -m|--metadata)
                if (( $# < 2 )); then
                    echo "✖ После $1 нужен источник метаданных (URL или файл)" >&2
                    exit 1
                fi
                meta_src="$2"
                shift 2
                ;;
            -*)
                echo "✖ Неизвестный флаг: $1" >&2
                exit 1
                ;;
            *)
                pos+=("$1")
                shift
                ;;
        esac
    done

    # весь ввод целиком: и чистый URL, и текст шаринга со вклеенной ссылкой
    text="${pos[*]}"

    if [[ -z "${text// /}" ]]; then
        echo "✖ Укажи URL: scd <URL> [-m <SRC>]" >&2
        echo "  (scd -h — подробная справка)" >&2
        exit 1
    fi

    if url=$(extract_url "$text"); then
        if (( ${#pos[@]} > 1 )) || [[ "$text" != "$url" ]]; then
            echo "▶ Нашёл ссылку: $url"
        fi
    elif (( ${#pos[@]} == 1 )) && [[ -f "$text" ]]; then
        url="$text"
    elif url=$(url_from_history "$text"); then
        echo "▶ Ссылку съел shell (комментарий #), нашёл её в истории: $url"
    else
        echo "✖ В тексте не нашёл ссылку:" >&2
        echo "  $text" >&2
        echo "  (вставь саму ссылку или закавычь текст)" >&2
        exit 1
    fi

    if ! is_soundcloud "$url" && [[ ! -f "$url" ]]; then
        echo "⚠ Похоже, это не ссылка SoundCloud: $url" >&2
    fi

    if [[ -n "$meta_src" ]]; then
        if [[ -f "$meta_src" ]]; then
            META_SRC_PATH="$(cd "$(dirname "$meta_src")" && pwd)/$(basename "$meta_src")"
        fi
        echo "▶ Беру метаданные и обложку из: $meta_src"
        if ! prepare_meta "$meta_src"; then
            echo "✖ Не удалось получить метаданные, продолжаю без них" >&2
        fi
    fi

    download "$url"
    exit 0
fi

echo "scd — загрузчик треков с SoundCloud (mp3 + обложка + метаданные)"
echo "Пустая строка — выход. Ctrl+C — прервать загрузку."
echo

while :; do
    printf 'Вставь URL или текст со ссылкой: '
    read -r line || true
    line="${line//[$'\r\n']/}"
    if [[ -z "$line" ]]; then
        echo "Пока!"
        exit 0
    fi
    if url=$(extract_url "$line"); then
        [[ "$line" != "$url" ]] && echo "▶ Нашёл ссылку: $url"
    elif [[ -f "$line" ]]; then
        url="$line"
    else
        echo "✖ В тексте не нашёл ссылку, попробуй ещё раз" >&2
        continue
    fi
    download "$url" || true
done
