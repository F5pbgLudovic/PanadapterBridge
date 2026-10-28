# PanadapterBridge 1.0 — @F5PBG 2026 — Passerelle ExpertSDR3 (ColibriNANO sur la 1ère FI du FT-2000) <-> FT-2000
# PowerShell / WinForms : fonctionne tel quel sous Windows 10 et 11, sans rien installer.
# Lancer avec PanadapterBridge.bat (ou : powershell -STA -ExecutionPolicy Bypass -File PanadapterBridge.ps1)
#
# Ce que fait le programme :
#   - un clic dans le panorama d'ExpertSDR3 fait QSYer le FT-2000 sur la fréquence cliquée
#     (inversion de la FI prise en compte, arrondi au pas choisi), puis ExpertSDR3 est
#     ramené sur la FI : le signal cliqué est au centre, et le FT-2000 est dessus ;
#   - un cran de molette dans ExpertSDR3 déplace le FT-2000 d'un pas fixe (100..500 Hz) ;
#   - le mode du FT-2000 est recopié dans ExpertSDR3 (LSB/USB échangés), et la FI écoutée
#     est choisie selon ce mode (le FT-2000 décale son oscillateur de la porteuse BLU).
#
# Lecture/écriture du FT-2000 : serveur IP de Ham Radio Deluxe (port 7809), ou CAT direct (COM).

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppName = 'PanadapterBridge'
$Version = '1.0'
$AppDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$CfgPath = Join-Path $AppDir "$AppName.json"

# ============================================================ configuration
$script:cfg = [ordered]@{
    tci_host      = '127.0.0.1'
    tci_port      = 50001
    rx            = 0
    ch            = 0
    if_lsb        = 69.448470    # FI écoutée (MHz) quand le FT-2000 est en LSB
    if_usb        = 69.451390    # ... en USB
    if_cw         = 69.450000
    if_am         = 69.450000
    if_fm         = 69.450000
    if_dig        = 69.450000
    inverted      = $true        # sens du spectre (clic à droite = fréquence plus basse sur le poste)
    swap_sideband = $true        # ExpertSDR3 en LSB quand le FT-2000 est en USB, et inversement
    sync_mode     = $true        # recopier le mode du FT-2000 dans ExpertSDR3
    deadband_hz   = 20           # en dessous, ExpertSDR3 est considéré "sur la FI"
    snap_hz       = 500          # arrondi de la fréquence envoyée après un clic (0 = aucun)
    wheel_hz      = 500          # pas du FT-2000 pour un cran de molette (0 = molette traitée comme un clic)
    wheel_fast_ms = 350          # crans espacés de moins de ... ms = molette tournée vite -> pas 1 kHz
    wheel_fast_n  = 1            # ... à partir du (n+1)-ième cran rapproché
    wheel_vfast_ms = 150         # crans encore plus rapprochés -> pas 2,5 kHz
    wheel_vfast_n = 4
    recenter_ms   = 250          # délai avant de recentrer ExpertSDR3 après un clic
    backend       = 'hrd'        # 'hrd' ou 'serial'
    hrd_host      = '127.0.0.1'
    hrd_port      = 7809
    serial_port   = 'COM12'
    serial_baud   = 38400
    poll_ms       = 300          # période de lecture fréquence/mode du FT-2000
    cat_query_s   = 30           # CAT direct : si rien n'est vu sur le port depuis ... s, le programme interroge lui-même le poste
    show_log      = $false       # journal affiche (fenetre plus haute)
    scan_start    = 14000.0      # kHz
    scan_end      = 14350.0      # kHz
    scan_step_hz  = 500
    scan_wait_s   = 2
    topmost       = $false       # fenetre toujours au premier plan
    compact       = $false       # "Réduit" : cadres Panadapter et ExpertSDR3 masques
    goto_history  = @()          # 20 dernieres frequences saisies (kHz), la plus recente en premier
    was_running   = $false       # la passerelle tournait a la derniere fermeture : relancee a l'ouverture suivante
}
$j = $null
if (Test-Path $CfgPath) {
    try {
        $j = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { if ($script:cfg.Contains($p.Name)) { $script:cfg[$p.Name] = $p.Value } }
    } catch { }
}
if ($j -and $j.PSObject.Properties['tci_url'] -and $j.tci_url -match '^ws://([^:/]+):(\d+)') { $script:cfg.tci_host = $Matches[1]; $script:cfg.tci_port = [int]$Matches[2] }   # anciens reglages
if ($j -and $j.PSObject.Properties['debug'] -and -not $j.PSObject.Properties['show_log']) { $script:cfg.show_log = [bool]$j.debug }   # ancien reglage
if ($null -eq $script:cfg.goto_history) { $script:cfg.goto_history = @() } else { $script:cfg.goto_history = @($script:cfg.goto_history | ForEach-Object { [string]$_ }) }
function Get-TciUrl { return ('ws://{0}:{1}' -f $script:cfg.tci_host, $script:cfg.tci_port) }
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) ($AppName + '.lnk')
function Get-StartWithWindows { return (Test-Path $StartupLnk) }
function Set-StartWithWindows([bool]$on) {
    if ($on) {
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($StartupLnk)
        $lnk.TargetPath = Join-Path $AppDir ($AppName + '.bat')
        $lnk.WorkingDirectory = $AppDir
        $lnk.WindowStyle = 7                      # reduit
        $lnk.Description = 'PanadapterBridge — ExpertSDR3 <-> FT-2000'
        $lnk.Save()
    } elseif (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force }
}
function Save-Config { try { $script:cfg | ConvertTo-Json | Set-Content $CfgPath -Encoding UTF8 } catch { } }

# ============================================================ modes et FI
$Swap = @{ 'lsb'='usb'; 'usb'='lsb'; 'digl'='digu'; 'digu'='digl' }
$Ft2000ModeCode = @{ '1'='LSB'; '2'='USB'; '3'='CW'; '4'='FM'; '5'='AM'; '6'='RTTY'; '7'='CW-R'; '8'='PKT-L'; '9'='RTTY-R'; 'A'='PKT-FM'; 'B'='FM-N'; 'C'='PKT-U' }

function Get-ModeFamily([string]$rigMode) {
    # LSB / USB / CW / AM / FM / DIG : sert à choisir la FI et le mode ExpertSDR3
    $u = $rigMode.Trim().ToUpper()
    if (-not $u) { return '' }
    if ($u -like '*LSB*') { return 'LSB' }
    if ($u -like '*USB*') { return 'USB' }
    if ($u -like '*CW*')  { return 'CW' }
    if ($u -like '*AM*')  { return 'AM' }
    if ($u -like '*FM*')  { return 'FM' }
    if ($u -like '*RTTY*' -or $u -like '*FSK*' -or $u -like '*PKT*' -or $u -like '*DATA*' -or $u -like '*DIG*') { return 'DIG' }
    return ''
}
function Get-TciModeForRig([string]$rigMode) {
    $m = switch (Get-ModeFamily $rigMode) {
        'LSB' { 'lsb' } 'USB' { 'usb' } 'CW' { 'cw' } 'AM' { 'am' } 'FM' { 'nfm' }
        'DIG' { if ($rigMode.ToUpper() -like '*-L*') { 'digl' } else { 'digu' } }
        default { '' }
    }
    if ($m -and $script:cfg.swap_sideband -and $Swap.ContainsKey($m)) { $m = $Swap[$m] }
    return $m
}
function Get-IfHzForMode([string]$rigMode) {
    $mhz = switch (Get-ModeFamily $rigMode) {
        'LSB' { $script:cfg.if_lsb } 'USB' { $script:cfg.if_usb } 'CW' { $script:cfg.if_cw }
        'AM'  { $script:cfg.if_am }  'FM'  { $script:cfg.if_fm }  'DIG' { $script:cfg.if_dig }
        default { $script:cfg.if_usb }
    }
    return [long][Math]::Round([double]$mhz * 1e6)
}
function Format-Hz([long]$hz) {
    $s = ([string]$hz).PadLeft(7, '0')
    return ('{0}.{1}.{2} MHz' -f $s.Substring(0, $s.Length - 6), $s.Substring($s.Length - 6, 3), $s.Substring($s.Length - 3))
}

