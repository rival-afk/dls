# install.ps1 — установщик dls на Windows (cmd / PowerShell), всё делает сам:
#   - качает скрипты ytd/ttd/scd и создаёт .cmd-лаунчеры (иначе Windows
#     открывает их в текстовом редакторе вместо запуска);
#   - при отсутствии качает с интернета: Git или PortableGit (bash, чтобы
#     исполнять скрипты), yt-dlp, jq, ffmpeg, python (embedded);
#   - добавляет ~/.local/bin в пользовательский PATH.
#
# Использование:
#   irm https://raw.githubusercontent.com/rival-afk/dls/main/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/rival-afk/dls/main/install.ps1))) ytd ttd
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/rival-afk/dls/main/install.ps1))) all
#
# Переменные: INSTALL_DIR (по умолчанию ~\.local\bin), APP_DIR (~\.local\share\dls), BRANCH (main)
param([string[]]$Tools)

$ProgressPreference = 'SilentlyContinue'

if ($env:INSTALL_DIR) { $INSTALL_DIR = $env:INSTALL_DIR } else { $INSTALL_DIR = Join-Path $env:USERPROFILE '.local\bin' }
if ($env:APP_DIR)     { $APP_DIR = $env:APP_DIR }         else { $APP_DIR = Join-Path $env:USERPROFILE '.local\share\dls' }
if ($env:BRANCH)      { $BRANCH = $env:BRANCH }           else { $BRANCH = 'main' }
$RAW = "https://raw.githubusercontent.com/rival-afk/dls/$BRANCH"

# --- мелочи -------------------------------------------------------------------

function Info([string]$m) { Write-Host "==> $m" }
function Ok([string]$m)   { Write-Host "  OK $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Err([string]$m)  { Write-Host "  X $m" -ForegroundColor Red }

# Скачивание файла: сначала curl.exe (Win10+), потом Invoke-WebRequest.
function Fetch([string]$url, [string]$dest) {
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -fsSL $url -o $dest 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) { return $true }
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest
        return (Test-Path $dest)
    } catch { return $false }
}

# Есть ли настоящая (не магазинная заглушка) команда
function Real-Exe([string]$name) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $c) { return $null }
    if ($c.Source -and $c.Source -like '*WindowsApps*') {
        # заглушка Microsoft Store
        $out = & $c.Source -c "print('ok')" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
    }
    return $c.Source
}

function Unblock([string]$path) { if (Test-Path $path) { Unblock-File $path -ErrorAction SilentlyContinue } }

$IS_ARM64 = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64')

# --- зависимости ---------------------------------------------------------------

function Ensure-Curl {
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        Warn 'curl.exe не найден (нужен Windows 10 1803+). Установи curl или обнови Windows.'
        throw 'no curl'
    }
}

# --- реальные утилиты -----------------------------------------------------------

function Deps-Jq {
    if (Test-Path "$INSTALL_DIR\jq.exe") { Ok 'jq установлен'; return }
    $asset = if ($IS_ARM64) { 'jq-windows-arm64.exe' } else { 'jq-windows-amd64.exe' }
    Info "Качаю jq с GitHub…"
    if (Fetch "https://github.com/jqlang/jq/releases/latest/download/$asset" "$INSTALL_DIR\jq.exe") {
        Unblock "$INSTALL_DIR\jq.exe"; Ok "jq установлен в $INSTALL_DIR\jq.exe"
    } else { Err 'не удалось скачать jq'; $script:depsFailed = $true }
}

function Deps-YtDlp {
    if (Test-Path "$INSTALL_DIR\yt-dlp.exe") { Ok 'yt-dlp установлен'; return }
    $asset = if ($IS_ARM64) { 'yt-dlp_arm64.exe' } else { 'yt-dlp.exe' }
    Info 'Качаю yt-dlp с GitHub…'
    if (Fetch "https://github.com/yt-dlp/yt-dlp/releases/latest/download/$asset" "$INSTALL_DIR\yt-dlp.exe") {
        Unblock "$INSTALL_DIR\yt-dlp.exe"; Ok "yt-dlp установлен в $INSTALL_DIR\yt-dlp.exe"
    } else { Err 'не удалось скачать yt-dlp'; $script:depsFailed = $true }
}

