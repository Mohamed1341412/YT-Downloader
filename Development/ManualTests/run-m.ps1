param(
    [Parameter(Mandatory)][ValidateSet('M1','M2','M3')][string]$Mode,
    [ValidateSet('Continue','Stop')][string]$EAP = 'Continue',
    [string]$Url = $null
)

Set-Location "E:\Work-Staton\Projects\PowerShell\YT Downloader"
$ErrorActionPreference = 'Continue'

# --- yt-dlp hygiene check (must show only .exe) ---
"=== Get-Command yt-dlp -All ==="
Get-Command yt-dlp -All | Format-Table Name,CommandType,Source
""

# --- Isolated run directory ---
$runDir = Join-Path $env:TEMP "M-$Mode-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$env:APPDATA = $runDir
$dest = Join-Path $runDir 'dest'
New-Item -ItemType Directory -Path $dest -Force | Out-Null

. .\Development\YT-Downloader.ps1
Initialize-App 2>&1 | Out-Null

$archive = $null
$item    = $null

switch ($Mode) {
    'M1' {
        $url = if ($Url) { $Url } else { 'https://www.youtube.com/watch?v=8pQYt1Og75E' }
        # F48: pre-check the URL is actually a private video
        $simOut = & yt-dlp.exe --simulate $url 2>&1
        $simExit = $LASTEXITCODE
        "=== M1 PRE-CHECK ==="
        "yt-dlp.exe --simulate exit=$simExit"
        ($simOut | Where-Object { $_ -match 'ERROR' } | Select-Object -First 2) | ForEach-Object { "  $_" }
        $isPrivate = ($simExit -eq 1) -and (($simOut -join "`n") -match 'Private video')
        if (-not $isPrivate) {
            "M1 SKIPPED - URL $url is not a private video (exit=$simExit)"
            "Use fixture + shim tests as evidence instead."
            return
        }
        "M1 URL confirmed private. Proceeding."
        ""
        $item = [PSCustomObject]@{
            Id=[guid]::NewGuid().ToString(); Url=$url; Mode='Video'; MaxHeight=720;
            AudioFormat=''; Bitrate=0; Destination=$dest; Status='Pending'; Error='';
			OutputFilePath=''; VideoId=$($url -replace '.*[/=]', ''); RetryCount=0; AttemptCount=0;
            FailureKind='None'; RetryDecision='None'
        }
        $script:Manifest = @($item)
    }
    'M2' {
        # Verify network is actually off
        "=== M2 PRE-CHECK ==="
        $net = Test-NetConnection www.youtube.com -Port 443 -WarningAction SilentlyContinue -InformationLevel Quiet
        "Test-NetConnection www.youtube.com:443 -> $net"
        if ($net) {
            "M2 SKIPPED - network is ON. Turn off Wi-Fi/Ethernet and re-run."
            return
        }
        "Network confirmed off. Proceeding."
        ""
        $url = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'
        $item = [PSCustomObject]@{
            Id=[guid]::NewGuid().ToString(); Url=$url; Mode='Video'; MaxHeight=720;
            AudioFormat=''; Bitrate=0; Destination=$dest; Status='Pending'; Error='';
            OutputFilePath=''; VideoId='dQw4w9WgXcQ'; RetryCount=0; AttemptCount=0;
            FailureKind='None'; RetryDecision='None'
        }
        $script:Manifest = @($item)
    }
    'M3' {
        # F47: generate a real 2-second video clip (OtherMode when checked against Audio)
        $id = 'dQw4w9WgXcQ'
        $url = "https://www.youtube.com/watch?v=$id"
        $fake = Join-Path $dest "existing_${id}.mp4"
        # Try libx264, fall back to mpeg4
        & ffmpeg -y -loglevel error -f lavfi -i "testsrc=d=2:s=320x240:r=10" -f lavfi -i "sine=d=2" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest $fake 2>$null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $fake)) {
            "libx264 failed, retrying with mpeg4..."
            & ffmpeg -y -loglevel error -f lavfi -i "testsrc=d=2:s=320x240:r=10" -f lavfi -i "sine=d=2" -c:v mpeg4 -c:a aac -shortest $fake 2>$null
        }
        if (-not (Test-Path $fake) -or (Get-Item $fake).Length -lt 1000) {
            "M3 SKIPPED - could not create a real video file with ffmpeg"
            return
        }

        # Verify the verdict is OtherMode (i.e., video file checked as Audio)
        $verdict = Get-FileVerdict -FilePath $fake -Mode 'Audio'
        "=== M3 VERDICT PRE-CHECK ==="
        "Get-FileVerdict('$fake', Mode='Audio') -> Verdict=$($verdict.Verdict) Reason=$($verdict.Reason)"
        if ($verdict.Verdict -ne 'OtherMode') {
            "M3 SKIPPED - pre-existing file did not classify as OtherMode"
            return
        }
        ""

        # F46: archive format is "<extractor> <id>", two tokens, ID second
        $archive = $script:AudioArchive
        New-Item -ItemType Directory -Path (Split-Path $archive -Parent) -Force | Out-Null
        Set-Content -LiteralPath $archive -Value "youtube $id" -Encoding UTF8
        "Audio archive seeded: $archive -> 'youtube $id'"
        ""

        $item = [PSCustomObject]@{
            Id=[guid]::NewGuid().ToString(); Url=$url; Mode='Audio'; MaxHeight=0;
            AudioFormat='MP3'; Bitrate=128; Destination=$dest; Status='Pending'; Error='';
            OutputFilePath=''; VideoId=$id; RetryCount=0; AttemptCount=0;
            FailureKind='None'; RetryDecision='None'
        }
        $script:Manifest = @($item)
    }
}

"=== RUN $Mode (EAP=$EAP) ==="
"ItemId=$($item.Id)"
"Url=$($item.Url)"
"Destination=$dest"
"APPDATA=$env:APPDATA"
if ($archive) { "Archive=$archive" }
""

# EAP set immediately before the call - the live-fire proof
$ErrorActionPreference = $EAP
$result = Invoke-ItemDownload -Item $item
$ErrorActionPreference = 'Continue'

""
"=== RESULT ==="
"ReturnValue=$result"
"Status=$($item.Status)"
"FailureKind=$($item.FailureKind)"
"RetryDecision=$($item.RetryDecision)"
"AttemptCount=$($item.AttemptCount)"
"Error=$($item.Error)"
""
"=== MANIFEST ROW ==="
$saved = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
@($saved) | Where-Object { $_.Id -eq $item.Id } | Format-List