# ============================================================ état
$script:running      = $false
$script:shuttingDown = $false
$script:autoStart    = $false      # relance automatique en cours : abandonnee au premier echec de connexion      # Windows se ferme : on garde was_running pour relancer au prochain demarrage
$script:ws           = $null
$script:wsConnect    = $null
$script:wsRecv       = $null
$script:wsBuf        = New-Object byte[] 65536
$script:wsText       = New-Object System.Text.StringBuilder
$script:wsRetryAt    = [DateTime]::MinValue
$script:tcp          = $null
$script:tcpStream    = $null
$script:hrdModeArg   = ''          # argument de "get dropdown-text" qui renvoie le mode (ex. {Main Mode})
$script:serial       = $null
$script:rigOk        = $false
$script:rigRetryAt   = [DateTime]::MinValue
$script:lastPoll     = [DateTime]::MinValue
$script:rigFreq      = 0L
$script:rigMode      = ''
$script:tciMode      = ''          # mode annoncé par ExpertSDR3
$script:modeSentAt   = [DateTime]::MinValue
$script:esdrVfo      = -1L         # dernier VFO annoncé par ExpertSDR3
$script:esdrDds      = -1L         # dernier centre de panorama annoncé par ExpertSDR3
$script:lastRecenter = [DateTime]::MinValue
$script:ignoreUntil  = [DateTime]::MinValue
$script:recenterAt   = [DateTime]::MinValue
$script:ifHz         = 0L
$script:scanning     = $false
$script:scanNextAt   = [DateTime]::MinValue
$script:logHeight    = 0
$script:origTops     = $null
$script:logDay       = ''
$script:catBuf = ''; $script:catFreq = 0L; $script:catMode = ''; $script:catFreqAt = [DateTime]::MinValue; $script:catModeAt = [DateTime]::MinValue
$script:catOpenedAt = [DateTime]::MinValue; $script:catMute = $false; $script:catAskedAt = [DateTime]::MinValue
$script:hrdQueue = $null; $script:hrdBuf = New-Object byte[] 0
$script:wheelLastAt  = [DateTime]::MinValue   # acceleration molette : crans rapproches = pas plus grand
$script:wheelRun     = 0
$script:gotoBusy     = $false      # evite de re-declencher Goto-Freq pendant la mise a jour de la liste

# ============================================================ journal
$LogDir = Join-Path $AppDir 'logs'
$LogKeepDays = 2
function Purge-OldLogs {
    try {
        if (-not (Test-Path $LogDir)) { return }
        Get-ChildItem $LogDir -Filter ($AppName + '_*.log') | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogKeepDays) } | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}
function Log([string]$msg, [switch]$Debug) {
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg
    if ($script:txtLog.Lines.Count -gt 2000) { $script:txtLog.Clear() }
    $script:txtLog.AppendText($line + [Environment]::NewLine)
    # fichier journalier logs\PanadapterBridge_AAAA-MM-JJ.log (les fichiers de plus de 2 jours sont supprimes)
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
        $day = Get-Date -Format 'yyyy-MM-dd'
        if ($script:logDay -ne $day) { $script:logDay = $day; Purge-OldLogs }
        Add-Content -Path (Join-Path $LogDir ($AppName + '_' + $day + '.log')) -Value $line -Encoding UTF8
    } catch { }
}

# ============================================================ FT-2000 via HRD (serveur IP)
$HRD_MAGIC1 = [uint32]305441741    # 0x1234ABCD
$HRD_MAGIC2 = [uint32]2882343476   # 0xABCD1234 (en décimal : PowerShell lit l'hexa comme un int32 signé)
$script:lastHrdLog = @{}

function Hrd-Connect {
    $script:tcp = New-Object System.Net.Sockets.TcpClient
    $script:tcp.ReceiveTimeout = 1000; $script:tcp.SendTimeout = 1000
    $script:tcp.Connect($script:cfg.hrd_host, [int]$script:cfg.hrd_port)
    $script:tcpStream = $script:tcp.GetStream()
    $script:hrdQueue = New-Object System.Collections.Queue
    $script:hrdBuf = New-Object byte[] 0
    $script:catFreq = 0L; $script:catMode = ''; $script:catFreqAt = [DateTime]::MinValue; $script:catModeAt = [DateTime]::MinValue
    Log ('HRD : connecté à {0}:{1}' -f $script:cfg.hrd_host, $script:cfg.hrd_port)
    # a la connexion seulement, quelques questions synchrones (delai max 1 s chacune) ; si HRD ne repond
    # pas a la premiere, on abandonne tout de suite (nouvel essai plus tard) pour ne pas figer la fenetre
    Log ('HRD : radio = ' + (Hrd-Cmd 'get radio'))
    # le mode est un "dropdown" de HRD ("Main Mode" pour le FT-2000), lu par get dropdown-text {nom}
    $script:hrdModeArg = ''
    $names = @()
    try { foreach ($n in ((Hrd-Cmd 'get dropdowns') -split '[,;\r\n]')) { $n = $n.Trim(); if ($n) { $names += $n } } } catch { }
    $cands = @('Main Mode', 'Mode')
    foreach ($n in $names) { if ($n -ilike '*mode*' -and $n -inotlike '*key*' -and $n -inotlike 'sub*' -and $cands -notcontains $n) { $cands += $n } }
    foreach ($c in $cands) {
        try { if ((Hrd-Cmd ('get dropdown-text {' + $c + '}')).Trim() -like ($c + '*')) { $script:hrdModeArg = '{' + $c + '}'; break } } catch { }
    }
    if ($script:hrdModeArg) { Log ('HRD : mode lu via "get dropdown-text ' + $script:hrdModeArg + '"') }
    else { Log 'HRD : mode introuvable — il ne sera pas recopié dans ExpertSDR3' }
}
function Hrd-Close {
    try { if ($script:tcpStream) { $script:tcpStream.Dispose() } } catch { }
    try { if ($script:tcp) { $script:tcp.Close() } } catch { }
    $script:tcp = $null; $script:tcpStream = $null; $script:hrdQueue = $null
}
function Hrd-Frame([string]$text) {
    # trame : uint32 longueur_totale | 0x1234ABCD | 0xABCD1234 | 0 | texte UTF-16LE | 0x0000
    $body = [byte[]]([System.Text.Encoding]::Unicode.GetBytes($text) + [byte[]](0, 0))
    $hdr = New-Object byte[] 16
    [BitConverter]::GetBytes([uint32](16 + $body.Length)).CopyTo($hdr, 0)
    [BitConverter]::GetBytes($HRD_MAGIC1).CopyTo($hdr, 4)
    [BitConverter]::GetBytes($HRD_MAGIC2).CopyTo($hdr, 8)
    return [byte[]]($hdr + $body)
}
function Hrd-ReadExact([int]$n) {
    $buf = New-Object byte[] $n; $got = 0
    while ($got -lt $n) {
        $r = $script:tcpStream.Read($buf, $got, $n - $got)
        if ($r -le 0) { throw 'connexion fermée par HRD' }
        $got += $r
    }
    return $buf
}
function Hrd-Cmd([string]$text) {
    # question/reponse synchrone : utilisee uniquement a la connexion (file d'attente vide)
    $pkt = Hrd-Frame $text
    $script:tcpStream.Write($pkt, 0, $pkt.Length)
    $h = Hrd-ReadExact 16
    $total = [BitConverter]::ToUInt32($h, 0)
    if ([BitConverter]::ToUInt32($h, 4) -ne $HRD_MAGIC1 -or [BitConverter]::ToUInt32($h, 8) -ne $HRD_MAGIC2) { throw 'en-tête HRD inattendu' }
    $r = [System.Text.Encoding]::Unicode.GetString((Hrd-ReadExact ([int]$total - 16))).TrimEnd([char]0)
    Log ('HRD > ' + $text + '   <-- "' + $r + '"') -Debug
    return $r
}
function Hrd-Send([string]$text, [string]$kind) {
    # envoi sans attente ; la reponse sera ramassee par Hrd-Pump (les reponses arrivent dans l'ordre des questions)
    $pkt = Hrd-Frame $text
    $script:tcpStream.Write($pkt, 0, $pkt.Length)
    $script:hrdQueue.Enqueue(@{ kind = $kind; cmd = $text; at = (Get-Date) })
}
function Hrd-Pending([string]$kind) { foreach ($q in $script:hrdQueue) { if ($q.kind -eq $kind) { return $true } }; return $false }
function Hrd-Pump {
    # lit ce qui est disponible (jamais bloquant), decoupe en trames et traite les reponses attendues
    while ($script:tcpStream.DataAvailable) {
        $tmp = New-Object byte[] 4096
        $n = $script:tcpStream.Read($tmp, 0, 4096)
        if ($n -le 0) { throw 'connexion fermée par HRD' }
        $script:hrdBuf = [byte[]]($script:hrdBuf + $tmp[0..($n - 1)])
    }
    while ($script:hrdBuf.Length -ge 16) {
        $total = [BitConverter]::ToUInt32($script:hrdBuf, 0)
        if ([BitConverter]::ToUInt32($script:hrdBuf, 4) -ne $HRD_MAGIC1 -or [BitConverter]::ToUInt32($script:hrdBuf, 8) -ne $HRD_MAGIC2) { throw 'en-tête HRD inattendu' }
        if ($script:hrdBuf.Length -lt $total) { break }
        $r = [System.Text.Encoding]::Unicode.GetString($script:hrdBuf, 16, [int]$total - 16).TrimEnd([char]0)
        $script:hrdBuf = if ($script:hrdBuf.Length -gt $total) { [byte[]]$script:hrdBuf[$total..($script:hrdBuf.Length - 1)] } else { New-Object byte[] 0 }
        if ($script:hrdQueue.Count -eq 0) { continue }
        $q = $script:hrdQueue.Dequeue()
        if ($script:lastHrdLog[$q.cmd] -ne $r) { Log ('HRD > ' + $q.cmd + '   <-- "' + $r + '"') -Debug; $script:lastHrdLog[$q.cmd] = $r }
        switch ($q.kind) {
            'freq' { $d = $r -replace '[^0-9]', ''; if ($d) { $script:catFreq = [long]$d; $script:catFreqAt = Get-Date } }
            'mode' {
                # reponse attendue "Main Mode: USB" ; "Main Mode" seul = HRD n'a pas encore la valeur, on ignore
                if ($r -match '^\s*[^:]+:\s*(\S.*)$') { $script:catMode = $Matches[1].Trim(); $script:catModeAt = Get-Date }
            }
        }
    }
    # une question sans reponse depuis plus de 2 s : HRD ne repond plus
    if ($script:hrdQueue.Count -gt 0 -and ((Get-Date) - $script:hrdQueue.Peek().at).TotalSeconds -gt 2) { throw 'HRD ne répond plus' }
}