function Deps-Ffmpeg {
    if ((Test-Path "$APP_DIR\ffmpeg\ffmpeg.exe") -and (Test-Path "$APP_DIR\ffmpeg\ffprobe.exe")) { Ok 'ffmpeg установлен'; return }
    if ((Real-Exe 'ffmpeg') -and (Real-Exe 'ffprobe')) { Ok 'ffmpeg найден в PATH'; return }
    $tag = if ($IS_ARM64) { 'winarm64' } else { 'win64' }
    $zip = Join-Path $APP_DIR 'ffmpeg.zip'
    Info 'Качаю ffmpeg (архив BtbN, примерно 100-170 МБ — одноразово)…'
    if (-not (Fetch "https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-$tag-gpl.zip" $zip)) {
        Err 'не удалось скачать ffmpeg'; $script:depsFailed = $true; return
    }
    $tmp = Join-Path $APP_DIR '_ffmpeg_tmp'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    try { Expand-Archive -Force -Path $zip -DestinationPath $tmp } catch {
        Err 'не удалось распаковать ffmpeg'; $script:depsFailed = $true; return
    } finally { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
    $bin = Get-ChildItem $tmp -Recurse -Directory -Filter 'bin' | Select-Object -First 1
    if (-not $bin) { Err 'в архиве ffmpeg нет папки bin'; $script:depsFailed = $true; return }
    New-Item -ItemType Directory -Force -Path "$APP_DIR\ffmpeg" | Out-Null
    if (Test-Path "$APP_DIR\ffmpeg") { Remove-Item "$APP_DIR\ffmpeg\*" -Recurse -Force -ErrorAction SilentlyContinue }
    Get-ChildItem $bin.FullName -File | ForEach-Object { Move-Item $_.FullName "$APP_DIR\ffmpeg\" -Force }
    Remove-Item $tmp -Recurse -Force
    Unblock "$APP_DIR\ffmpeg\ffmpeg.exe"; Unblock "$APP_DIR\ffmpeg\ffprobe.exe"
    Ok "ffmpeg установлен в $APP_DIR\ffmpeg"
}

function Deps-Python {
    $pyDir = Join-Path $APP_DIR 'python3'
    if (Test-Path "$pyDir\python3.exe") { Ok 'python3 установлен'; return }
    # скрипты вызывают команду python3; если её нет — ставим embedded
    # (свою копию: python.exe/python/py-лаунчер под именем python3 надёжно не работают)
    if (Real-Exe 'python3') { Ok 'python3 найден в PATH'; return }
    $ver = '3.12.10'
    $arch = if ($IS_ARM64) { 'arm64' } else { 'amd64' }
    $url = "https://www.python.org/ftp/python/$ver/python-$ver-embed-$arch.zip"
    $zip = Join-Path $APP_DIR 'python.zip'
    Info 'Качаю python (embedded, ~11 МБ)…'
    if (-not (Fetch $url $zip)) { Err 'не удалось скачать python'; $script:depsFailed = $true; return }
    if (Test-Path $pyDir) { Remove-Item $pyDir -Recurse -Force }
    Expand-Archive -Force -Path $zip -DestinationPath $pyDir
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    # Скрипты вызывают команду python3 — а в embedded она python.exe.
    # Копируем exe под именем python3.exe и делаем для него python3._pth
    # (Windows-питон ищет .pth-файл по имени exe).
    Copy-Item "$pyDir\python.exe" "$pyDir\python3.exe" -Force
    $pth = Get-ChildItem $pyDir -Filter 'python*._pth' | Select-Object -First 1
    if ($pth) { Copy-Item $pth.FullName "$pyDir\python3._pth" -Force }
    Unblock "$pyDir\python3.exe"
    Ok "python3 установлен в $pyDir"
}

# Bash, чтобы исполнять bash-скрипты: ищем Git Bash, иначе качаем PortableGit
function Deps-Bash {
    Info 'Ищу Git Bash…'
    $cands = @()
    if ($env:ProgramFiles) { $cands += (Join-Path $env:ProgramFiles 'Git\bin\bash.exe') }
    if (${env:ProgramFiles(x86)}) { $cands += (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe') }
    if ($env:LOCALAPPDATA) { $cands += (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe') }
    foreach ($c in $cands) { if (Test-Path $c) { Ok "bash найден: $c"; return $c } }
    $b = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($b -and $b.Source -and ($b.Source -notlike '*System32*')) {
        Ok "bash найден: $($b.Source)"; return $b.Source
    }

    Info 'Git Bash не найден — качаю PortableGit (~60 МБ, одноразово)…'
    $tag = if ($IS_ARM64) { 'arm64' } else { '64-bit' }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $rel = Invoke-RestMethod -UseBasicParsing 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    } catch { Err 'не удалось получить список релизов git-for-windows'; $script:depsFailed = $true; return $null }
    $asset = $rel.assets | Where-Object { $_.name -like "PortableGit*-$tag.7z.exe" } | Select-Object -First 1
    if (-not $asset) { Err 'не нашёл PortableGit в релизах'; $script:depsFailed = $true; return $null }
    $sfx = Join-Path $APP_DIR $asset.name
    if (-not (Fetch $asset.browser_download_url $sfx)) { Err "не удалось скачать $($asset.name)"; $script:depsFailed = $true; return $null }
    Ok "Качаю: $($asset.name)"
    $gitDir = Join-Path $APP_DIR 'git'
    if (Test-Path $gitDir) { Remove-Item $gitDir -Recurse -Force }
    & $sfx "-o$gitDir" -y | Out-Null
    Unblock "$gitDir\bin\bash.exe"
    if (Test-Path "$gitDir\bin\bash.exe") { Ok "PortableGit распакован в $gitDir"; return "$gitDir\bin\bash.exe" }
    Err 'PortableGit не распаковался'; $script:depsFailed = $true; return $null
}

function Ensure-Deps {
    if ($script:depsDone) { return $script:bashPath }
    Ensure-Curl
    New-Item -ItemType Directory -Force -Path $INSTALL_DIR, $APP_DIR | Out-Null
    Deps-Ffmpeg
    Deps-Jq
    Deps-YtDlp
    Deps-Python
    $script:bashPath = Deps-Bash
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Warn 'node не найден — для части роликов YouTube yt-dlp попросит JS-рантайм. Если будут ошибки, поставь node.'
    }
    $script:depsDone = $true
    return $script:bashPath
}

# --- установка утилит -----------------------------------------------------------

function Make-Launcher([string]$name, [string]$bashPath) {
    $py = Join-Path $APP_DIR 'python3'
    $ff = Join-Path $APP_DIR 'ffmpeg'
    $pathPart = "$INSTALL_DIR;%PATH%"
    if (Test-Path $py) { $pathPart = "$py;$pathPart" }
    if (Test-Path $ff) { $pathPart = "$ff;$pathPart" }
    $content = "@echo off" + "`r`n" + "chcp 65001 >nul" + "`r`n" +
        "set `"PATH=$pathPart`"" + "`r`n" +
        "`"$bashPath`" --norc --noprofile `"$INSTALL_DIR\$name`" %*" + "`r`n"
    # UTF-8 без BOM: пути могут быть не-ASCII, а cmd задавит BOM в первой строке
    [System.IO.File]::WriteAllText("$INSTALL_DIR\$name.cmd", $content, (New-Object System.Text.UTF8Encoding($false)))
    Ok "$name.cmd создан (запуск из cmd/PowerShell)"
}

function Install-Tool([string]$name, [string]$bashPath) {
    Info "Скачиваю $name…"
    if (-not (Fetch "$RAW/$name" "$INSTALL_DIR\$name")) {
        Err "не удалось скачать $RAW/$name"; return $false
    }
    Unblock "$INSTALL_DIR\$name"
    Make-Launcher $name $bashPath
    Ok "$name установлен в $INSTALL_DIR"
    return $true
}

# --- PATH -----------------------------------------------------------------------

function Add-UserPath([string]$d) {
    $p = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $p) { $p = '' }
    $parts = $p -split ';' | Where-Object { $_ -ne '' }
    if ($parts -notcontains $d) {
        $p = ($p.TrimEnd(';') + ';' + $d)
        [Environment]::SetEnvironmentVariable('Path', $p, 'User')
        Ok "в пользовательский PATH добавлено: $d"
        Write-Host '  (открой новое окно терминала, чтобы PATH применился)' -ForegroundColor Yellow
    } else { Ok "$d уже в PATH" }
}

function Setup-Bashrc {
    $bashrc = Join-Path $env:USERPROFILE '.bashrc'
    $marker = '# >>> dls PATH >>>'
    if ((Test-Path $bashrc) -and ((Get-Content $bashrc -Raw) -match [regex]::Escape($marker))) { Ok 'bashrc уже настроен'; return }
    $block = "`r`n$marker`r`n" +
        'export PATH="$HOME/.local/bin:$PATH"' + "`r`n" +
        'export PATH="$HOME/.local/share/dls/ffmpeg:$HOME/.local/share/dls/python3:$PATH"' + "`r`n" +
        '# <<< dls PATH <<<' + "`r`n"
    if (Test-Path $bashrc) {
        # ASCII-строки, Add-Content без BOM-сюрпризов
        Add-Content -Path $bashrc -Value $block -Encoding Ascii
    } else {
        [System.IO.File]::WriteAllText($bashrc, $block, (New-Object System.Text.UTF8Encoding($false)))
    }
    Ok '$HOME/.bashrc: добавлен PATH для Git Bash'
}

# --- выбор того, что ставить -----------------------------------------------------

function Pick-Tools {
    Write-Host ''
    Write-Host 'Доступные утилиты:'
    Write-Host '  1) ytd — загрузчик треков/видео с YouTube Music (mp3/mp4, обложка, теги, SponsorBlock)'
    Write-Host '  2) ttd — загрузчик треков/видео с TikTok (mp3/mp4, обложка и метаданные)'
    Write-Host '  3) scd — загрузчик треков с SoundCloud (mp3 + обложка и теги, треки/сеты/профили)'
    Write-Host ''
    $r = Read-Host "Что установить? Номера через пробел/запятую (напр.: 1 3), 'all' — всё, 'q' — выход"
    $r = $r -replace ',', ' '
    $res = @()
    foreach ($t in ($r -split '\s+')) {
        if ($t -eq '') { continue }
        switch -Regex ($t) {
            '^1$' { $res += 'ytd' }
            '^2$' { $res += 'ttd' }
            '^3$' { $res += 'scd' }
            '^(all|ytd|ttd|scd)$' { $res += $t }
            '^(q|quit|exit)$' { return @() }
            default { Err "непонятный выбор: '$t'"; throw 'bad choice' }
        }
    }
    if ($res -contains 'all') { return @('ytd', 'ttd', 'scd') }
    return $res | Select-Object -Unique
}

# --- main ------------------------------------------------------------------------

$failed = $false
if (-not $Tools -or $Tools.Count -eq 0) {
    $Tools = Pick-Tools
    if (-not $Tools -or $Tools.Count -eq 0) { Write-Host 'Выход.'; return }
}
if ($Tools -contains 'all') { $Tools = @('ytd', 'ttd', 'scd') }

$bashPath = Ensure-Deps
if ($script:depsFailed) { Err 'часть зависимостей установить не удалось — утилита может не заработать.' }

foreach ($t in $Tools) {
    switch ($t) {
        'ytd' { if (-not (Install-Tool 'ytd' $bashPath)) { $failed = $true } }
        'ttd' { if (-not (Install-Tool 'ttd' $bashPath)) { $failed = $true } }
        'scd' { if (-not (Install-Tool 'scd' $bashPath)) { $failed = $true } }
        default { Err "неизвестная утилита: '$t' (доступны: ytd, ttd, scd, all)"; $failed = $true }
    }
}

Add-UserPath $INSTALL_DIR
Setup-Bashrc

if (-not $failed) {
    Write-Host ''
    Write-Host 'Готово! Утилиты вызываются по имени (ytd, ttd, scd) из любого окна cmd/PowerShell/Git Bash.' -ForegroundColor Green
    Write-Host 'Если запущенный терминал открыт — открой новое окно.' -ForegroundColor Yellow
} else {
    exit 1
}