# ============================================================ FT-2000 en CAT direct (port COM)
function Serial-Open {
    $script:serial = New-Object System.IO.Ports.SerialPort($script:cfg.serial_port, [int]$script:cfg.serial_baud, 'None', 8, 'One')
    $script:serial.ReadTimeout = 50; $script:serial.WriteTimeout = 500
    $script:serial.Open()
    $script:catBuf = ''; $script:catFreq = 0L; $script:catMode = ''; $script:catFreqAt = [DateTime]::MinValue; $script:catModeAt = [DateTime]::MinValue
    $script:catOpenedAt = Get-Date; $script:catMute = $false; $script:catAskedAt = [DateTime]::MinValue
    Log ('CAT : port {0} ouvert à {1} bauds' -f $script:cfg.serial_port, $script:cfg.serial_baud)
}
function Serial-Close { try { if ($script:serial) { $script:serial.Close() } } catch { }; $script:serial = $null }
function Serial-Pump {
    # Le port peut etre partage (hub4com) : on y voit aussi les reponses du poste aux autres programmes.
    # On lit donc tout en flux (jamais bloquant), on decoupe en messages complets "...;" et on ne retient
    # que FA (frequence), MD0 (mode) et IF, d'ou qu'ils viennent. Rien n'est jete : pas de message tronque.
    $script:catBuf += $script:serial.ReadExisting()
    while (($i = $script:catBuf.IndexOf(';')) -ge 0) {
        $m = $script:catBuf.Substring(0, $i).Trim(); $script:catBuf = $script:catBuf.Substring($i + 1)
        if ($m -match '^FA(\d{8})$') { $script:catFreq = [long]$Matches[1]; $script:catFreqAt = Get-Date; Log ('CAT < ' + $m) -Debug }
        elseif ($m -match '^MD0(.)$') { $c = $Ft2000ModeCode[$Matches[1]]; if ($c) { $script:catMode = $c; $script:catModeAt = Get-Date; Log ('CAT < ' + $m) -Debug } }
        elseif ($m -match '^IF\d{3}(\d{8})[+-]\d{4}..(.)') {
            # IF : canal(3) frequence(8) clarifier(+0000) clarRX(1) clarTX(1) mode(1) ...
            $script:catFreq = [long]$Matches[1]; $script:catFreqAt = Get-Date
            $c = $Ft2000ModeCode[$Matches[2]]; if ($c) { $script:catMode = $c; $script:catModeAt = Get-Date; Log ('CAT < ' + $m) -Debug }
        }
    }
    if ($script:catBuf.Length -gt 200) { $script:catBuf = '' }   # securite : flux sans ';' (vitesse fausse ?)
    # rien vu depuis cat_query_s : on pose nous-memes la question (sans attendre), au plus une fois par cat_query_s
    $last = if ($script:catFreqAt -gt $script:catModeAt) { $script:catFreqAt } else { $script:catModeAt }
    $now = Get-Date
    if (($now - $last).TotalSeconds -gt [int]$script:cfg.cat_query_s -and ($now - $script:catAskedAt).TotalSeconds -gt [int]$script:cfg.cat_query_s) {
        $script:catAskedAt = $now
        $script:serial.Write('FA;MD0;')
        Log 'CAT > FA;MD0;' -Debug
    }
}
function Cat-Watchdog {
    # liaison muette (rien vu, meme apres notre propre question) : voyant noir + une ligne de journal
    $last = if ($script:catFreqAt -gt $script:catModeAt) { $script:catFreqAt } else { $script:catModeAt }
    $mute = ($script:catOpenedAt -ne [DateTime]::MinValue) -and (((Get-Date) - $last).TotalSeconds -gt ([int]$script:cfg.cat_query_s + 2)) -and (((Get-Date) - $script:catOpenedAt).TotalSeconds -gt 5)
    if ($mute -and -not $script:catMute) {
        $script:catMute = $true
        Set-Led $script:ledRig 'mute'
        Log 'ALERTE : liaison CAT muette (port ouvert mais aucune réponse du FT-2000) — vérifier le Bluetooth / PartageCOM'
    } elseif (-not $mute -and $script:catMute) {
        $script:catMute = $false
        Set-Led $script:ledRig $true
        Log 'Liaison CAT rétablie'
    }
}

# ============================================================ FT-2000 : lecture / QSY (jamais bloquant)
function Rig-Open  { if ($script:cfg.backend -eq 'serial') { Serial-Open } else { Hrd-Connect } }
function Rig-Close { Hrd-Close; Serial-Close }
function Rig-GetFreq {
    if ($script:cfg.backend -eq 'serial') { Serial-Pump; return $script:catFreq }
    Hrd-Pump
    if (-not (Hrd-Pending 'freq')) { Hrd-Send 'get frequency' 'freq' }
    return $script:catFreq
}
function Rig-GetMode {
    if ($script:cfg.backend -eq 'serial') { Serial-Pump; Cat-Watchdog; return $script:catMode }
    Hrd-Pump
    if ($script:hrdModeArg -and -not (Hrd-Pending 'mode')) { Hrd-Send ('get dropdown-text ' + $script:hrdModeArg) 'mode' }
    return $script:catMode
}
function Rig-SetFreq([long]$hz) {
    if ($script:cfg.backend -eq 'serial') { $script:serial.Write(('FA{0:D8};' -f $hz)) }
    else { Hrd-Send ('set frequency-hz {0}' -f $hz) 'set' }
    $script:catFreq = $hz; $script:catFreqAt = Get-Date
}

# ============================================================ ExpertSDR3 via TCI (WebSocket)
function Tci-Send([string]$msg) {
    if (-not $script:ws -or $script:ws.State -ne 'Open') { return }
    Log ('TCI > ' + $msg) -Debug
    $seg = [System.ArraySegment[byte]]::new([System.Text.Encoding]::UTF8.GetBytes($msg))
    $script:ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait(2000) | Out-Null
}
function Tci-Recenter {
    $script:ignoreUntil = (Get-Date).AddMilliseconds(150)
    $script:lastRecenter = Get-Date
    Tci-Send ('dds:{0},{1};' -f $script:cfg.rx, $script:ifHz)
    Tci-Send ('vfo:{0},{1},{2};' -f $script:cfg.rx, $script:cfg.ch, $script:ifHz)
}
function Tci-PushMode {
    if (-not $script:cfg.sync_mode) { return }
    if (-not $script:ws -or $script:ws.State -ne 'Open') { return }
    $m = Get-TciModeForRig $script:rigMode
    if ($m -and $m -ne $script:tciMode) {
        Tci-Send ('modulation:{0},{1};' -f $script:cfg.rx, $m)
        $script:modeSentAt = Get-Date
        Log ('Mode FT-2000 {0} -> ExpertSDR3 {1}' -f $script:rigMode, $m.ToUpper())
        # ExpertSDR3 ne renvoie "modulation:" que si le mode change reellement : si on ne connait pas encore
        # son mode, on considere la commande appliquee (un eventuel echo contraire corrigera)
        if (-not $script:tciMode) { $script:tciMode = $m }
    }
}
function Tci-StartReceive {
    $script:wsRecv = $script:ws.ReceiveAsync([System.ArraySegment[byte]]::new($script:wsBuf), [System.Threading.CancellationToken]::None)
}
function Tci-Close {
    try { if ($script:ws) { $script:ws.Dispose() } } catch { }
    $script:ws = $null; $script:wsConnect = $null; $script:wsRecv = $null
    [void]$script:wsText.Clear()
    Set-Led $script:ledTci $false
}
function Update-If {
    # la FI dépend du mode du FT-2000 ; quand elle change, ExpertSDR3 est recalé dessus
    $new = Get-IfHzForMode $script:rigMode
    if ($new -ne $script:ifHz) {
        $script:ifHz = $new
        $script:lblIf.Text = 'FI : ' + (Format-Hz $new)
        Log ('FI pour le mode {0} : {1}' -f $script:rigMode, (Format-Hz $new))
        $script:recenterAt = [DateTime]::MinValue
        Tci-Recenter
    }
}
function Tci-OnMessage([string]$msg) {
    foreach ($part in $msg.Split(';')) {
        $p = $part.Trim()
        if (-not $p) { continue }
        Log ('TCI < ' + $p) -Debug
        if ($p -eq 'ready') {
            Tci-Recenter
            Tci-PushMode
        } elseif ($p.StartsWith('modulation:')) {
            $f = $p.Substring(11).Split(',')
            if ($f.Length -eq 2 -and [int]$f[0] -eq [int]$script:cfg.rx) { $script:tciMode = $f[1].Trim().ToLower() }
        } elseif ($p.StartsWith('vfo:')) {
            $f = $p.Substring(4).Split(',')
            if ($f.Length -ne 3) { continue }
            try { $rx = [int]$f[0]; $ch = [int]$f[1]; $hz = [long][double]$f[2] } catch { continue }
            if ($rx -eq [int]$script:cfg.rx -and $ch -eq [int]$script:cfg.ch) { $script:esdrVfo = $hz; On-Vfo $hz }
        } elseif ($p.StartsWith('dds:')) {
            $f = $p.Substring(4).Split(',')
            if ($f.Length -eq 2) { try { if ([int]$f[0] -eq [int]$script:cfg.rx) { $script:esdrDds = [long][double]$f[1] } } catch { } }
        }
    }
}

# ============================================================ clic / molette -> QSY
function On-Vfo([long]$hz) {
    $delta = $hz - $script:ifHz
    if ([Math]::Abs($delta) -le [int]$script:cfg.deadband_hz) { return }
    if ((Get-Date) -lt $script:ignoreUntil) { return }
    if ($script:recenterAt -ne [DateTime]::MinValue) { return }     # QSY déjà en cours
    if (-not $script:rigOk -or $script:rigFreq -eq 0) {
        Log 'Clic ignoré : FT-2000 non connecté'
        Tci-Recenter
        return
    }
    Stop-Scan 'clic dans ExpertSDR3'
    $rfDelta = if ($script:cfg.inverted) { -$delta } else { $delta }
    $wheel = [long]$script:cfg.wheel_hz
    $snap  = [long]$script:cfg.snap_hz
    $isWheel = ($wheel -gt 0 -and [Math]::Abs($delta) -lt $wheel)
    if ($isWheel) {
        # un cran de molette : un pas sur la grille, dans le sens du cran.
        # Molette tournee vite (crans rapproches, seuils reglables dans le .json) : pas 1 kHz, puis 2,5 kHz si tres vite ;
        # des que la molette s'arrete, on revient au pas regle.
        $now = Get-Date
        $gap = ($now - $script:wheelLastAt).TotalMilliseconds
        if ($gap -lt [int]$script:cfg.wheel_fast_ms) { $script:wheelRun++ } else { $script:wheelRun = 0 }
        $script:wheelLastAt = $now
        $step = $wheel
        if ($wheel -lt 1000) {
            if ($script:wheelRun -ge [int]$script:cfg.wheel_vfast_n -and $gap -lt [int]$script:cfg.wheel_vfast_ms) { $step = 2500 }
            elseif ($script:wheelRun -ge [int]$script:cfg.wheel_fast_n) { $step = 1000 }
        }
        $sign = if ($rfDelta -ge 0) { 1 } else { -1 }
        $base = [long]([Math]::Round([double]$script:rigFreq / $step, [System.MidpointRounding]::AwayFromZero) * $step)
        $target = $base + $sign * $step
        Log ('Molette {0}{1} Hz{2} -> FT-2000 {3}' -f $(if ($sign -gt 0) { '+' } else { '-' }), $step, $(if ($step -ne $wheel) { ' (rapide)' } else { '' }), (Format-Hz $target))
    } else {
        $target = $script:rigFreq + $rfDelta
        if ($snap -gt 0) { $target = [long]([Math]::Round([double]$target / $snap, [System.MidpointRounding]::AwayFromZero) * $snap) }
        Log ('Clic {0}{1} Hz -> FT-2000 {2} -> {3}' -f $(if ($delta -ge 0) { '+' } else { '' }), $delta, (Format-Hz $script:rigFreq), (Format-Hz $target))
    }
    try {
        Rig-SetFreq $target
        $script:rigFreq = $target
        $script:lblFreq.Text = Format-Hz $target
        $script:status.Text = 'QSY envoyé ' + (Get-Date -Format 'HH:mm:ss')
        if ($isWheel) { Tci-Recenter } else { $script:recenterAt = (Get-Date).AddMilliseconds([int]$script:cfg.recenter_ms) }
    } catch {
        Log ('Échec QSY : ' + $_.Exception.Message)
        Tci-Recenter
    }
}

# ============================================================ scan
function Read-ScanForm {
    try {
        $script:cfg.scan_start = [double]($script:txtScanStart.Text.Trim().Replace(',', '.'))
        $script:cfg.scan_end   = [double]($script:txtScanEnd.Text.Trim().Replace(',', '.'))
    } catch { Log 'ALERTE : fréquences de scan invalides (en kHz, ex. 14000 ou 14074.5)'; return $false }
    $script:cfg.scan_step_hz = if ($script:cmbScanStep.SelectedItem -eq '1 kHz') { 1000 } else { 500 }
    $script:cfg.scan_wait_s  = [int]($script:cmbScanWait.SelectedItem -replace '\D', '')
    if ($script:cfg.scan_end -eq $script:cfg.scan_start) { Log 'ALERTE : les fréquences de début et de fin de scan sont identiques'; return $false }
    Save-Config
    return $true
}
function Start-Scan {
    if (-not $script:running -or -not $script:rigOk) { Log 'Scan impossible : FT-2000 non connecté'; return }
    if (-not (Read-ScanForm)) { return }
    $script:scanning = $true
    $script:btnScan.Text = 'Arrêter le scan'
    foreach ($c in @($script:txtScanStart, $script:txtScanEnd, $script:cmbScanStep, $script:cmbScanWait)) { $c.Enabled = $false }
    Log ('Scan de {0} à {1} kHz ({2}), pas {3} Hz, {4} s par pas' -f $script:cfg.scan_start, $script:cfg.scan_end, $(if ($script:cfg.scan_end -gt $script:cfg.scan_start) { 'montant' } else { 'descendant' }), $script:cfg.scan_step_hz, $script:cfg.scan_wait_s)
    Scan-GoTo ([long][Math]::Round($script:cfg.scan_start * 1000))
}
function Stop-Scan([string]$why) {
    if (-not $script:scanning) { return }
    $script:scanning = $false
    $script:btnScan.Text = 'Lancer le scan'
    foreach ($c in @($script:txtScanStart, $script:txtScanEnd, $script:cmbScanStep, $script:cmbScanWait)) { $c.Enabled = $true }
    Log ('Scan arrêté' + $(if ($why) { ' (' + $why + ')' } else { '' }))
}
function Scan-GoTo([long]$hz) {
    try {
        Rig-SetFreq $hz
        $script:rigFreq = $hz
        $script:lblFreq.Text = Format-Hz $hz
        $script:scanNextAt = (Get-Date).AddSeconds([int]$script:cfg.scan_wait_s)
    } catch { Stop-Scan ('échec QSY : ' + $_.Exception.Message) }
}
function Scan-Step {
    if (-not $script:scanning -or (Get-Date) -lt $script:scanNextAt) { return }
    if (-not $script:rigOk) { Stop-Scan 'FT-2000 déconnecté'; return }
    $start = [long][Math]::Round($script:cfg.scan_start * 1000); $end = [long][Math]::Round($script:cfg.scan_end * 1000)
    if ($end -gt $start) {
        $next = $script:rigFreq + [long]$script:cfg.scan_step_hz
        if ($next -gt $end) { $next = $start }          # limite haute atteinte : on repart du début
    } else {
        $next = $script:rigFreq - [long]$script:cfg.scan_step_hz
        if ($next -lt $end) { $next = $start }          # limite basse atteinte : on repart du début
    }
    Scan-GoTo $next
}
function Add-GotoHistory([long]$hz) {
    $key = ($hz / 1000.0).ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
    $hist = @($key) + @($script:cfg.goto_history | Where-Object { $_ -ne $key })
    if ($hist.Count -gt 20) { $hist = $hist[0..19] }
    $script:cfg.goto_history = $hist; Save-Config
    $script:gotoBusy = $true
    $script:cmbGoto.Items.Clear(); [void]$script:cmbGoto.Items.AddRange([string[]]$hist)
    $script:cmbGoto.Text = $key
    $script:gotoBusy = $false
    return $key
}
function Remove-GotoHistory([string]$key) {
    $hist = @($script:cfg.goto_history | Where-Object { $_ -ne $key })
    $script:cfg.goto_history = $hist; Save-Config
    $script:gotoBusy = $true
    $script:cmbGoto.Items.Clear(); [void]$script:cmbGoto.Items.AddRange([string[]]$hist)
    if ($script:cmbGoto.Text -eq $key) { $script:cmbGoto.Text = '' }
    $script:gotoBusy = $false
    Log ('Fréquence retirée de la liste : ' + $key + ' kHz')
}
function Save-CurrentFreq {
    if (-not $script:rigOk -or $script:rigFreq -eq 0) { Log 'Mémorisation impossible : fréquence du FT-2000 inconnue'; return }
    $k = Add-GotoHistory $script:rigFreq
    Log ('Fréquence mémorisée : ' + $k + ' kHz')
}
function Goto-Freq([string]$value) {
    # saisie ou selection d'une frequence (kHz) pour le FT-2000 ; historique des 20 dernieres
    if (-not $script:running -or -not $script:rigOk) { Log 'QSY impossible : FT-2000 non connecté'; return }
    if (-not $value) { $value = $script:cmbGoto.Text }
    $txt = $value.Trim().Replace(',', '.')
    if (-not $txt) { return }
    try { $khz = [double]$txt } catch { Log 'ALERTE : fréquence invalide (en kHz, ex. 14074.5)'; return }
    $hz = [long][Math]::Round($khz * 1000)
    if ($hz -lt 30000 -or $hz -gt 60000000) { Log 'ALERTE : fréquence hors limites du FT-2000'; return }
    Stop-Scan 'saisie manuelle'
    try {
        Rig-SetFreq $hz
        $script:rigFreq = $hz
        $script:lblFreq.Text = Format-Hz $hz
        Log ('QSY manuel -> ' + (Format-Hz $hz))
        [void](Add-GotoHistory $hz); $script:cmbGoto.SelectAll()
    } catch { Log ('Échec QSY : ' + $_.Exception.Message) }
}

# ============================================================ boucle principale (timer 100 ms)
function Abort-AutoStart([string]$why) {
    Log ('ALERTE : relance automatique annulée — ' + $why)
    Log 'Corrigez le problème puis cliquez sur Démarrer.'
    Stop-Bridge
    $script:status.Text = 'Relance automatique annulée : ' + $why
}
function Step {
    if (-not $script:running) { return }
    $now = Get-Date

    Scan-Step

    # recentrage différé après un clic
    if ($script:recenterAt -ne [DateTime]::MinValue -and $now -ge $script:recenterAt) {
        $script:recenterAt = [DateTime]::MinValue
        Tci-Recenter
    }

    # chien de garde : ExpertSDR3 doit rester calé sur la FI
    if ($script:ws -and $script:ws.State -eq 'Open' -and $script:recenterAt -eq [DateTime]::MinValue -and $now -ge $script:ignoreUntil -and ($now - $script:lastRecenter).TotalMilliseconds -ge 200) {
        $off = ($script:esdrVfo -ge 0 -and [Math]::Abs($script:esdrVfo - $script:ifHz) -gt [int]$script:cfg.deadband_hz) -or
               ($script:esdrDds -ge 0 -and [Math]::Abs($script:esdrDds - $script:ifHz) -gt [int]$script:cfg.deadband_hz)
        if ($off) { Log 'Recalage d''ExpertSDR3 sur la FI' -Debug; Tci-Recenter }
    }

    # FT-2000 : connexion et lecture périodique
    if (-not $script:rigOk -and $now -ge $script:rigRetryAt) {
        try { Rig-Open; $script:rigOk = $true; Set-Led $script:ledRig $true; if ($script:ws -and $script:ws.State -eq 'Open') { $script:autoStart = $false } }
        catch {
            Rig-Close
            if ($script:autoStart) { Abort-AutoStart ('FT-2000 injoignable (' + $_.Exception.Message + ')'); return }
            Log ('FT-2000 injoignable (' + $_.Exception.Message + ') — nouvel essai dans 2 s')
            $script:rigRetryAt = $now.AddSeconds(2)
        }
    }
    if ($script:rigOk -and ($now - $script:lastPoll).TotalMilliseconds -ge [int]$script:cfg.poll_ms) {
        $script:lastPoll = $now
        try {
            $f = Rig-GetFreq
            $m = Rig-GetMode
            if ($f -and $f -ne $script:rigFreq) { $script:rigFreq = $f; $script:lblFreq.Text = Format-Hz $f; Log ('FT-2000 : ' + (Format-Hz $f)) }
            if ($m -and $m -ne $script:rigMode) { $script:rigMode = $m; $script:lblMode.Text = $m; Log ('FT-2000 : mode ' + $m); Update-If; Tci-PushMode }
            elseif ($script:rigMode -and ($now - $script:modeSentAt).TotalSeconds -ge 2) { Tci-PushMode }   # renvoi tant qu'ExpertSDR3 n'a pas suivi
        } catch {
            Log ('FT-2000 : lecture impossible (' + $_.Exception.Message + ') — reconnexion dans 2 s')
            Rig-Close; $script:rigOk = $false; Set-Led $script:ledRig $false; $script:rigRetryAt = $now.AddSeconds(2)
        }
    }

    # ExpertSDR3 : connexion et lecture des messages
    if (-not $script:ws) {
        if ($now -ge $script:wsRetryAt) {
            try {
                $script:ws = New-Object System.Net.WebSockets.ClientWebSocket
                $script:wsConnect = $script:ws.ConnectAsync([Uri](Get-TciUrl), [System.Threading.CancellationToken]::None)
            } catch { Log ('TCI : ' + $_.Exception.Message); Tci-Close; $script:wsRetryAt = $now.AddSeconds(3) }
        }
        return
    }
    if ($script:wsConnect) {
        if (-not $script:wsConnect.IsCompleted) { return }
        if ($script:wsConnect.IsFaulted) {
            Tci-Close
            if ($script:autoStart) { Abort-AutoStart ('ExpertSDR3 injoignable sur ' + (Get-TciUrl)); return }
            Log ('ExpertSDR3 injoignable (' + (Get-TciUrl) + ') — nouvel essai dans 3 s')
            $script:wsRetryAt = $now.AddSeconds(3); return
        }
        $script:wsConnect = $null
        Set-Led $script:ledTci $true
        Log ('TCI : connecté à ' + (Get-TciUrl))
        Tci-StartReceive
        if ($script:rigOk) { $script:autoStart = $false }
    }
    $n = 0
    while ($script:wsRecv -and $script:wsRecv.IsCompleted -and $n -lt 50) {
        $n++
        if ($script:wsRecv.IsFaulted -or $script:ws.State -ne 'Open') {
            Log 'TCI : connexion perdue — nouvel essai dans 3 s'
            Tci-Close; $script:wsRetryAt = $now.AddSeconds(3); return
        }
        $r = $script:wsRecv.Result
        if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            Log 'TCI : fermé par ExpertSDR3 — nouvel essai dans 3 s'
            Tci-Close; $script:wsRetryAt = $now.AddSeconds(3); return
        }
        if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
            [void]$script:wsText.Append([System.Text.Encoding]::UTF8.GetString($script:wsBuf, 0, $r.Count))
            if ($r.EndOfMessage) {
                $msg = $script:wsText.ToString(); [void]$script:wsText.Clear()
                try { Tci-OnMessage $msg } catch { Log ('Erreur traitement TCI : ' + $_.Exception.Message) }
            }
        }
        Tci-StartReceive
    }
}

# ============================================================ démarrage / arrêt
function Read-Form {
    try {
        $ifVals = @{}
        foreach ($k in @('lsb','usb','cw','am','fm','dig')) { $ifVals[$k] = [double]($script:txtIfs[$k].Text.Trim().Replace(',', '.')) }
        $tciPort = [int]$script:cmbTciPort.Text.Trim()
        $hrdPort = [int]$script:cmbHrdPort.Text.Trim()
        $baud = [int]$script:cmbBaud.SelectedItem
        $snap = [int]$script:cmbSnap.SelectedItem
    } catch {
        [System.Windows.Forms.MessageBox]::Show('Vérifiez les valeurs numériques (FI par mode, arrondi, port, bauds).', $AppName, 'OK', 'Error') | Out-Null
        return $false
    }
    $script:cfg.tci_host      = $script:cmbTciHost.Text.Trim(); if (-not $script:cfg.tci_host) { $script:cfg.tci_host = '127.0.0.1' }
    $script:cfg.tci_port      = $tciPort
    $script:cfg.if_lsb = $ifVals['lsb']; $script:cfg.if_usb = $ifVals['usb']; $script:cfg.if_cw = $ifVals['cw']
    $script:cfg.if_am  = $ifVals['am'];  $script:cfg.if_fm  = $ifVals['fm'];  $script:cfg.if_dig = $ifVals['dig']
    $script:cfg.inverted      = $script:chkInv.Checked
    $script:cfg.sync_mode     = $script:chkSync.Checked
    $script:cfg.swap_sideband = $script:chkSwap.Checked
    $script:cfg.snap_hz       = $snap
    $script:cfg.wheel_hz      = [int]$script:cmbWheel.SelectedItem
    $script:cfg.backend       = if ($script:rbSerial.Checked) { 'serial' } else { 'hrd' }
    $script:cfg.hrd_host      = $script:cmbHrdHost.Text.Trim(); if (-not $script:cfg.hrd_host) { $script:cfg.hrd_host = '127.0.0.1' }
    $script:cfg.hrd_port      = $hrdPort
    $script:cfg.serial_port   = $script:cmbCom.Text.Trim()
    $script:cfg.serial_baud   = $baud
    Save-Config
    return $true
}
function Start-Bridge {
    if ($script:running) { return }
    if (-not (Read-Form)) { return }
    $script:ifHz = Get-IfHzForMode ''
    $script:lblIf.Text = 'FI : ' + (Format-Hz $script:ifHz)
    $script:rigFreq = 0; $script:rigMode = ''; $script:tciMode = ''; $script:esdrVfo = -1; $script:esdrDds = -1
    $script:rigRetryAt = [DateTime]::MinValue; $script:wsRetryAt = [DateTime]::MinValue; $script:recenterAt = [DateTime]::MinValue
    Log ('{0} {1} — FI LSB {2}, USB {3}, spectre {4}' -f $AppName, $Version, (Format-Hz (Get-IfHzForMode 'LSB')), (Format-Hz (Get-IfHzForMode 'USB')), $(if ($script:cfg.inverted) { 'inversé' } else { 'normal' }))
    $script:running = $true
    if (-not $script:autoStart) { $script:cfg.was_running = $true; Save-Config }
    $script:btnStart.Enabled = $false; $script:btnStop.Enabled = $true
    $script:status.Text = 'En marche — la croix réduit la fenêtre ; pour quitter : Arrêter, puis la croix'
    Set-Form-Locked $true
    $script:btnScan.Enabled = $true; $script:cmbGoto.Enabled = $true; $script:btnSave.Enabled = $true
}
function Stop-Bridge {
    if (-not $script:running) { return }
    Stop-Scan
    $script:running = $false
    $script:autoStart = $false
    if (-not $script:shuttingDown) { $script:cfg.was_running = $false; Save-Config }
    Tci-Close; Rig-Close; $script:rigOk = $false
    Set-Led $script:ledRig $false; Set-Led $script:ledTci $false
    $script:btnStart.Enabled = $true; $script:btnStop.Enabled = $false
    $script:status.Text = 'Arrêté'
    Set-Form-Locked $false
    $script:btnScan.Enabled = $false; $script:cmbGoto.Enabled = $false; $script:btnSave.Enabled = $false
    Log 'Passerelle arrêtée.'
}

# ============================================================ interface
function New-Label($text, $x, $y) { $l = New-Object System.Windows.Forms.Label; $l.Text = $text; $l.Location = "$x,$y"; $l.AutoSize = $true; return $l }
function New-Text($text, $x, $y, $w) { $t = New-Object System.Windows.Forms.TextBox; $t.Text = $text; $t.Location = "$x,$y"; $t.Width = $w; return $t }
function New-Combo($items, $value, $x, $y, $w, $editable) {
    $c = New-Object System.Windows.Forms.ComboBox; $c.Location = "$x,$y"; $c.Width = $w
    $c.DropDownStyle = if ($editable) { 'DropDown' } else { 'DropDownList' }
    [void]$c.Items.AddRange([string[]]$items)
    $v = [string]$value
    if ($c.Items.Contains($v)) { $c.SelectedItem = $v } elseif ($editable) { $c.Text = $v } else { $c.SelectedIndex = 0 }
    return $c
}
function Get-AllPorts { return @([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object { [int]($_ -replace '\D', '') }) }
function Get-FreePorts {
    # ports COM presents sur la machine et non occupes par un autre programme (test par ouverture : peut prendre
    # quelques secondes sur un port Bluetooth, d'ou un bouton dedie plutot qu'un test a l'ouverture de la liste)
    $free = @()
    foreach ($n in (Get-AllPorts)) {
        try { $sp = New-Object System.IO.Ports.SerialPort($n); $sp.Open(); $sp.Close(); $sp.Dispose(); $free += $n } catch { }
    }
    return $free
}
function Refresh-ComList([switch]$TestFree) {
    $cur = $script:cmbCom.Text
    $ports = if ($TestFree) { Get-FreePorts } else { Get-AllPorts }
    if ($cur -and $ports -notcontains $cur) { $ports = @($cur) + $ports }
    $script:cmbCom.Items.Clear(); [void]$script:cmbCom.Items.AddRange([string[]]$ports)
    if ($script:cmbCom.Items.Contains($cur)) { $script:cmbCom.SelectedItem = $cur } elseif ($script:cmbCom.Items.Count -gt 0) { $script:cmbCom.SelectedIndex = 0 }
    if ($TestFree) { Log ('Ports COM libres : ' + $(if ($ports.Count) { $ports -join ', ' } else { 'aucun' })) }
}
function New-Check($text, $x, $y, $checked) { $c = New-Object System.Windows.Forms.CheckBox; $c.Text = $text; $c.Location = "$x,$y"; $c.AutoSize = $true; $c.Checked = [bool]$checked; return $c }
function New-Led($parent, $text, $x, $y) {
    $p = New-Object System.Windows.Forms.Panel; $p.Location = "$x,$($y+4)"; $p.Size = '12,12'; $p.BackColor = [System.Drawing.Color]::Silver; $p.BorderStyle = 'FixedSingle'
    $parent.Controls.AddRange(@($p, (New-Label $text ($x + 16) $y)))
    return $p
}
function Set-Led($led, $on) {
    # $on : $true (vert), $false (gris) ou 'mute' (noir). Comparaison en texte : en PowerShell, $true -eq 'mute' serait vrai !
    $led.BackColor = if (($on -is [string]) -and $on -eq 'mute') { [System.Drawing.Color]::Black } elseif ([bool]$on) { [System.Drawing.Color]::LimeGreen } else { [System.Drawing.Color]::Silver }
}
function Set-Form-Locked($locked) {
    foreach ($c in @($script:chkInv, $script:chkSync, $script:chkSwap, $script:cmbSnap, $script:cmbWheel, $script:cmbTciHost, $script:cmbTciPort, $script:rbHrd, $script:rbSerial, $script:cmbHrdHost, $script:cmbHrdPort, $script:cmbCom, $script:cmbBaud, $script:btnComRefresh, $script:btnPermute)) { $c.Enabled = -not $locked }
    foreach ($c in $script:txtIfs.Values) { $c.Enabled = -not $locked }
    if (-not $locked) { Refresh-Backend }
}
function Apply-LogVisibility {
    # Reagence la fenetre : "Reduit" masque les cadres Panadapter et ExpertSDR3 (tout remonte d'autant),
    # "Journal" affiche ou non le journal. La largeur n'est jamais modifiee ; les hauteurs sont lues sur
    # les controles deja mis a l'echelle par Windows, donc correctes quelle que soit l'echelle d'affichage.
    $show = $script:chkDebug.Checked
    $compact = $script:chkCompact.Checked
    if (-not $script:logHeight) { $script:logHeight = $script:txtLog.Height }
    $movable = @($g3, $g4, $script:btnStart, $script:btnStop, $script:chkDebug, $script:chkAuto, $script:chkTop, $script:chkCompact, $btnClear, $script:txtLog)
    if (-not $script:origTops) { $script:origTops = @{}; foreach ($c in $movable) { $script:origTops[$c.GetHashCode()] = $c.Top } }
    $shift = if ($compact) { $g3.Top - $g1.Top } else { 0 }
    $script:txtLog.Visible = $show; $btnClear.Visible = $show
    $g1.Visible = -not $compact; $g2.Visible = -not $compact
    $shift = if ($compact) { $script:origTops[$g3.GetHashCode()] - $g1.Top } else { 0 }
    foreach ($c in $movable) { $c.Top = $script:origTops[$c.GetHashCode()] - $shift }
    $marge = $script:btnStart.Top - $g4.Bottom                     # espace standard entre deux blocs (deja a l'echelle)
    $h = if ($show) { $script:txtLog.Top + $script:logHeight } else { $script:btnStart.Bottom }
    $h += $marge + $statusStrip.Height
    $w = $form.Width
    $form.MaximumSize = New-Object System.Drawing.Size(0, 0)
    $form.MinimumSize = New-Object System.Drawing.Size(0, 0)
    $form.ClientSize = New-Object System.Drawing.Size($form.ClientSize.Width, $h)
    $form.Width = $w
    if ($show) { $script:txtLog.Height = $script:logHeight }
    $form.MinimumSize = New-Object System.Drawing.Size($w, $form.Height)
    if (-not $show) { $form.MaximumSize = New-Object System.Drawing.Size(9999, $form.Height) }
}
function Refresh-Backend {
    $hrd = $script:rbHrd.Checked
    $script:cmbHrdHost.Enabled = $hrd; $script:cmbHrdPort.Enabled = $hrd
    $script:cmbCom.Enabled = -not $hrd; $script:cmbBaud.Enabled = -not $hrd; $script:btnComRefresh.Enabled = -not $hrd
}

$form = New-Object System.Windows.Forms.Form
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.AutoScaleMode = 'Dpi'
$form.Text = "$AppName $Version @F5PBG 2026 - ExpertSDR3 <-> FT-2000"
$form.Size = '660,700'
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# --- Panadapter
$g1 = New-Object System.Windows.Forms.GroupBox; $g1.Text = 'Panadapter'; $g1.Location = '10,8'; $g1.Size = '625,176'; $g1.Anchor = 'Top,Left,Right'
$g1.Controls.Add((New-Label 'FI écoutée (MHz) selon le mode du FT-2000 :' 12 22))
$script:btnPermute = New-Object System.Windows.Forms.Button; $script:btnPermute.Text = 'Permuter LSB/USB'; $script:btnPermute.Location = '270,19'; $script:btnPermute.Size = '115,24'
$script:btnPermute.add_Click({ $a = $script:txtIfs['lsb'].Text; $script:txtIfs['lsb'].Text = $script:txtIfs['usb'].Text; $script:txtIfs['usb'].Text = $a })
$script:lblIf = New-Label 'FI : —' 400 22; $script:lblIf.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)
$g1.Controls.AddRange(@($script:btnPermute, $script:lblIf))
$script:txtIfs = @{}
$ifDefs = @(@('lsb','FT-2000 en LSB',$script:cfg.if_lsb), @('usb','FT-2000 en USB',$script:cfg.if_usb), @('cw','FT-2000 en CW',$script:cfg.if_cw),
            @('am','FT-2000 en AM',$script:cfg.if_am),    @('fm','FT-2000 en FM',$script:cfg.if_fm),    @('dig','FT-2000 en DIG',$script:cfg.if_dig))
$i = 0
foreach ($d in $ifDefs) {
    $x = 12 + ($i % 3) * 205; $y = 50 + [Math]::Floor($i / 3) * 28
    $g1.Controls.Add((New-Label $d[1] $x $y))
    $t = New-Text (([double]$d[2]).ToString('0.000000', [System.Globalization.CultureInfo]::InvariantCulture)) ($x + 98) ($y - 3) 82
    $script:txtIfs[$d[0]] = $t; $g1.Controls.Add($t)
    $i++
}
$script:chkInv  = New-Check 'Spectre inversé' 12 112 $script:cfg.inverted
$script:chkSync = New-Check 'Mode FT-2000 -> ExpertSDR3' 150 112 $script:cfg.sync_mode
$script:chkSwap = New-Check 'Échanger LSB/USB' 360 112 $script:cfg.swap_sideband
$g1.Controls.Add((New-Label 'Molette : un cran = (Hz)' 12 144))
$script:cmbWheel = New-Object System.Windows.Forms.ComboBox; $script:cmbWheel.Location = '165,141'; $script:cmbWheel.Width = 70; $script:cmbWheel.DropDownStyle = 'DropDownList'
[void]$script:cmbWheel.Items.AddRange(@('0', '100', '200', '300', '400', '500', '1000'))
$script:cmbWheel.SelectedItem = [string]$script:cfg.wheel_hz; if ($script:cmbWheel.SelectedIndex -lt 0) { $script:cmbWheel.SelectedItem = '500' }
$g1.Controls.Add((New-Label 'Clic : arrondir à (Hz)' 270 144))
$script:cmbSnap = New-Combo @('0','100','200','300','400','500') $script:cfg.snap_hz 410 141 70 $false
$g1.Controls.AddRange(@($script:chkInv, $script:chkSync, $script:chkSwap, $script:cmbWheel, $script:cmbSnap))

# --- ExpertSDR3
$g2 = New-Object System.Windows.Forms.GroupBox; $g2.Text = 'ExpertSDR3 (TCI)'; $g2.Location = '10,190'; $g2.Size = '625,56'; $g2.Anchor = 'Top,Left,Right'
$g2.Controls.Add((New-Label 'TCI : ws://' 12 24))
$script:cmbTciHost = New-Combo @('127.0.0.1','localhost') $script:cfg.tci_host 85 21 120 $true
$g2.Controls.Add((New-Label ':' 208 24))
$script:cmbTciPort = New-Combo @('50001','40001','50002','50003') $script:cfg.tci_port 218 21 75 $true
$g2.Controls.AddRange(@($script:cmbTciHost, $script:cmbTciPort))
$script:ledTci = New-Led $g2 'ExpertSDR3' 340 24

# --- FT-2000
$g3 = New-Object System.Windows.Forms.GroupBox; $g3.Text = 'FT-2000'; $g3.Location = '10,252'; $g3.Size = '625,110'; $g3.Anchor = 'Top,Left,Right'
$script:rbHrd = New-Object System.Windows.Forms.RadioButton; $script:rbHrd.Text = 'Via Ham Radio Deluxe (serveur IP)'; $script:rbHrd.Location = '12,20'; $script:rbHrd.AutoSize = $true
$script:rbSerial = New-Object System.Windows.Forms.RadioButton; $script:rbSerial.Text = 'CAT direct sur un port COM'; $script:rbSerial.Location = '260,20'; $script:rbSerial.AutoSize = $true
if ($script:cfg.backend -eq 'serial') { $script:rbSerial.Checked = $true } else { $script:rbHrd.Checked = $true }
$g3.Controls.Add((New-Label 'Hôte HRD' 12 48)); $script:cmbHrdHost = New-Combo @('127.0.0.1','localhost') $script:cfg.hrd_host 85 45 100 $true
$g3.Controls.Add((New-Label 'Port' 195 48));     $script:cmbHrdPort = New-Combo @('7809') $script:cfg.hrd_port 245 45 70 $true
$g3.Controls.Add((New-Label 'Port COM' 12 76));  $script:cmbCom = New-Combo @(@($script:cfg.serial_port) + (Get-AllPorts) | Select-Object -Unique) $script:cfg.serial_port 85 73 72 $false
$script:btnComRefresh = New-Object System.Windows.Forms.Button; $script:btnComRefresh.Text = [string][char]0x21BB; $script:btnComRefresh.Location = '160,72'; $script:btnComRefresh.Size = '25,24'
$script:btnComRefresh.add_Click({ $script:btnComRefresh.Enabled = $false; try { Refresh-ComList -TestFree } finally { $script:btnComRefresh.Enabled = $true } })
$script:tip = New-Object System.Windows.Forms.ToolTip; $script:tip.SetToolTip($script:btnComRefresh, 'Rechercher les ports COM présents et libres')
$g3.Controls.Add($script:btnComRefresh)
$g3.Controls.Add((New-Label 'Bauds' 195 76));    $script:cmbBaud = New-Combo @('9600','19200','38400') $script:cfg.serial_baud 245 73 70 $false
$script:ledRig = New-Led $g3 'FT-2000' 340 48
$g3.Controls.Add((New-Label 'Aller à (kHz)' 425 48))
$script:cmbGoto = New-Object System.Windows.Forms.ComboBox; $script:cmbGoto.Location = '508,45'; $script:cmbGoto.Width = 100; $script:cmbGoto.DropDownStyle = 'DropDown'; $script:cmbGoto.Enabled = $false
[void]$script:cmbGoto.Items.AddRange([string[]]@($script:cfg.goto_history))
$script:cmbGoto.add_KeyDown({ param($o, $e) if ($e.KeyCode -eq 'Return') { $e.SuppressKeyPress = $true; Goto-Freq } })
# selection dans la liste = validation immediate. A cet instant .Text n'est pas encore a jour : on prend
# l'element choisi, et on envoie apres la fin de l'evenement pour pouvoir reordonner la liste sans conflit.
$script:cmbGoto.add_SelectionChangeCommitted({
    if ($script:gotoBusy -or $null -eq $script:cmbGoto.SelectedItem) { return }
    $v = [string]$script:cmbGoto.SelectedItem
    [void]$form.BeginInvoke([Action]{ Goto-Freq $v }.GetNewClosure())
})
# clic droit sur le champ : menu "Supprimer de la liste" avec toutes les frequences memorisees
$script:menuGoto = New-Object System.Windows.Forms.ContextMenuStrip
$script:menuGoto.add_Opening({
    param($o, $e)
    $script:menuGoto.Items.Clear()
    $sub = New-Object System.Windows.Forms.ToolStripMenuItem('Supprimer de la liste')
    if ($script:cfg.goto_history.Count -eq 0) { $sub.Enabled = $false }
    foreach ($k in $script:cfg.goto_history) {
        $it = New-Object System.Windows.Forms.ToolStripMenuItem(($k + ' kHz'))
        $it.Tag = $k
        $it.add_Click({ param($src, $ev) Remove-GotoHistory ([string]$src.Tag) })
        [void]$sub.DropDownItems.Add($it)
    }
    [void]$script:menuGoto.Items.Add($sub)
    $all = New-Object System.Windows.Forms.ToolStripMenuItem('Vider toute la liste')
    $all.Enabled = ($script:cfg.goto_history.Count -gt 0)
    $all.add_Click({ foreach ($k in @($script:cfg.goto_history)) { Remove-GotoHistory $k } })
    [void]$script:menuGoto.Items.Add($all)
})
$script:cmbGoto.ContextMenuStrip = $script:menuGoto
# liste ouverte : la touche Suppr retire l'entree surlignee au clavier
$script:cmbGoto.add_KeyDown({ param($o, $e) if ($e.KeyCode -eq 'Delete' -and $script:cmbGoto.DroppedDown -and $script:cmbGoto.SelectedIndex -ge 0) { $e.SuppressKeyPress = $true; $k = [string]$script:cmbGoto.SelectedItem; $script:cmbGoto.DroppedDown = $false; Remove-GotoHistory $k } })
$g3.Controls.Add($script:cmbGoto)
$script:lblFreq = New-Label '—' 338 69; $script:lblFreq.Font = New-Object System.Drawing.Font('Consolas', 15, [System.Drawing.FontStyle]::Bold); $script:lblFreq.ForeColor = [System.Drawing.Color]::FromArgb(16, 48, 112)
$script:lblMode = New-Label '' 512 74; $script:lblMode.Font = New-Object System.Drawing.Font('Consolas', 11, [System.Drawing.FontStyle]::Bold); $script:lblMode.ForeColor = [System.Drawing.Color]::FromArgb(16, 48, 112)
$script:btnSave = New-Object System.Windows.Forms.Button; $script:btnSave.Text = 'Save'; $script:btnSave.Location = '562,70'; $script:btnSave.Size = '46,24'; $script:btnSave.Enabled = $false
$script:btnSave.add_Click({ Save-CurrentFreq })
$g3.Controls.Add($script:btnSave)
$g3.Controls.AddRange(@($script:rbHrd, $script:rbSerial, $script:cmbHrdHost, $script:cmbHrdPort, $script:cmbCom, $script:cmbBaud, $script:lblFreq, $script:lblMode))
$script:rbHrd.add_CheckedChanged({ Refresh-Backend }); $script:rbSerial.add_CheckedChanged({ Refresh-Backend })

# --- Scan
$g4 = New-Object System.Windows.Forms.GroupBox; $g4.Text = 'Scan du FT-2000'; $g4.Location = '10,368'; $g4.Size = '625,56'; $g4.Anchor = 'Top,Left,Right'
$g4.Controls.Add((New-Label 'Début (kHz)' 12 24)); $script:txtScanStart = New-Text ([string]$script:cfg.scan_start) 85 21 75
$g4.Controls.Add((New-Label 'Fin (kHz)' 170 24));  $script:txtScanEnd   = New-Text ([string]$script:cfg.scan_end) 230 21 75
$g4.Controls.Add((New-Label 'Pas' 315 24));        $script:cmbScanStep  = New-Combo @('500 Hz','1 kHz') $(if ([int]$script:cfg.scan_step_hz -ge 1000) { '1 kHz' } else { '500 Hz' }) 345 21 70 $false
$g4.Controls.Add((New-Label 'Attente' 425 24));    $script:cmbScanWait  = New-Combo @(1..10 | ForEach-Object { "$_ s" }) ("$($script:cfg.scan_wait_s) s") 475 21 55 $false
$script:btnScan = New-Object System.Windows.Forms.Button; $script:btnScan.Text = 'Lancer le scan'; $script:btnScan.Location = '540,19'; $script:btnScan.Size = '78,24'; $script:btnScan.Enabled = $false
$script:btnScan.add_Click({ if ($script:scanning) { Stop-Scan } else { Start-Scan } })
$g4.Controls.AddRange(@($script:txtScanStart, $script:txtScanEnd, $script:cmbScanStep, $script:cmbScanWait, $script:btnScan))

# --- Boutons
$script:btnStart = New-Object System.Windows.Forms.Button; $script:btnStart.Text = 'Démarrer'; $script:btnStart.Location = '10,432'; $script:btnStart.Size = '90,28'
$script:btnStop  = New-Object System.Windows.Forms.Button; $script:btnStop.Text = 'Arrêter';   $script:btnStop.Location = '106,432'; $script:btnStop.Size = '90,28'; $script:btnStop.Enabled = $false
$script:chkDebug = New-Check 'Journal' 210 436 $script:cfg.show_log
$script:chkAuto  = New-Check 'Démarrer avec Windows' 285 436 (Get-StartWithWindows)
$script:chkTop   = New-Check 'Avant-plan' 440 436 $script:cfg.topmost
$script:chkTop.add_CheckedChanged({ $form.TopMost = $script:chkTop.Checked; $script:cfg.topmost = $script:chkTop.Checked; Save-Config })
$script:chkCompact = New-Check 'Réduit' 0 436 $script:cfg.compact
$script:chkCompact.add_CheckedChanged({ $script:cfg.compact = $script:chkCompact.Checked; Save-Config; Apply-LogVisibility })
$script:chkAuto.add_CheckedChanged({ try { Set-StartWithWindows $script:chkAuto.Checked } catch { Log ('Raccourci de démarrage : ' + $_.Exception.Message); } })
$btnClear = New-Object System.Windows.Forms.Button; $btnClear.Text = 'Effacer'; $btnClear.Location = '565,432'; $btnClear.Size = '70,28'; $btnClear.Anchor = 'Top,Right'
$script:btnStart.add_Click({ Start-Bridge }); $script:btnStop.add_Click({ Stop-Bridge })
$btnClear.add_Click({ $script:txtLog.Clear() })
$script:chkDebug.add_CheckedChanged({ $script:cfg.show_log = $script:chkDebug.Checked; Save-Config; Apply-LogVisibility })

# --- Journal
$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Multiline = $true; $script:txtLog.ReadOnly = $true; $script:txtLog.ScrollBars = 'Vertical'; $script:txtLog.WordWrap = $false
$script:txtLog.Location = '10,468'; $script:txtLog.Size = '625,170'; $script:txtLog.Anchor = 'Top,Bottom,Left,Right'
$script:txtLog.Font = New-Object System.Drawing.Font('Consolas', 9); $script:txtLog.BackColor = [System.Drawing.Color]::White

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$script:status = New-Object System.Windows.Forms.ToolStripStatusLabel; $script:status.Text = 'Arrêté'
$statusStrip.Items.Add($script:status) | Out-Null

# les cases de cette ligne se placent d'apres leur largeur reelle, pour ne jamais se chevaucher
$script:chkAuto.Left = $script:chkDebug.Left + $script:chkDebug.PreferredSize.Width + 14
$script:chkTop.Left  = $script:chkAuto.Left  + $script:chkAuto.PreferredSize.Width  + 14
$script:chkCompact.Left = $script:chkTop.Left + $script:chkTop.PreferredSize.Width + 14
$form.TopMost = [bool]$script:cfg.topmost
$form.Controls.AddRange(@($g1, $g2, $g3, $g4, $script:btnStart, $script:btnStop, $script:chkDebug, $script:chkAuto, $script:chkTop, $script:chkCompact, $btnClear, $script:txtLog, $statusStrip))
Refresh-Backend

$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 100
$timer.add_Tick({ try { Step } catch { Log ('Erreur : ' + $_.Exception.Message) } })
$timer.Start()

$form.add_FormClosing({
    param($sender, $e)
    if ($e.CloseReason -ne [System.Windows.Forms.CloseReason]::UserClosing) { $script:shuttingDown = $true }   # arret de Windows : l'etat "en marche" est conservé
    if ($script:running -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        # passerelle en marche : la croix reduit la fenetre dans la barre des taches, elle ne ferme pas
        $e.Cancel = $true
        $form.WindowState = 'Minimized'
        return
    }
    [void](Read-Form); Stop-Bridge; $timer.Stop()
})
$form.add_Shown({ Apply-LogVisibility; if ($script:cfg.was_running) { Log 'La passerelle tournait à la dernière fermeture : relance automatique.'; $script:autoStart = $true; Start-Bridge } })

[void]$form.ShowDialog()
