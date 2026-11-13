#Requires -Version 5.1
#==============================================================================
# Safe Execution Guard (Prevents Main/Mutex execution during Pester Dot-sourcing)
#==============================================================================
$script:RunAsMain = $MyInvocation.InvocationName -ne '.'

#==============================================================================
# Global Configuration & State
#==============================================================================
$script:AppDir = Join-Path $env:APPDATA "YT-DL-CLI"
$script:ManifestPath = Join-Path $script:AppDir "manifest.json"
$script:SettingsPath = Join-Path $script:AppDir "settings.json"
$script:VideoArchive = Join-Path $script:AppDir "video_archive.txt"
$script:AudioArchive = Join-Path $script:AppDir "audio_archive.txt"
$script:Manifest = @()
$script:CurrentRunItems = @()
$script:CurrentLogPath = ""
$script:StateInitialized = $false
$script:Config = @{ MaxRetries = 3 } # Changable on demand
$script:HistoricalMaxAttempts = 1000 # Fixed historical upper bound to preserve legacy data
$script:ValidFailureKinds = @('None', 'Transient', 'Permanent', 'Configuration', 'Unknown')
$script:ValidRetryDecisions = @('None', 'Retry', 'Stop')
$script:RunState = @{
    DownloadsCompleted      = $true
    VerificationsPassed     = $true
    ManifestSaved           = $true
    SettingsSaved           = $true
    LogsWritten             = $true
    Interrupted             = $false
    PreviousInstanceCrashed = $false
}
$script:MainMutex = $null
$script:ArchiveMutex = $null
$mutexName = "Global\YT-DL-CLI-SingleInstance"
$archiveMutexName = "Global\YT-DL-CLI-ArchiveLock"

# Acquire locks ONLY if running as main script
if ($script:RunAsMain) {
    try {
        $script:MainMutex = New-Object System.Threading.Mutex($false, $mutexName)
        $script:ArchiveMutex = New-Object System.Threading.Mutex($false, $archiveMutexName)
        try {
            if (-not $script:MainMutex.WaitOne(0)) {
                Write-Host "[ERROR] Another instance is already running. Halting." -ForegroundColor Red
                exit 1
            }
        }
        catch [System.Threading.AbandonedMutexException] {
            $script:RunState.PreviousInstanceCrashed = $true
        }
    }
    catch [System.UnauthorizedAccessException] {
        Write-Host "[ERROR] Failed to acquire lock due to permissions. Halting." -ForegroundColor Red
        exit 1
    }
    catch {
        Write-Host "[ERROR] Failed to acquire lock: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

#==============================================================================
# Helpers & Validation
#==============================================================================
function Test-MaxRetriesConfig {
    param([Parameter(Mandatory = $false)]$Value = $script:Config.MaxRetries)
    if ($Value -isnot [int]) { return $false }
    if ($Value -lt 0 -or $Value -gt 10) { return $false }
    return $true
}

function Get-MaxAttempts {
    return ([int]$script:Config.MaxRetries + 1)
}

function Get-InvalidTargetPath {
    param(
        [string]$FilePath,
        [string]$Directory
    )
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $guidShort = [guid]::NewGuid().ToString().Substring(0, 8)
    # المواصفة: <الاسم الكامل بالامتداد>.invalid_<ts>_<guid8>
    $newFileName = "${fileName}.invalid_${timestamp}_${guidShort}"
    return Join-Path $Directory $newFileName
}

function Get-MediaInfo {
    param([string]$FilePath)
    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath)) {
        return @{ Success = $false; Error = "File not found"; IsCommandFailure = $false }
    }
    try {
        $probeArgs = @(
            "-v", "error",
            "-count_packets",
            "-show_entries", "stream=codec_type,nb_read_packets",
            "-show_entries", "format=duration",
            "-of", "json",
            $FilePath
        )
        $raw = & ffprobe @probeArgs 2>$null
        $exitCode = $global:LASTEXITCODE
        
        # إذا فشل الأمر نفسه (exit code != 0) فهو Corrupt (ملف تالف)، وليس Unknown
        if ($exitCode -ne 0) {
            return @{ Success = $false; Error = "ffprobe exited with code $exitCode"; IsCommandFailure = $false }
        }
        
        $jsonText = $raw -join [Environment]::NewLine
        $data = $jsonText | ConvertFrom-Json -ErrorAction Stop
        
        $hasVideo = $false; $videoPackets = 0
        $hasAudio = $false; $audioPackets = 0
        
        if ($data.streams) {
            foreach ($stream in $data.streams) {
                if ($stream.codec_type -eq 'video') { 
                    $hasVideo = $true
                    $parsed = 0
                    [int]::TryParse([string]$stream.nb_read_packets, [ref]$parsed) | Out-Null
                    $videoPackets = $parsed
                }
                if ($stream.codec_type -eq 'audio') { 
                    $hasAudio = $true
                    $parsed = 0
                    [int]::TryParse([string]$stream.nb_read_packets, [ref]$parsed) | Out-Null
                    $audioPackets = $parsed
                }
            }
        }
        
        $duration = 0.0
        if ($data.format -and $data.format.duration) {
            [double]::TryParse([string]$data.format.duration, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$duration) | Out-Null
        }

        return @{ 
            Success          = $true
            Duration         = $duration
            HasVideo         = $hasVideo
            HasAudio         = $hasAudio
            VideoPackets     = $videoPackets
            AudioPackets     = $audioPackets
            Error            = $null
            IsCommandFailure = $false
        }
    }
    catch [System.Management.Automation.CommandNotFoundException] {
        return @{ Success = $false; Error = "ffprobe not found"; IsCommandFailure = $true }
    }
    catch {
        # يشمل ذلك أخطاء JSON أو أي استثناء غير متوقع أثناء التنفيذ
        return @{ Success = $false; Error = "Exception: $($_.Exception.Message)"; IsCommandFailure = $true }
    }
}

function Get-FileVerdict {
    param(
        [string]$FilePath,
        [ValidateSet("Video", "Audio")]
        [string]$Mode
    )
    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        return @{ Verdict = "Corrupt"; Reason = "Empty file path" }
    }
    
    $fileItem = Get-Item -LiteralPath $FilePath -ErrorAction SilentlyContinue
    if (-not $fileItem -or $fileItem.PSIsContainer -or $fileItem.Length -le 0) {
        return @{ Verdict = "Corrupt"; Reason = "File missing, is a directory, or zero length" }
    }

    $mediaInfo = Get-MediaInfo -FilePath $FilePath
    
    # Unknown فقط إذا كان ffprobe غير متاح أو حدث استثناء غير متوقع
    if (-not $mediaInfo.Success -and $mediaInfo.IsCommandFailure) {
        return @{ Verdict = "Unknown"; Reason = "ffprobe failed or unavailable: $($mediaInfo.Error)" }
    }
    
    # إذا نجح تشغيل ffprobe لكنه أرجع خطأ في قراءة الملف، فهو تالف
    if (-not $mediaInfo.Success -and -not $mediaInfo.IsCommandFailure) {
        return @{ Verdict = "Corrupt"; Reason = "ffprobe failed to read file: $($mediaInfo.Error)" }
    }

    # إضافة شرط جديد: ملف بدون أي مسارات صوت أو فيديو يعتبر تالفاً لمنع اعتباره OtherMode وتركه مكانه
    if (-not $mediaInfo.HasVideo -and -not $mediaInfo.HasAudio) {
        return @{ Verdict = "Corrupt"; Reason = "No audio or video streams" }
    }

    # التحقق من أن المدة > 0
    if ($mediaInfo.Duration -le 0) {
        return @{ Verdict = "Corrupt"; Reason = "Invalid or zero duration" }
    }

    if ($Mode -eq "Video") {
        if (-not $mediaInfo.HasVideo) {
            return @{ Verdict = "OtherMode"; Reason = "No video stream found" }
        }
        if ($mediaInfo.VideoPackets -le 0) {
            return @{ Verdict = "Corrupt"; Reason = "Video stream has 0 or negative packets" }
        }
        return @{ Verdict = "Valid"; Reason = "Valid video file" }
    }
    else {
        # Mode -eq "Audio"
        if ($mediaInfo.HasVideo) {
            return @{ Verdict = "OtherMode"; Reason = "Contains video stream (expected audio only)" }
        }
        if (-not $mediaInfo.HasAudio) {
            return @{ Verdict = "OtherMode"; Reason = "No audio stream found" }
        }
        if ($mediaInfo.AudioPackets -le 0) {
            return @{ Verdict = "Corrupt"; Reason = "Audio stream has 0 or negative packets" }
        }
        return @{ Verdict = "Valid"; Reason = "Valid audio file" }
    }
}

function Test-PathInsideDirectory {
    param(
        [string]$Path,
        [string]$Directory
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Directory)) {
        return $false
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $fullDir = [System.IO.Path]::GetFullPath($Directory)
        
        if (-not $fullDir.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
            $fullDir += [System.IO.Path]::DirectorySeparatorChar
        }
        
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            return $false
        }
        
        $parentDir = [System.IO.Path]::GetDirectoryName($fullPath)
        if (-not $parentDir.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
            $parentDir += [System.IO.Path]::DirectorySeparatorChar
        }
        
        return $parentDir.Equals($fullDir, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Move-ToInvalid {
    param(
        [string]$FilePath,
        [string]$Directory
    )
    $result = @{ Success = $false; NewPath = $null; Error = $null }
    
    if (-not (Test-PathInsideDirectory -Path $FilePath -Directory $Directory)) {
        $result.Error = "Path validation failed: File is not a direct child of the target directory or does not exist."
        return $result
    }

    $maxRetries = 5
    $lastError = ""
    for ($i = 1; $i -le $maxRetries; $i++) {
        try {
            $newPath = Get-InvalidTargetPath -FilePath $FilePath -Directory $Directory
            
            # التحقق من عدم وجود تصادم في الاسم
            if (Test-Path -LiteralPath $newPath) {
                continue # تصادم، حاول مرة أخرى باسم جديد
            }
            
            [System.IO.File]::Move($FilePath, $newPath)
            $result.Success = $true
            $result.NewPath = $newPath
            return $result
        }
        catch [System.IO.IOException] {
            $lastError = $_.Exception.Message
            continue
        }
        catch {
            $result.Error = "Move failed: $($_.Exception.Message)"
            return $result
        }
    }
    
    $result.Error = "Move failed after $maxRetries attempts due to persistent naming collisions or file locks. Last error: $lastError"
    return $result
}

function Get-FailureKind {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,
        
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string[]]$ErrorText
    )
    
    # Initialize result
    $result = @{
        FailureKind   = 'Unknown'
        RetryDecision = 'Retry'
        Reason        = 'unknown failure'
        Evidence      = ''
    }
    
    # Exit 0: Success baseline - no analysis
    if ($ExitCode -eq 0) {
        $result.FailureKind = 'None'
        $result.RetryDecision = 'None'
        $result.Reason = 'success'
        return $result
    }
    
    # Exit 2: Bad option - requires both exit code AND parser error line
    if ($ExitCode -eq 2) {
        $hasParserError = $false
        $parserLine = ''
        
        if ($null -ne $ErrorText -and $ErrorText.Count -gt 0) {
            $allLines = @()
            foreach ($element in $ErrorText) {
                if (-not [string]::IsNullOrEmpty($element)) {
                    $allLines += $element -split '\r?\n'
                }
            }
            
            foreach ($line in $allLines) {
                $cleanLine = $line -replace '\x1b\[[0-9;]*m', ''
                if ($cleanLine -match '^yt-dlp(?:\.exe)?:\s*error:') {
                    $hasParserError = $true
                    $parserLine = $cleanLine
                    break
                }
            }
        }
        
        if ($hasParserError) {
            $result.FailureKind = 'Configuration'
            $result.RetryDecision = 'Stop'
            $result.Reason = 'invalid yt-dlp option'
            $result.Evidence = $parserLine
            if ($result.Evidence.Length -gt 300) {
                $result.Evidence = $result.Evidence.Substring(0, 300)
            }
            return $result
        }
        # Exit 2 without parser error: fall through to default Unknown/Retry
    }
    
    # Exit 1: Analyze last ERROR: line
    if ($ExitCode -eq 1) {
        $errorLines = @()
        $warningLines = @()
        
        if ($null -ne $ErrorText -and $ErrorText.Count -gt 0) {
            $allLines = @()
            foreach ($element in $ErrorText) {
                if (-not [string]::IsNullOrEmpty($element)) {
                    $allLines += $element -split '\r?\n'
                }
            }
            
            foreach ($line in $allLines) {
                $cleanLine = $line -replace '\x1b\[[0-9;]*m', ''
                if ($cleanLine -match '^ERROR:') {
                    $errorLines += $cleanLine
                }
                elseif ($cleanLine -match '^WARNING:') {
                    $warningLines += $cleanLine
                }
            }
        }
        
        if ($errorLines.Count -eq 0) {
            # No ERROR: line found
            if ($warningLines.Count -gt 0) {
                $result.Evidence = ($warningLines -join ' | ')
                if ($result.Evidence.Length -gt 300) {
                    $result.Evidence = $result.Evidence.Substring(0, 300)
                }
            }
            return $result
        }
        
        $lastError = $errorLines[-1]
        
        # Detect patterns - categorize as critical or weak
        $patterns = @{
            Permanent     = @()
            Configuration = @()
            Transient     = @()
            Weak          = @()  # Patterns that don't participate in conflict detection
        }
        
        # Permanent patterns - Fixed: \S+ instead of \w+ to support IDs with hyphens
        if ($lastError -match '(?i)\S+:\s+Private video\b') {
            $patterns.Permanent += @{ Pattern = 'Private video'; Reason = 'private video' }
        }
        if ($lastError -match '(?i)Incomplete YouTube ID' -and $lastError -match '(?i)looks truncated') {
            $patterns.Permanent += @{ Pattern = 'Incomplete YouTube ID'; Reason = 'invalid video id' }
        }
        
        # Configuration patterns
        if ($lastError -match '(?i)Sign in to confirm your age') {
            $patterns.Configuration += @{ Pattern = 'age restricted'; Reason = 'age restricted' }
        }
        if ($lastError -match '(?i)Requested format is not available') {
            $patterns.Configuration += @{ Pattern = 'format unavailable'; Reason = 'format unavailable' }
        }
        
        # Transient patterns
        if ($lastError -match '(?i)TransportError') {
            $patterns.Transient += @{ Pattern = 'TransportError'; Reason = 'network transport error' }
        }
        if ($lastError -match '(?i)getaddrinfo failed') {
            $patterns.Transient += @{ Pattern = 'getaddrinfo failed'; Reason = 'network transport error' }
        }
        if ($lastError -match '(?i)Failed to resolve') {
            $patterns.Transient += @{ Pattern = 'Failed to resolve'; Reason = 'network transport error' }
        }
        if ($lastError -match '(?i)HTTP Error 429') {
            $patterns.Transient += @{ Pattern = 'HTTP Error 429'; Reason = 'http 429' }
        }
        if ($lastError -match '(?i)HTTP Error 5\d\d') {
            $patterns.Transient += @{ Pattern = 'HTTP Error 5xx'; Reason = 'http 5xx' }
        }
        
        # Weak patterns (don't participate in conflict detection)
        if ($lastError -match '(?i)HTTP Error 4\d\d' -and $lastError -notmatch '(?i)HTTP Error 429') {
            $patterns.Weak += @{ Pattern = 'HTTP Error 4xx'; Reason = 'unknown failure' }
        }
        if ($lastError -match '(?i)\bVideo unavailable\b' -and $lastError -notmatch '(?i)\bThis video is unavailable\b') {
            $patterns.Weak += @{ Pattern = 'Video unavailable'; Reason = 'unknown failure' }
        }
        if ($lastError -match '(?i)\bThis video is unavailable\b') {
            $patterns.Weak += @{ Pattern = 'This video is unavailable'; Reason = 'unknown failure' }
        }
        
        # Count total critical matches
        $totalCritical = $patterns.Permanent.Count + $patterns.Configuration.Count + $patterns.Transient.Count
        
        # Conflict detection: only among critical categories
        if ($totalCritical -gt 1) {
            # Multiple critical patterns from different categories = conflict
            $categories = @()
            if ($patterns.Permanent.Count -gt 0) { $categories += 'Permanent' }
            if ($patterns.Configuration.Count -gt 0) { $categories += 'Configuration' }
            if ($patterns.Transient.Count -gt 0) { $categories += 'Transient' }
            
            if ($categories.Count -gt 1) {
                # Conflict detected
                $result.FailureKind = 'Unknown'
                $result.RetryDecision = 'Retry'
                $result.Reason = 'conflicting evidence'
                $result.Evidence = $lastError
                if ($result.Evidence.Length -gt 300) {
                    $result.Evidence = $result.Evidence.Substring(0, 300)
                }
                return $result
            }
        }
        
        # No conflict: apply priority within category
        if ($patterns.Permanent.Count -gt 0) {
            $result.FailureKind = 'Permanent'
            $result.RetryDecision = 'Stop'
            $result.Reason = $patterns.Permanent[0].Reason
        }
        elseif ($patterns.Configuration.Count -gt 0) {
            $result.FailureKind = 'Configuration'
            $result.RetryDecision = 'Stop'
            $result.Reason = $patterns.Configuration[0].Reason
        }
        elseif ($patterns.Transient.Count -gt 0) {
            $result.FailureKind = 'Transient'
            $result.RetryDecision = 'Retry'
            $result.Reason = $patterns.Transient[0].Reason
        }
        elseif ($patterns.Weak.Count -gt 0) {
            $result.FailureKind = 'Unknown'
            $result.RetryDecision = 'Retry'
            $result.Reason = $patterns.Weak[0].Reason
        }
        
        # Set evidence
        $result.Evidence = $lastError
        if ($warningLines.Count -gt 0) {
            $result.Evidence += ' | ' + ($warningLines -join ' | ')
        }
        if ($result.Evidence.Length -gt 300) {
            $result.Evidence = $result.Evidence.Substring(0, 300)
        }
        
        return $result
    }
    
    # Any other exit code: Unknown/Retry
    return $result
}

function Normalize-FailureClassification {
    param(
        [string]$Status,
        $FailureKind,    # Untyped to allow $null
        $RetryDecision   # Untyped to allow $null
    )
    
    $validKinds = @('None', 'Transient', 'Permanent', 'Configuration', 'Unknown')
    $validDecisions = @('None', 'Retry', 'Stop')
    
    # Check absence (null or missing)
    $fkAbsent = ($null -eq $FailureKind)
    $rdAbsent = ($null -eq $RetryDecision)
    
    # Check invalid (non-canonical string)
    $fkInvalid = (-not $fkAbsent) -and ($FailureKind -cnotin $validKinds)
    $rdInvalid = (-not $rdAbsent) -and ($RetryDecision -cnotin $validDecisions)
    
    # 1. Success always clears to None/None
    if ($Status -eq 'Success') {
        return @{ FailureKind = 'None'; RetryDecision = 'None'; Reason = 'Success' }
    }
    
    # 2. Pending/Downloading always clear to None/None; reason reflects stored pair
    if ($Status -in 'Pending', 'Downloading') {
        $reason = if ($fkInvalid -or $rdInvalid) { 'Invalid' }
                  elseif ($fkAbsent -or $rdAbsent) { 'Default' }
                  else { 'Valid' }
        return @{ FailureKind = 'None'; RetryDecision = 'None'; Reason = $reason }
    }
    
    # 3. Any invalid value normalizes the whole pair to Unknown/Retry
    if ($fkInvalid -or $rdInvalid) {
        return @{ FailureKind = 'Unknown'; RetryDecision = 'Retry'; Reason = 'Invalid' }
    }
    
    # 4. If either is absent, default the whole pair by Status
    if ($fkAbsent -or $rdAbsent) {
        if ($Status -eq 'Failed') {
            return @{ FailureKind = 'Unknown'; RetryDecision = 'Retry'; Reason = 'Default' }
        }
        else {
            return @{ FailureKind = 'None'; RetryDecision = 'None'; Reason = 'Default' }
        }
    }
    
    # 5. Failed + None safety rule
    if ($Status -eq 'Failed' -and ($FailureKind -eq 'None' -or $RetryDecision -eq 'None')) {
        return @{ FailureKind = 'Unknown'; RetryDecision = 'Retry'; Reason = 'FailedNone' }
    }
    
    # 6. Both present and valid
    return @{ FailureKind = $FailureKind; RetryDecision = $RetryDecision; Reason = 'Valid' }
}

function Find-OutputCandidates {
    param(
        [string]$Directory,
        [string]$VideoId,
        [ValidateSet("Video", "Audio")]
        [string]$Mode
    )
    $candidates = @()
    
    if ([string]::IsNullOrWhiteSpace($Directory) -or [string]::IsNullOrWhiteSpace($VideoId)) {
        return $candidates
    }

    try {
        $fullDir = [System.IO.Path]::GetFullPath($Directory)
        if (-not (Test-Path -LiteralPath $fullDir -PathType Container)) {
            return $candidates
        }
    }
    catch {
        return $candidates
    }

    $validExts = @('mp4', 'webm', 'mkv', 'mov', 'm4a', 'mp3', 'opus', 'ogg', 'aac', 'flac', 'wav')
    
    # جلب الملفات المباشرة فقط (بدون بحث متداخل)
    $files = Get-ChildItem -LiteralPath $fullDir -File -ErrorAction SilentlyContinue
    
    foreach ($file in $files) {
        $ext = [System.IO.Path]::GetExtension($file.Name).TrimStart('.').ToLowerInvariant()
        
        # 1. التحقق من الامتداد المسموح
        if ($validExts -notcontains $ext) { continue }

        # 2. استبعاد الأنماط المحظورة صراحةً
        if ($file.Name -match '\.part$|\.ytdl$|\.invalid_|\.bak$|\.tmp$|\.f\d+\.|-Frag\d+\.part') {
            continue
        }

        # 3. التحقق من مطابقة المعرّف (حساسة لحالة الحروف Case-Sensitive)
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $expectedSuffix = "_$VideoId"
        if (-not $baseName.EndsWith($expectedSuffix, [System.StringComparison]::Ordinal)) {
            continue
        }

        # 4. الحصول على الحكم المشدد للملف
        $verdict = Get-FileVerdict -FilePath $file.FullName -Mode $Mode
        
        $candidates += [PSCustomObject]@{
            File    = $file
            Verdict = $verdict.Verdict
            Reason  = $verdict.Reason
        }
    }

    return $candidates
}

function Get-RetryPlan {
    param(
        [object]$Manifest = $script:Manifest,
        [switch]$Force
    )
    $maxAttempts = Get-MaxAttempts
    $candidates = @()
    $skipped = @()
    
    foreach ($m in $Manifest) {
        $eligible = $false
        if ($m.Status -in @("Failed", "Pending", "Downloading")) {
            $eligible = $true
        }
        elseif ($m.Status -eq "Success" -and -not (Test-FileValidity -FilePath $m.OutputFilePath -Mode $m.Mode)) {
            $eligible = $true
        }
        if ($eligible) { $candidates += $m }
    }

    if ($candidates.Count -eq 0) {
        return @{ ModifiedManifest = $null; ItemsToRun = @(); Skipped = @(); BlockedByStop = 0 }
    }

    $tempManifest = Copy-Manifest -Source $Manifest
    $toRun = @()
    
    foreach ($c in $candidates) {
        $idx = -1
        for ($i = 0; $i -lt $tempManifest.Count; $i++) {
            if ([string]$tempManifest[$i].Id -eq [string]$c.Id) { $idx = $i; break }
        }
        if ($idx -lt 0) { continue }
        
        $entry = $tempManifest[$idx]
        
        $isStop = ([string]$entry.Status -eq 'Failed' -and [string]$entry.RetryDecision -eq 'Stop')
        $vid = if ($entry.VideoId) { $entry.VideoId } else { Get-VideoId -Url $entry.Url }
        $invalid = [string]::IsNullOrWhiteSpace($vid)
        if ($invalid) {
            $entry.Status = "Failed"
            $entry.Error = "Invalid YouTube URL / VideoId"
            $entry.FailureKind = 'Permanent'
            $entry.RetryDecision = 'Stop'
            $skipped += @{
                Id = $entry.Id
                Url = $entry.Url
                VideoId = $vid
                FailureKind = $entry.FailureKind
                Error = $entry.Error
                AttemptCount = $entry.AttemptCount
                SkipReason = 'InvalidVideoId'
            }
            continue
        }
        if ($isStop -and -not $Force) {
            $skipped += @{
                Id = $entry.Id
                Url = $entry.Url
                VideoId = $vid
                FailureKind = $entry.FailureKind
                Error = $entry.Error
                AttemptCount = $entry.AttemptCount
                SkipReason = 'Stop'
            }
            continue
        }
        if ($isStop -or [int]$entry.AttemptCount -ge $maxAttempts) {
            $entry.AttemptCount = 0
            $entry.RetryCount = 0
        }
        
        $previousStatus = [string]$entry.Status
        $entry.Status = "Pending"
        $entry.Error = ""
        $entry.VideoId = $vid
        # Clear FailureKind/RetryDecision on rescheduling (direct assignment, $entry comes from Copy-Manifest)
        $entry.FailureKind = 'None'
        $entry.RetryDecision = 'None'
        if ($previousStatus -ne 'Success' -or -not (Test-FileValidity -FilePath $entry.OutputFilePath -Mode $entry.Mode)) {
            $entry.OutputFilePath = ""
        }
        
        $entry.RetryCount = [Math]::Min((Get-MaxAttempts) - 1, [Math]::Max(0, [int]$entry.AttemptCount - 1))
        $toRun += $entry
    }
    
    $blocked = @($skipped | Where-Object { $_.SkipReason -eq 'Stop' }).Count
    if ($toRun.Count -eq 0) {
        return @{ ModifiedManifest = $null; ItemsToRun = @(); Skipped = @($skipped); BlockedByStop = $blocked }
    }
    
    return @{ ModifiedManifest = $tempManifest; ItemsToRun = $toRun; Skipped = @($skipped); BlockedByStop = $blocked }
}

function Get-RetrySkipSummary {
    param([AllowNull()][object[]]$Skipped)
    if ($null -eq $Skipped -or @($Skipped).Count -eq 0) {
        return ,@()
    }

    $items = @($Skipped)
    $lines = @()
    $lines += "Skipped $($items.Count) item(s):"

    foreach ($reason in @('Stop', 'InvalidVideoId')) {
        $count = @($items | Where-Object { $_.SkipReason -eq $reason }).Count
        if ($count -gt 0) {
            $lines += "  ${reason}: $count"
        }
    }

    foreach ($kind in @('Transient', 'Permanent', 'Configuration', 'Unknown', 'None')) {
        $count = @($items | Where-Object { $_.SkipReason -eq 'Stop' -and $_.FailureKind -eq $kind }).Count
        if ($count -gt 0) {
            $lines += "    ${kind}: $count"
        }
    }

    $previewCount = [Math]::Min(5, $items.Count)
    for ($i = 0; $i -lt $previewCount; $i++) {
        $item = $items[$i]
        $display = if ([string]::IsNullOrWhiteSpace([string]$item.VideoId)) { $item.Url } else { $item.VideoId }
        $lines += "  $display - $($item.Error)"
    }

    if ($items.Count -gt 5) {
        $more = $items.Count - 5
        $lines += "  ... and $more more"
    }

    return ,$lines
}

function Invoke-RetryPlanFlow {
    $plan = Get-RetryPlan

    if ($plan.Skipped.Count -gt 0) {
        $summary = Get-RetrySkipSummary -Skipped $plan.Skipped
        foreach ($line in @($summary)) {
            [void](Write-Log $line "Yellow")
        }
    }

    if ($plan.BlockedByStop -gt 0) {
        $ans = Read-Host "Type FORCE to also retry the $($plan.BlockedByStop) blocked item(s), or press Enter to skip them"
        if ($ans -ceq 'FORCE') {
            $plan = Get-RetryPlan -Force
            if ($plan.Skipped.Count -gt 0) {
                $summary = Get-RetrySkipSummary -Skipped $plan.Skipped
                foreach ($line in @($summary)) {
                    [void](Write-Log $line "Yellow")
                }
            }
        }
    }

    [void](Write-Log "Items to run: $($plan.ItemsToRun.Count)")

    if ($plan.ItemsToRun.Count -eq 0) {
        if ($plan.BlockedByStop -gt 0) {
            [void](Write-Log "All eligible items are blocked (RetryDecision=Stop). Fix the cause, then use Force Retry." "Yellow")
        }
        elseif ($plan.Skipped.Count -gt 0) {
            [void](Write-Log "Remaining items have an invalid VideoId and cannot be retried." "Yellow")
        }
        else {
            [void](Write-Log "No failed, pending or interrupted items found." "Yellow")
        }
        [void](Read-Host "Press Enter to continue")
        return $null
    }

    return $plan
}

function Copy-Manifest {
    param([object]$Source)
    $copy = @()
    foreach ($item in @($Source)) {
        $retryCount = 0
        $retryValid = $false; $retryAbsent = ($null -eq $item.RetryCount)
        if ($null -ne $item.RetryCount) {
            $parsed = 0
            if ([int]::TryParse([string]$item.RetryCount, [ref]$parsed) -and $parsed -ge 0 -and $parsed -le $script:HistoricalMaxAttempts) {
                $retryCount = $parsed
                $retryValid = $true
            }
        }

        $attemptCount = 0
        $attemptValid = $false
        if ($null -ne $item.PSObject.Properties['AttemptCount']) {
            $parsedAttempts = 0
            if ([int]::TryParse([string]$item.AttemptCount, [ref]$parsedAttempts) -and $parsedAttempts -ge 0 -and $parsedAttempts -le $script:HistoricalMaxAttempts) {
                $attemptCount = $parsedAttempts
                $attemptValid = $true
            }
            else {
                # invalid value: treated as exhausted
                $attemptCount = $script:HistoricalMaxAttempts
                $attemptValid = $true
            }
        }
        else {
            if ($retryValid -or $retryAbsent) {
                if ($item.Status -eq 'Success') {
                    $attemptCount = [Math]::Max(1, [Math]::Min($script:HistoricalMaxAttempts, $retryCount))
                }
                else {
                    $attemptCount = [Math]::Min($script:HistoricalMaxAttempts, $retryCount)
                }
            }
            else {
                $attemptCount = $script:HistoricalMaxAttempts
            }
            $attemptValid = $true
        }

        if (-not $retryValid) {
            if ($attemptValid -and $attemptCount -lt $script:HistoricalMaxAttempts) {
                $retryCount = [Math]::Max(0, $attemptCount - 1)
            }
            else {
                $retryCount = $script:HistoricalMaxAttempts
            }
        }

        # Normalize FailureKind and RetryDecision (silent normalization in Copy-Manifest)
        $rawFK = if ($null -ne $item.PSObject.Properties['FailureKind']) { $item.FailureKind } else { $null }
        $rawRD = if ($null -ne $item.PSObject.Properties['RetryDecision']) { $item.RetryDecision } else { $null }
        $normalized = Normalize-FailureClassification -Status $item.Status -FailureKind $rawFK -RetryDecision $rawRD
     
        $copy += [PSCustomObject]@{
            Id             = $item.Id
            Url            = $item.Url
            Mode           = $item.Mode
            MaxHeight      = $item.MaxHeight
            AudioFormat    = $item.AudioFormat
            Bitrate        = $item.Bitrate
            Destination    = $item.Destination
            Status         = $item.Status
            Error          = $item.Error
            VideoId        = $item.VideoId
            OutputFilePath = $item.OutputFilePath
            RetryCount     = $retryCount
            AttemptCount   = $attemptCount
            FailureKind    = $normalized.FailureKind
            RetryDecision  = $normalized.RetryDecision
        }
    }
    return , $copy
}

function Test-ManifestSchema {
    param($Data)
    if ($null -eq $Data) { return $false }
    if ($Data -is [Array] -and $Data.Count -eq 0) { return $true }
    if ($Data -is [PSCustomObject]) { $Data = @($Data) }
    elseif ($Data -isnot [Array]) { return $false }

    $seenIds = @{}
    $validStatuses = @("Pending", "Downloading", "Success", "Failed")
    $validModes = @("Video", "Audio")
    $validAudioFormats = @("", "MP3", "M4A", "Best")
    $requiredFields = @('Id', 'Url', 'Status', 'Mode', 'Destination', 'VideoId', 'OutputFilePath', 'MaxHeight', 'Bitrate', 'AudioFormat', 'Error')

    foreach ($entry in $Data) {
        if ($null -eq $entry -or $entry -isnot [PSCustomObject]) { return $false }
        $names = $entry.PSObject.Properties.Name
        foreach ($field in $requiredFields) { if ($names -notcontains $field) { return $false } }
        
        if ($entry.Id -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { return $false }
        if ($seenIds.ContainsKey($entry.Id)) { return $false }
        $seenIds[$entry.Id] = $true
        
        if ($entry.Url -notmatch "^https?://") { return $false }
        if ($entry.Status -notin $validStatuses) { return $false }
        if ($entry.Mode -notin $validModes) { return $false }
        if ($entry.AudioFormat -notin $validAudioFormats) { return $false }
        
        $mh = 0; $br = 0
        if (-not [int]::TryParse([string]$entry.MaxHeight, [ref]$mh)) { return $false }
        if (-not [int]::TryParse([string]$entry.Bitrate, [ref]$br)) { return $false }
        if ($mh -lt 0 -or $mh -gt 10000) { return $false }
        if ($br -lt 0 -or $br -gt 1000) { return $false }
        
        if ($null -ne $entry.Destination -and $entry.Destination -isnot [string]) { return $false }
        if ($null -ne $entry.VideoId -and $entry.VideoId -isnot [string]) { return $false }
        if ($null -ne $entry.OutputFilePath -and $entry.OutputFilePath -isnot [string]) { return $false }
        if ($null -ne $entry.Error -and $entry.Error -isnot [string]) { return $false }

        # Validate RetryCount if present (Backward compatibility: not in requiredFields)
        if ($names -contains 'RetryCount') {
            $retry = 0
            if (-not [int]::TryParse([string]$entry.RetryCount, [ref]$retry) -or $retry -lt 0 -or $retry -gt $script:HistoricalMaxAttempts) {
                return $false
            }
        }
        if ($names -contains 'AttemptCount') {
            $attempts = 0
            if (-not [int]::TryParse([string]$entry.AttemptCount, [ref]$attempts) -or $attempts -lt 0 -or $attempts -gt $script:HistoricalMaxAttempts) {
                return $false
            }
        }
    }
    return $true
}

function Save-AtomicJson {
    param([string]$Path, [object]$Data)
    $unique = [guid]::NewGuid().ToString("N")
    $tempFile = "$Path.$unique.tmp"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    try {
        $json = ConvertTo-Json -InputObject $Data -Depth 5 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($json)) {
            throw "JSON serialization produced empty output."
        }
        [System.IO.File]::WriteAllText($tempFile, $json, $encoding)
        $tempRaw = [System.IO.File]::ReadAllText($tempFile, [System.Text.Encoding]::UTF8).Trim()
        if ($tempRaw -eq '[]') {
            $tempData = @()
        }
        else {
            $tempData = $tempRaw | ConvertFrom-Json -ErrorAction Stop
        }
        if ($Path -eq $script:ManifestPath -and -not (Test-ManifestSchema -Data $tempData)) {
            throw "Schema validation failed on temp file."
        }
        if (Test-Path -LiteralPath $Path) {
            $backupFile = "$Path.$(Get-Date -Format 'yyyyMMdd_HHmmss')_$unique.bak"
            [System.IO.File]::Replace($tempFile, $Path, $backupFile)
        }
        else {
            [System.IO.File]::Move($tempFile, $Path)
        }
        # Update state on success
        if ($Path -eq $script:ManifestPath) {
            $script:RunState.ManifestSaved = $true
        }
        # Retain only the five newest backups for this file.
        try {
            $backupPattern = [System.IO.Path]::GetFileName($Path) + '.*.bak'
            $backupDir = Split-Path -Parent $Path
            $oldBackups = @(Get-ChildItem -LiteralPath $backupDir -Filter $backupPattern -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -Skip 5)
            foreach ($oldBackup in $oldBackups) {
                Remove-Item -LiteralPath $oldBackup.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        catch { }
        return $true
    }
    catch {
        # Update state on failure
        if ($Path -eq $script:ManifestPath) {
            $script:RunState.ManifestSaved = $false
        }
        Write-Host "[ERROR] Atomic save failed for ${Path}: $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path -LiteralPath $Path) -or (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).Length -eq 0) {
            $bakFiles = Get-ChildItem -LiteralPath (Split-Path $Path -Parent) -Filter "$([System.IO.Path]::GetFileName($Path)).*.bak" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
            foreach ($bak in $bakFiles) {
                try {
                    $raw = [System.IO.File]::ReadAllText($bak.FullName, [System.Text.Encoding]::UTF8).Trim()
                    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                    # التحقق الصارم من صلاحية JSON قبل أي محاولة استعادة
                    $null = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
                    if ($Path -eq $script:ManifestPath) {
                        $tempData = if ($raw -eq '[]') { @() } else { $raw | ConvertFrom-Json -ErrorAction Stop }
                        if (-not (Test-ManifestSchema -Data $tempData)) { 
                            Write-Host "[WARNING] Backup $($bak.Name) failed schema validation. Skipping." -ForegroundColor Yellow
                            continue 
                        }
                    }
                    Copy-Item -LiteralPath $bak.FullName -Destination $Path -Force -ErrorAction Stop
                    Write-Host "[WARNING] Restored ${Path} from validated backup $($bak.Name)." -ForegroundColor Yellow
                    break # خروج من الحلقة عند نجاح الاستعادة
                }
                catch {
                    Write-Host "[WARNING] Backup $($bak.Name) is corrupted or invalid JSON. Skipping." -ForegroundColor Yellow
                }
            }
        }
        return $false
    }
}

function Save-Settings {
    param([string]$LogPath = "")
    $settings = @{ LogPath = $LogPath }
    return (Save-AtomicJson -Path $script:SettingsPath -Data $settings)
}

function Initialize-App {
    if (-not (Test-MaxRetriesConfig)) {
        Write-Host "[FATAL] MaxRetries configuration is invalid. It must be an integer between 0 and 10." -ForegroundColor Red
        exit 1
    }

    if (-not (Test-Path -LiteralPath $script:AppDir)) {
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
    }
    if ($script:RunState.PreviousInstanceCrashed) {
        Write-Host "[WARNING] Previous instance crashed. State files may be inconsistent." -ForegroundColor Yellow
    }
    
    $isValid = $false
    $loaded = $null
    if (Test-Path -LiteralPath $script:ManifestPath) {
        try {
            $raw = [System.IO.File]::ReadAllText($script:ManifestPath, [System.Text.Encoding]::UTF8).Trim()
            if ($raw -eq '[]') {
                $loaded = @()
                $isValid = $true
            }
            else {
                $loaded = $raw | ConvertFrom-Json -ErrorAction Stop
                $isValid = ($null -ne $loaded) -and (Test-ManifestSchema -Data $loaded)
            }
        }
        catch {
            $isValid = $false
        }
    }

    if (-not $isValid) {
        $bakFiles = Get-ChildItem -LiteralPath $script:AppDir -Filter "manifest.json.*.bak" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        $recovered = $false
        foreach ($bak in $bakFiles) {
            $restoreTemp = "$script:ManifestPath.restore_$([guid]::NewGuid().ToString('N')).tmp"
            try {
                Copy-Item -LiteralPath $bak.FullName -Destination $restoreTemp -Force -ErrorAction Stop
                $tempRaw = [System.IO.File]::ReadAllText($restoreTemp, [System.Text.Encoding]::UTF8).Trim()
                if ($tempRaw -eq '[]') {
                    $tempLoaded = @()
                }
                else {
                    $tempLoaded = $tempRaw | ConvertFrom-Json -ErrorAction Stop
                }
                if (Test-ManifestSchema -Data $tempLoaded) {
                    if (Test-Path -LiteralPath $script:ManifestPath) {
                        $corruptFile = "$script:ManifestPath.corrupted_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$([guid]::NewGuid().ToString('N')).json"
                        [System.IO.File]::Replace($restoreTemp, $script:ManifestPath, $corruptFile)
                    }
                    else {
                        Move-Item -LiteralPath $restoreTemp -Destination $script:ManifestPath -Force -ErrorAction Stop
                    }
                    $loaded = $tempLoaded
                    $recovered = $true
                    $isValid = $true
                    Write-Host "[WARNING] Recovered manifest atomically from validated backup: $($bak.Name)" -ForegroundColor Yellow
                    break
                }
                else {
                    Write-Host "[WARNING] Backup $($bak.Name) failed schema validation. Trying next..." -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host "[WARNING] Failed to process backup $($bak.Name): $($_.Exception.Message)" -ForegroundColor Yellow
                if (Test-Path -LiteralPath $restoreTemp) { Remove-Item -LiteralPath $restoreTemp -Force -ErrorAction SilentlyContinue }
            }
        }
        if (-not $recovered) {
            if (Test-Path -LiteralPath $script:ManifestPath) {
                Write-Host "[FATAL] Manifest schema invalid and no valid backup found. Quarantine manually." -ForegroundColor Red
                exit 1
            }
            else {
                $loaded = @()
                $isValid = $true
            }
        }
    }

    if ($isValid) {
        $arr = @($loaded)
        foreach ($entry in $arr) {
            $entry.Destination = [string]$entry.Destination
            $entry.VideoId = [string]$entry.VideoId
            $entry.OutputFilePath = [string]$entry.OutputFilePath
            $entry.MaxHeight = [int]$entry.MaxHeight
            $entry.Bitrate = [int]$entry.Bitrate
            $entry.AudioFormat = [string]$entry.AudioFormat
            $entry.Error = [string]$entry.Error
            
            # Migrate RetryCount for backward compatibility
            if ($null -eq $entry.RetryCount) {
                $entry | Add-Member -NotePropertyName RetryCount -NotePropertyValue 0
            }
            else {
                $parsedRetry = 0
                if ([int]::TryParse([string]$entry.RetryCount, [ref]$parsedRetry) -and $parsedRetry -ge 0 -and $parsedRetry -le $script:HistoricalMaxAttempts) {
                    $entry.RetryCount = $parsedRetry
                }
                else {
                    Write-Log "[WARNING] Invalid RetryCount ($($entry.RetryCount)) for $($entry.Id). Treating as exhausted." "Yellow"
                    $entry.RetryCount = $script:HistoricalMaxAttempts
                }
            }
            
            if ($null -eq $entry.PSObject.Properties['AttemptCount']) {
                $legacyAttempts = 0
                $retryVal = $entry.RetryCount
                if ($retryVal -ge $script:HistoricalMaxAttempts) {
                    $legacyAttempts = $script:HistoricalMaxAttempts
                }
                elseif ($entry.Status -eq 'Success') {
                    $legacyAttempts = [Math]::Max(1, $retryVal)
                }
                else {
                    $legacyAttempts = $retryVal
                }
                $entry | Add-Member -NotePropertyName AttemptCount -NotePropertyValue $legacyAttempts
            }
            else {
                $parsedAttempts = 0
                if ([int]::TryParse([string]$entry.AttemptCount, [ref]$parsedAttempts) -and $parsedAttempts -ge 0 -and $parsedAttempts -le $script:HistoricalMaxAttempts) {
                    $entry.AttemptCount = $parsedAttempts
                }
                else {
                    Write-Log "[WARNING] Invalid AttemptCount ($($entry.AttemptCount)) for $($entry.Id). Treating as exhausted." "Yellow"
                    $entry.AttemptCount = $script:HistoricalMaxAttempts
                }
            }
         
            # Normalize FailureKind and RetryDecision (warnings only for Invalid or FailedNone)
            $rawFK = if ($null -ne $entry.PSObject.Properties['FailureKind']) { $entry.FailureKind } else { $null }
            $rawRD = if ($null -ne $entry.PSObject.Properties['RetryDecision']) { $entry.RetryDecision } else { $null }
            $normalized = Normalize-FailureClassification -Status $entry.Status -FailureKind $rawFK -RetryDecision $rawRD
         
            if ($normalized.Reason -in @('Invalid', 'FailedNone')) {
                Write-Log "[WARNING] Item $($entry.Id): FailureKind/RetryDecision normalized to $($normalized.FailureKind)/$($normalized.RetryDecision) (Reason: $($normalized.Reason))" "Yellow"
            }
         
            if ($null -eq $entry.PSObject.Properties['FailureKind']) {
                $entry | Add-Member -NotePropertyName FailureKind -NotePropertyValue $normalized.FailureKind
            }
            else {
                $entry.FailureKind = $normalized.FailureKind
            }
         
            if ($null -eq $entry.PSObject.Properties['RetryDecision']) {
                $entry | Add-Member -NotePropertyName RetryDecision -NotePropertyValue $normalized.RetryDecision
            }
            else {
                $entry.RetryDecision = $normalized.RetryDecision
            }
        }
        $script:Manifest = $arr
    }
    else {
        $script:Manifest = @()
    }
    $script:StateInitialized = $true
}

function Set-ItemState {
    param(
        [PSCustomObject]$Item,
        [string]$Status,
        [Alias('Error')][string]$ErrorMessage = "",
        [AllowNull()][string]$OutputFilePath = $null,
        [AllowNull()][string]$VideoId = $null,
        [AllowNull()][string]$Destination = $null,
        [int]$RetryCount = -1,
        [int]$AttemptCount = -1,
        [string]$FailureKind = $null,
        [string]$RetryDecision = $null
    )
    if ($null -eq $Item -or [string]::IsNullOrWhiteSpace([string]$Item.Id)) { return $false }
    
    $manifestArr = @($script:Manifest)
    $idx = -1
    for ($i = 0; $i -lt $manifestArr.Count; $i++) {
        if ([string]$manifestArr[$i].Id -eq [string]$Item.Id) { $idx = $i; break }
    }
    if ($idx -lt 0) { return $false }
    
    $current = $manifestArr[$idx]
    $finalPath = if ($PSBoundParameters.ContainsKey('OutputFilePath')) { $OutputFilePath } else { $current.OutputFilePath }
    
    if ($Status -eq 'Success') {
        if ([string]::IsNullOrWhiteSpace([string]$finalPath)) {
            $script:RunState.VerificationsPassed = $false
            return $false
        }
        if (-not (Test-FileValidity -FilePath $finalPath -Mode $current.Mode)) {
            $script:RunState.VerificationsPassed = $false
            return $false
        }
    }
    
    $tempManifest = Copy-Manifest -Source $script:Manifest
    $target = $tempManifest[$idx]
    if ($null -eq $target) { return $false }
    $target.Status = $Status
    $target.Error = $ErrorMessage
    
    if ($PSBoundParameters.ContainsKey('OutputFilePath')) { $target.OutputFilePath = $OutputFilePath }
    if ($PSBoundParameters.ContainsKey('VideoId')) { $target.VideoId = $VideoId }
    if ($PSBoundParameters.ContainsKey('Destination')) { $target.Destination = $Destination }
    
    if ($PSBoundParameters.ContainsKey('RetryCount')) {
        if ($RetryCount -lt 0 -or $RetryCount -gt $script:HistoricalMaxAttempts) { return $false }
        $target.RetryCount = $RetryCount
    }
    if ($PSBoundParameters.ContainsKey('AttemptCount')) {
        if ($AttemptCount -lt 0 -or $AttemptCount -gt $script:HistoricalMaxAttempts) { return $false }
        $target.AttemptCount = $AttemptCount
    }
    # Reject non-canonical FailureKind/RetryDecision before any mutation or save
    if ($PSBoundParameters.ContainsKey('FailureKind') -and $FailureKind -cnotin $script:ValidFailureKinds) { return $false }
    if ($PSBoundParameters.ContainsKey('RetryDecision') -and $RetryDecision -cnotin $script:ValidRetryDecisions) { return $false }
    # Keep the retry counter consistent with attempts actually started.
    # Note: Enforcing the operational budget (MaxRetries) is the responsibility of Invoke-ItemDownload 
    # and Get-MaxAttempts. Set-ItemState only preserves history up to HistoricalMaxAttempts.
    if ($target.AttemptCount -gt 0) {
        $target.RetryCount = [Math]::Min($script:HistoricalMaxAttempts, $target.AttemptCount - 1)
    }
    else {
        $target.RetryCount = 0
    }
    # Determine FailureKind and RetryDecision based on Status and passed parameters
    $fkPassed = $PSBoundParameters.ContainsKey('FailureKind')
    $rdPassed = $PSBoundParameters.ContainsKey('RetryDecision')
    
    if ($Status -eq 'Success') {
        $target.FailureKind = 'None'; $target.RetryDecision = 'None'
    }
    elseif ($Status -in 'Pending', 'Downloading') {
        $target.FailureKind = 'None'; $target.RetryDecision = 'None'
    }
    elseif (-not $fkPassed -and -not $rdPassed) {
        if ($Status -eq 'Failed') {
            Write-Log "[WARNING] Failed without FailureKind/RetryDecision. Using Unknown/Retry" "Yellow"
            $target.FailureKind = 'Unknown'; $target.RetryDecision = 'Retry'
        }
        else {
            $target.FailureKind = 'None'; $target.RetryDecision = 'None'
        }
    }
    else {
        if ($fkPassed -xor $rdPassed) {
            Write-Log "[WARNING] Only one of FailureKind/RetryDecision passed. Filling the other with a safe default" "Yellow"
        }
        $target.FailureKind = if ($fkPassed) { $FailureKind }   else { 'Unknown' }
        $target.RetryDecision = if ($rdPassed) { $RetryDecision } else { 'Retry' }
        if ($Status -eq 'Failed' -and ($target.FailureKind -eq 'None' -or $target.RetryDecision -eq 'None')) {
            Write-Log "[WARNING] Failed + FailureKind=None. Normalizing to Unknown/Retry" "Yellow"
            $target.FailureKind = 'Unknown'; $target.RetryDecision = 'Retry'
        }
    }
    if (-not (Save-AtomicJson -Path $script:ManifestPath -Data $tempManifest)) {
        $script:RunState.ManifestSaved = $false
        return $false
    }
    
    # Mutate the existing object in place so references held by callers remain valid.
    $current.Status = $target.Status
    $current.Error = $target.Error
    $current.OutputFilePath = $target.OutputFilePath
    $current.VideoId = $target.VideoId
    $current.Destination = $target.Destination
    $current.RetryCount = $target.RetryCount
    $current.AttemptCount = $target.AttemptCount
    # Safely update FailureKind and RetryDecision (Add-Member needed for legacy items without these properties)
    if ($null -eq $current.PSObject.Properties['FailureKind']) {
        $current | Add-Member -NotePropertyName FailureKind -NotePropertyValue $target.FailureKind -Force
    }
    else {
        $current.FailureKind = $target.FailureKind
    }
    if ($null -eq $current.PSObject.Properties['RetryDecision']) {
        $current | Add-Member -NotePropertyName RetryDecision -NotePropertyValue $target.RetryDecision -Force
    }
    else {
        $current.RetryDecision = $target.RetryDecision
    }
    $Item.Status = $target.Status
    $Item.Error = $target.Error
    $Item.OutputFilePath = $target.OutputFilePath
    $Item.VideoId = $target.VideoId
    $Item.Destination = $target.Destination
    $Item.RetryCount = $target.RetryCount
    $Item.AttemptCount = $target.AttemptCount
    if ($null -eq $Item.PSObject.Properties['FailureKind']) {
        $Item | Add-Member -NotePropertyName FailureKind -NotePropertyValue $target.FailureKind -Force
    }
    else {
        $Item.FailureKind = $target.FailureKind
    }
    if ($null -eq $Item.PSObject.Properties['RetryDecision']) {
        $Item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue $target.RetryDecision -Force
    }
    else {
        $Item.RetryDecision = $target.RetryDecision
    }
    return $true
}

#==============================================================================
# Logging & Core Helpers
#==============================================================================
function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] $Message"
    Write-Host $logLine -ForegroundColor $Color
    if ($script:CurrentLogPath) {
        $logDir = Split-Path $script:CurrentLogPath -Parent
        if (Test-Path -LiteralPath $logDir) {
            try { Add-Content -LiteralPath $script:CurrentLogPath -Value $logLine -Encoding UTF8 }
            catch { $script:RunState.LogsWritten = $false }
        }
        else { $script:RunState.LogsWritten = $false }
    }
}

function Test-Dependencies {
    $missing = @()
    if (-not (Get-Command yt-dlp -ErrorAction SilentlyContinue)) { $missing += "yt-dlp" }
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $missing += "ffmpeg" }
    if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) { $missing += "ffprobe" }
    if ($missing.Count -gt 0) { Write-Log "[ERROR] Missing dependencies: $($missing -join ', ')" "Red"; return $false }
    return $true
}

function Get-VideoId {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    try {
        $uri = $null
        if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) { return $null }
        if ($uri.Scheme -notin @('http', 'https')) { return $null }
        if (-not [string]::IsNullOrEmpty($uri.UserInfo)) { return $null }
        if (-not $uri.IsDefaultPort) { return $null }

        $validHosts = @('youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com', 'youtu.be')
        if ($uri.Host -notin $validHosts) { return $null }

        $id = $null
        if ($uri.Host -eq 'youtu.be') {
            $path = $uri.AbsolutePath.Trim('/')
            if ($path -match '^([a-zA-Z0-9_-]{11})$') { $id = $matches[1] }
        }
        elseif ($uri.AbsolutePath -eq '/watch') {
            foreach ($part in ($uri.Query.TrimStart('?') -split '&')) {
                $pair = $part -split '=', 2
                if ($pair.Count -eq 2 -and $pair[0] -eq 'v') {
                    if ($pair[1] -match '^([a-zA-Z0-9_-]{11})$') { $id = $matches[1] }
                    break
                }
            }
        }
        elseif ($uri.AbsolutePath -match '^/(?:embed|shorts|live|v)/([a-zA-Z0-9_-]{11})/?$') {
            $id = $matches[1]
        }
        return $id
    }
    catch { return $null }
}

function Get-ValidDestination {
    param([string]$DefaultPath)
    while ($true) {
        $dest = Read-Host "Enter destination folder (Default: $DefaultPath)"
        if ([string]::IsNullOrWhiteSpace($dest)) { $dest = $DefaultPath }
        $dest = [Environment]::ExpandEnvironmentVariables($dest)
        try { $dest = [System.IO.Path]::GetFullPath($dest) }
        catch { Write-Log "[ERROR] Invalid path format." "Red"; continue }

        if (Test-Path -LiteralPath $dest) {
            $item = Get-Item -LiteralPath $dest -ErrorAction SilentlyContinue
            if ($item -and $item.PSIsContainer -eq $false) {
                Write-Log "[ERROR] Destination exists but is a file, not a folder." "Red"
                continue
            }
        }
        else {
            try { New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop | Out-Null } 
            catch { Write-Log "[ERROR] Cannot create directory: $dest" "Red"; continue }
        }

        $testFile = Join-Path $dest ".write_test_$([guid]::NewGuid().ToString())"
        $writable = $false
        try {
            [IO.File]::WriteAllText($testFile, "test")
            $writable = $true
        }
        catch {
            Write-Log "[ERROR] Destination is not writable: $dest" "Red"
        }
        finally {
            if (Test-Path -LiteralPath $testFile) {
                Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
            }
        }
        if ($writable) { return $dest }
    }
}

function Test-FileValidity {
    param([string]$FilePath, [string]$Mode)
    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath)) { return $false }
    $f = Get-Item -LiteralPath $FilePath -ErrorAction SilentlyContinue
    if (-not $f -or $f.PSIsContainer -or $f.Length -le 0) { return $false }
    if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) { return $false }

    $probeArgs = @("-v", "error", "-show_entries", "format=duration:stream=codec_type", "-of", "json", $FilePath)
    $raw = & ffprobe @probeArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }

    $jsonText = $raw -join [Environment]::NewLine
    try { $data = $jsonText | ConvertFrom-Json -ErrorAction Stop } catch { return $false }
    if (-not $data.streams) { return $false }

    $duration = 0.0
    if ($data.format -and $data.format.duration) {
        $parsed = [double]::TryParse([string]$data.format.duration, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$duration)
        if (-not $parsed -or [double]::IsNaN($duration) -or [double]::IsInfinity($duration) -or $duration -le 0) { return $false }
    }
    else { return $false }

    $types = @($data.streams | ForEach-Object { $_.codec_type })
    if ($Mode -eq "Video") { return ($types -contains "video") }
    if ($Mode -eq "Audio") { return ($types -contains "audio") }
    return $false
}

#==============================================================================
# Menu & Prompts
#==============================================================================
function Show-MainMenu {
    Clear-Host
    Write-Log "========================================" "Cyan"
    Write-Log "   YouTube Downloader CLI (yt-dlp)" "Cyan"
    Write-Log "========================================" "Cyan"
    Write-Host "1. Download entire YouTube playlist (Videos)"
    Write-Host "2. Download one YouTube video"
    Write-Host "3. Download audio only (One video)"
    Write-Host "4. Download multiple individual URLs (Mixed settings)"
    Write-Host "5. Download audio only (Multiple URLs)"
    Write-Host "6. Retry failed / interrupted downloads"
    Write-Host "7. View current run log"
    Write-Host "8. Exit"
    Write-Log "========================================" "Cyan"
}

function Select-VideoQuality {
    Write-Host "`nSelect Maximum Video Quality:"
    Write-Host "1. 144p   2. 240p   3. 360p   4. 480p"
    Write-Host "5. 720p   6. 1080p  7. 1440p  8. 2160p (4K)"
    Write-Host "9. Best available quality"
    while ($true) {
        $c = Read-Host "Enter choice (1-9)"
        switch ($c) {
            "1" { return 144 }  "2" { return 240 }  "3" { return 360 }  "4" { return 480 }
            "5" { return 720 }  "6" { return 1080 } "7" { return 1440 } "8" { return 2160 }
            "9" { return 0 }
            default { Write-Log "Invalid choice." "Red" }
        }
    }
}

function Select-AudioFormat {
    Write-Host "`nSelect Audio Format:"
    Write-Host "1. MP3 (Re-encoded)   2. M4A (Remux/Convert)   3. Best original"
    while ($true) {
        $c = Read-Host "Enter choice (1-3)"
        switch ($c) { "1" { return "MP3" } "2" { return "M4A" } "3" { return "Best" } default { Write-Log "Invalid." "Red" } }
    }
}

function Select-Mp3Bitrate {
    Write-Host "`nSelect MP3 Bitrate: 1. 128k  2. 192k  3. 320k"
    while ($true) {
        $c = Read-Host "Enter choice (1-3)"
        switch ($c) { "1" { return 128 } "2" { return 192 } "3" { return 320 } default { Write-Log "Invalid." "Red" } }
    }
}

function Get-UrlsFromInput {
    param([string]$Prompt)
    Write-Log $Prompt "Cyan"
    Write-Log "Enter URLs one per line, or a path to a UTF-8 text file. Type 'DONE' when finished." "Gray"
    $urls = @()
    $firstLine = (Read-Host "URL / File Path").Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($firstLine) -or $firstLine -eq 'DONE') { return , $urls }

    if (Test-Path -LiteralPath $firstLine -PathType Leaf -ErrorAction SilentlyContinue) {
        foreach ($line in (Get-Content -LiteralPath $firstLine -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $candidate = ([string]$line).Trim().Trim('"').Trim("'")
            if (Get-VideoId -Url $candidate) { $urls += $candidate }
            elseif (-not [string]::IsNullOrWhiteSpace($candidate)) { Write-Log "Skipping invalid YouTube URL: $candidate" "Yellow" }
        }
    }
    else {
        if (Get-VideoId -Url $firstLine) { $urls += $firstLine }
        else { Write-Log "The first entry is not a valid YouTube URL or readable file path." "Yellow" }
        while ($true) {
            $line = (Read-Host "URL (or 'DONE')").Trim().Trim('"').Trim("'")
            if ($line -eq "DONE") { break }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if (Get-VideoId -Url $line) { $urls += $line }
            else { Write-Log "Skipping invalid YouTube URL: $line" "Yellow" }
        }
    }
    return , $urls
}

#==============================================================================
# Core Execution & Verification
#==============================================================================
function Get-PlaylistUrls {
    param([string]$Url)
    Write-Log "Extracting playlist URLs..." "Cyan"
    $jsonStr = & yt-dlp --flat-playlist -J $Url 2>$null
    $jsonText = $jsonStr -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($jsonText)) { return $null }
    try { $data = $jsonText | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    $urls = @()

    if ($data.entries) {
        foreach ($entry in $data.entries) {
            $vidUrl = $null
            # 1. Try entry.url first
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.url)) {
                $candidate = [string]$entry.url
                if ($candidate -match '^https?://') { $vidUrl = $candidate }
                elseif ($candidate -match '^/') { $vidUrl = "https://www.youtube.com$candidate" }
                # Invalidate if URL doesn't yield a valid video ID
                if ($vidUrl -and -not (Get-VideoId -Url $vidUrl)) {
                    $vidUrl = $null
                }
            }
            # 2. Fallback to entry.id if URL is missing or invalid
            if (-not $vidUrl -and [string]$entry.id -match '^[a-zA-Z0-9_-]{11}$') {
                $vidUrl = "https://www.youtube.com/watch?v=$($entry.id)"
            }
            if ($vidUrl) { $urls += $vidUrl }
        }
    }
    return $urls
}

function Test-IdInArchive {
    param([string]$ArchivePath, [string]$VideoId)
    if ([string]::IsNullOrWhiteSpace($ArchivePath) -or [string]::IsNullOrWhiteSpace($VideoId)) { return @{ Status = 'InvalidInput' } }
    $acquired = $false
    try {
        if ($null -eq $script:ArchiveMutex) {
            $acquired = $true
        }
        else {
            try {
                $acquired = $script:ArchiveMutex.WaitOne(5000)
            }
            catch [System.Threading.AbandonedMutexException] {
                $acquired = $true
            }
        }
        if (-not $acquired) { return @{ Status = 'ReadError' } }

        # نقل فحص وجود الملف إلى داخل القفل لمنع سباق التزامن (Race Condition)
        if (-not (Test-Path -LiteralPath $ArchivePath)) { 
            return @{ Status = 'NotFound' } 
        }

        $fs = [System.IO.File]::Open($ArchivePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            while ($null -ne ($line = $sr.ReadLine())) {
                $parts = $line -split '\s+' | Where-Object { $_ -ne '' }
                if ($parts.Count -ge 2 -and $parts[1] -ceq $VideoId) { return @{ Status = 'Found' } }
            }
        }
        finally { 
            $fs.Dispose() 
        }
    }
    catch { 
        return @{ Status = 'ReadError' } 
    }
    finally { 
        if ($acquired -and $null -ne $script:ArchiveMutex) { 
            try { $script:ArchiveMutex.ReleaseMutex() } catch {} 
        } 
    }
    return @{ Status = 'NotFound' }
}

function Remove-VideoIdFromArchive {
    param([string]$ArchivePath, [string]$VideoId)
    if ([string]::IsNullOrWhiteSpace($ArchivePath) -or [string]::IsNullOrWhiteSpace($VideoId)) { return $false }
    $acquired = $false
    $tempFile = $null
    try {
        if ($null -eq $script:ArchiveMutex) {
            $acquired = $true
        }
        else {
            try {
                $acquired = $script:ArchiveMutex.WaitOne(5000)
            }
            catch [System.Threading.AbandonedMutexException] {
                $acquired = $true
            }
        }
        if (-not $acquired) { return $false }

        # FIX: Check existence AFTER acquiring lock to avoid race conditions
        if (-not (Test-Path -LiteralPath $ArchivePath)) { return $true }

        $unique = [guid]::NewGuid().ToString("N")
        $tempFile = "$ArchivePath.$unique.tmp"
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $lines = [System.IO.File]::ReadAllLines($ArchivePath, [System.Text.Encoding]::UTF8)
        $kept = New-Object System.Collections.Generic.List[string]
        foreach ($line in $lines) {
            $parts = $line -split '\s+' | Where-Object { $_ -ne '' }
            if (-not ($parts.Count -ge 2 -and $parts[1] -ceq $VideoId)) { $kept.Add($line) }
        }
        $archiveText = if ($kept.Count -gt 0) { ($kept -join "`r`n") + "`r`n" } else { "" }
        [System.IO.File]::WriteAllText($tempFile, $archiveText, $encoding)

        $bak = "$ArchivePath.$(Get-Date -Format 'yyyyMMdd_HHmmss')_$unique.bak"
        [System.IO.File]::Replace($tempFile, $ArchivePath, $bak)

        $after = [System.IO.File]::ReadAllLines($ArchivePath, [System.Text.Encoding]::UTF8)
        foreach ($line in $after) {
            $parts = $line -split '\s+' | Where-Object { $_ -ne '' }
            if ($parts.Count -ge 2 -and $parts[1] -ceq $VideoId) { return $false }
        }
        return $true
    }
    catch {
        Write-Log "Archive cleanup failed: $($_.Exception.Message)" "Red"
        if (-not [string]::IsNullOrWhiteSpace([string]$tempFile) -and (Test-Path -LiteralPath $tempFile)) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
    finally { 
        if ($acquired -and $null -ne $script:ArchiveMutex) { 
            try { $script:ArchiveMutex.ReleaseMutex() } catch {} 
        } 
    }
}

function Add-CapturedLine {
    param(
        [System.Collections.Generic.Queue[string]]$Queue,
        [AllowNull()][object]$Line,
        [int]$Cap = 200
    )
    if ($null -eq $Line) { return }
    $s = "$Line"
    if ([string]::IsNullOrWhiteSpace($s)) { return }
    if ($s -match '(?i)(ERROR|WARNING):|yt-dlp(\.exe)?:\s*error:') {
        if ($s.Length -gt 1000) { $s = $s.Substring(0, 1000) }
        [void]$Queue.Enqueue($s)
        while ($Queue.Count -gt $Cap) {
            [void]$Queue.Dequeue()
        }
    }
}

function Test-FfprobeAvailable {
    return [bool](Get-Command ffprobe -ErrorAction SilentlyContinue)
}

function Get-VerdictFailureClass {
    param(
        [Parameter(Mandatory)][ValidateSet('Corrupt', 'QuarantineFailed', 'OtherMode', 'Unknown', 'NoOutput')][string]$Outcome,
        [ValidateSet('A', 'C')][string]$Case = 'A',
        [bool]$FfprobeAvailable = $true
    )
    switch ($Outcome) {
        'Corrupt' { return @{ FailureKind = 'Transient'; RetryDecision = 'Retry' } }
        'QuarantineFailed' { return @{ FailureKind = 'Unknown'; RetryDecision = 'Retry' } }
        'NoOutput' { return @{ FailureKind = 'Unknown'; RetryDecision = 'Retry' } }
        'OtherMode' {
            if ($Case -eq 'A') { return @{ FailureKind = 'Configuration'; RetryDecision = 'Stop' } }
            else { return @{ FailureKind = 'Unknown'; RetryDecision = 'Retry' } }
        }
        'Unknown' {
            if (-not $FfprobeAvailable) { return @{ FailureKind = 'Configuration'; RetryDecision = 'Stop' } }
            else { return @{ FailureKind = 'Unknown'; RetryDecision = 'Retry' } }
        }
    }
    return @{ FailureKind = 'Unknown'; RetryDecision = 'Retry' }
}

function Stop-ItemEarly {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Item,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$FailureKind,
        [Parameter(Mandatory)][int]$AttemptNumber,
        [Parameter(Mandatory)][int]$MaxAttempts
    )
    $errMsg = "$Reason; retry skipped (FailureKind=$FailureKind, attempt $AttemptNumber/$MaxAttempts)"
    if (-not (Set-ItemState -Item $Item -Status 'Failed' -Error $errMsg -FailureKind $FailureKind -RetryDecision 'Stop')) {
        Write-Log "CRITICAL: Failed to persist early stop state for $($Item.Url)." "Red"
    }
    Write-Log "FAILED: $($Item.Url) - retry skipped (FailureKind=$FailureKind, attempt $AttemptNumber/$MaxAttempts)." "Red"
    return $false
}

function Invoke-ItemDownload {
    param([PSCustomObject]$Item)
    if ($null -eq $Item) { return $false }

    $maxAttempts = Get-MaxAttempts

    if ([string]::IsNullOrWhiteSpace($Item.Destination)) {
        [void](Set-ItemState -Item $Item -Status "Failed" -Error "No destination configured" -FailureKind 'Configuration' -RetryDecision 'Stop')
        return $false
    }
    $dest = $Item.Destination
    try { $dest = [System.IO.Path]::GetFullPath($dest) } catch {
        [void](Set-ItemState -Item $Item -Status "Failed" -Error "Invalid destination path" -FailureKind 'Configuration' -RetryDecision 'Stop')
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($Item.OutputFilePath) -and $Item.Mode -in @('Video', 'Audio')) {
        $existingVerdict = Get-FileVerdict -FilePath $Item.OutputFilePath -Mode $Item.Mode
        if ($existingVerdict -and $existingVerdict.Verdict -eq 'Valid') {
            if (-not (Set-ItemState -Item $Item -Status "Success" -Error "Verified existing output")) { return $false }
            return $true
        }
    }

    $expectedId = Get-VideoId -Url $Item.Url
    if ([string]::IsNullOrWhiteSpace($expectedId)) {
        [void](Set-ItemState -Item $Item -Status "Failed" -Error "Cannot extract video id" -FailureKind 'Permanent' -RetryDecision 'Stop')
        return $false
    }

    $archive = if ($Item.Mode -eq "Audio") { $script:AudioArchive } else { $script:VideoArchive }
    $downloadSucceeded = $false
    $ytExitCode = -1
    $workingId = $expectedId
    $actualPath = ""
    $lastSpecificError = ""
    $attemptFK='Unknown'; $attemptRD='Retry'; $attemptReason='unclassified' 

    while ([int]$Item.AttemptCount -lt $maxAttempts -and -not $downloadSucceeded) {
        $attemptNumber = [int]$Item.AttemptCount + 1
        $retryNumber = [Math]::Max(0, $attemptNumber - 1)
        $attemptFK = 'Unknown'; $attemptRD = 'Retry'; $attemptReason = 'unclassified'
        $capture = New-Object 'System.Collections.Generic.Queue[string]'
        # Persist the attempt before invoking yt-dlp. A crash can therefore never silently reset the budget.
        if (-not (Set-ItemState -Item $Item -Status "Downloading" -Error "" -RetryCount $retryNumber -AttemptCount $attemptNumber)) {
            Write-Log "Cannot persist attempt state; aborting this item." "Red"
            return $false
        }

        Write-Log "Download attempt $attemptNumber of $maxAttempts for $($Item.Url)" "Cyan"

        $idFile = $null
        $pathFile = $null
        $ytExitCode = -1
        $actualPath = ""
        $actualId = ""
        $lastSpecificError = ""
        try {
            $idFile = [System.IO.Path]::GetTempFileName()
            $pathFile = [System.IO.Path]::GetTempFileName()
            $outTemplate = Join-Path $dest "%(title).100s_%(id)s.%(ext)s"
            $ytArgs = @($Item.Url, "-o", $outTemplate, "--download-archive", $archive, "--no-playlist", "--retries", "5", "--retry-sleep", "http:exp=1:20", "--retry-sleep", "fragment:exp=1:20", "--retry-sleep", "extractor:exp=1:20", "--abort-on-unavailable-fragments", "--windows-filenames", "--no-progress", "--print-to-file", "id", $idFile, "--print-to-file", "after_move:filepath", $pathFile)
            
            if ($Item.Mode -eq "Audio") {
                $ytArgs += @("-f", "bestaudio")
                switch ($Item.AudioFormat) {
                    "MP3" { $ytArgs += @("-x", "--audio-format", "mp3", "--audio-quality", "$($Item.Bitrate)k") }
                    "M4A" { $ytArgs += @("-x", "--audio-format", "m4a") }
                }
            }
            else {
                if ($Item.MaxHeight -eq 0) { $ytArgs += @("-f", "bestvideo+bestaudio/best") }
                else { $ytArgs += @("-f", "bestvideo[height<=$($Item.MaxHeight)]+bestaudio/best[height<=$($Item.MaxHeight)]") }
            }

            $oldCaptureEAP = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $global:LASTEXITCODE = $null
                & yt-dlp @ytArgs 2>&1 | ForEach-Object {
                    $s = "$_"
                    Write-Host $s
                    Add-CapturedLine -Queue $capture -Line $s
                } | Out-Null
                $ytExitCode = if ($null -eq $LASTEXITCODE) { -1 } else { $LASTEXITCODE }
            } finally {
                $ErrorActionPreference = $oldCaptureEAP
            }
            if (Test-Path -LiteralPath $idFile) { $actualId = ([System.IO.File]::ReadAllText($idFile)).Trim() }
            if (Test-Path -LiteralPath $pathFile) { $actualPath = ([System.IO.File]::ReadAllText($pathFile)).Trim() }
        }
        catch [System.Management.Automation.CommandNotFoundException] {
            Write-Log "yt-dlp not found" "Red"
            $ytExitCode = -1
            $attemptFK = 'Configuration'; $attemptRD = 'Stop'; $attemptReason = 'yt-dlp not found'
        }
        catch {
            Write-Log "yt-dlp execution threw an exception: $($_.Exception.Message)" "Red"
            $ytExitCode = -1
        }
        finally {
            foreach ($tempPath in @($idFile, $pathFile)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$tempPath)) {
                    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
        if ($ytExitCode -ne 0 -and $attemptReason -ne 'yt-dlp not found') {
            $r = Get-FailureKind -ExitCode $ytExitCode -ErrorText @($capture)
            $attemptFK = $r.FailureKind
            $attemptRD = $r.RetryDecision
            $attemptReason = "yt-dlp exit code ${ytExitCode}: $($r.Reason)"
            if ($r.Evidence) { Write-Log "Evidence: $($r.Evidence)" "DarkGray" }
        }
        if (-not [string]::IsNullOrWhiteSpace($actualId)) { $workingId = $actualId }
        if (-not [string]::IsNullOrWhiteSpace($actualPath)) {
            try { $actualPath = [System.IO.Path]::GetFullPath($actualPath) } catch { $actualPath = "" }
        }

        if (-not [string]::IsNullOrWhiteSpace($actualPath)) {
            $verdict = Get-FileVerdict -FilePath $actualPath -Mode $Item.Mode
         
            if ($verdict.Verdict -eq 'Valid' -and $ytExitCode -eq 0) {
                $downloadSucceeded = $true
                break
            }
         
            if ($verdict.Verdict -eq 'Corrupt') {
                $moveResult = Move-ToInvalid -FilePath $actualPath -Directory $dest
                if ($moveResult.Success) {
                    if ($ytExitCode -eq 0) {
                        if (-not (Remove-VideoIdFromArchive -ArchivePath $archive -VideoId $workingId)) {
                            $lastSpecificError = "archive cleanup failed (file isolated to $($moveResult.NewPath))"
                            Write-Log "Archive cleanup failed after isolation: $($moveResult.NewPath). Halting immediately." "Red"
                            if (-not (Set-ItemState -Item $Item -Status "Failed" -Error $lastSpecificError -FailureKind 'Unknown' -RetryDecision 'Stop')) {
                                Write-Log "CRITICAL: Failed to persist failure state for $($Item.Url)." "Red"
                            }
                            return $false
                        }
                        else {
                            $lastSpecificError = "file was corrupt and isolated to $($moveResult.NewPath)"
                        }
                    }
                    else {
                        $lastSpecificError = "file was corrupt and isolated to $($moveResult.NewPath)"
                    }
                    $vc = Get-VerdictFailureClass -Outcome Corrupt -Case A
                    if ($attemptRD -ne 'Stop') { $attemptFK = $vc.FailureKind; $attemptRD = $vc.RetryDecision; $attemptReason = $lastSpecificError }
                }
                else {
                    $lastSpecificError = "quarantine failed: $($moveResult.Error)"
                    $vc = Get-VerdictFailureClass -Outcome QuarantineFailed -Case A
                    if ($attemptRD -ne 'Stop') { $attemptFK = $vc.FailureKind; $attemptRD = $vc.RetryDecision; $attemptReason = $lastSpecificError }
                }
            }
            elseif ($ytExitCode -eq 0 -and $verdict.Verdict -eq 'Unknown') {
                $lastSpecificError = "verdict Unknown: $($verdict.Reason)"
                $ffprobe = Test-FfprobeAvailable
                $vc = Get-VerdictFailureClass -Outcome Unknown -Case A -FfprobeAvailable $ffprobe
                if ($attemptRD -ne 'Stop') { $attemptFK = $vc.FailureKind; $attemptRD = $vc.RetryDecision; $attemptReason = $lastSpecificError }
            }
            elseif ($ytExitCode -eq 0 -and $verdict.Verdict -eq 'OtherMode') {
                $lastSpecificError = "verdict OtherMode: $($verdict.Reason)"
                $vc = Get-VerdictFailureClass -Outcome OtherMode -Case A
                if ($attemptRD -ne 'Stop') { $attemptFK = $vc.FailureKind; $attemptRD = $vc.RetryDecision; $attemptReason = $lastSpecificError }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($lastSpecificError)) {
            Write-Log "Attempt $attemptNumber failed: $lastSpecificError" "Red"
            $reason = if ($attemptReason -ne $lastSpecificError -and -not [string]::IsNullOrWhiteSpace($attemptReason)) { "$attemptReason; $lastSpecificError" } else { $lastSpecificError }
            Write-Log "[Retry] FailureKind: $attemptFK. Decision: $attemptRD. Reason: $reason" "Yellow"
            if ($attemptRD -eq 'Stop' -and $attemptNumber -lt $maxAttempts) {
                return (Stop-ItemEarly -Item $Item -Reason $reason -FailureKind $attemptFK -AttemptNumber $attemptNumber -MaxAttempts $maxAttempts)
            }
            if ([int]$Item.AttemptCount -lt $maxAttempts) {
                if (-not (Set-ItemState -Item $Item -Status "Pending" -Error $lastSpecificError -RetryCount $retryNumber -AttemptCount $attemptNumber)) {
                    Write-Log "Cannot persist retry state; aborting this item." "Red"
                    return $false
                }
                Write-Log "Attempt $attemptNumber failed. Waiting before retry..." "Yellow"
                Start-Sleep -Seconds ([Math]::Min(2 * $attemptNumber, 10))
            }
            continue
        }

        # yt-dlp may return success without a filepath when the item is already in the archive.
        if ($ytExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($actualPath)) {
            $archiveCheck = Test-IdInArchive -ArchivePath $archive -VideoId $workingId
            if ($archiveCheck.Status -eq 'ReadError') {
                [void](Set-ItemState -Item $Item -Status "Failed" -Error "Archive read error" -FailureKind 'Unknown' -RetryDecision 'Stop')
                return $false
            }
            if ($archiveCheck.Status -eq 'Found') {
                $candidates = @(Find-OutputCandidates -Directory $dest -VideoId $workingId -Mode $Item.Mode)
             
                $validCandidates = @($candidates | Where-Object { $_.Verdict -eq 'Valid' })
                $unknownCandidates = @($candidates | Where-Object { $_.Verdict -eq 'Unknown' })
                $corruptCandidates = @($candidates | Where-Object { $_.Verdict -eq 'Corrupt' })
                $otherModeCandidates = @($candidates | Where-Object { $_.Verdict -eq 'OtherMode' })
             
                # Rule 1: Valid exists - accept without isolation
                if ($validCandidates.Count -gt 0) {
                    # Find the newest file by LastWriteTimeUtc, breaking ties by Ordinal name comparison
                    $chosen = $null
                    foreach ($c in $validCandidates) {
                        if ($null -eq $chosen) {
                            $chosen = $c
                            continue
                        }
                        $timeCmp = $c.File.LastWriteTimeUtc.CompareTo($chosen.File.LastWriteTimeUtc)
                        if ($timeCmp -gt 0) {
                            $chosen = $c
                        }
                        elseif ($timeCmp -eq 0) {
                            # Break ties using Ordinal comparison (smaller name wins)
                            if ([System.StringComparer]::Ordinal.Compare($c.File.Name, $chosen.File.Name) -lt 0) {
                                $chosen = $c
                            }
                        }
                    }
                    $actualPath = $chosen.File.FullName
                    Write-Log "Found valid output for ${workingId}: $($chosen.File.Name)" "Cyan"
                    $downloadSucceeded = $true
                    break
                }
             
                # Rule 2: Unknown has priority - no isolation, no archive modification
                if ($unknownCandidates.Count -gt 0) {
                    $lastSpecificError = "verdict Unknown: $($unknownCandidates[0].Reason)"
                    $ffprobe = Test-FfprobeAvailable
                    $vc = Get-VerdictFailureClass -Outcome Unknown -Case C -FfprobeAvailable $ffprobe
                    if ($attemptRD -ne 'Stop') { $attemptFK = $vc.FailureKind; $attemptRD = $vc.RetryDecision; $attemptReason = $lastSpecificError }
                }
                # Rule 3: Corrupt exists - isolate all, then remove ID
                # Note: If isolation of the second file fails, the first file remains isolated.
                # The archive is NOT modified in this case (per policy).
                elseif ($corruptCandidates.Count -gt 0) {
                    $isolationFailed = $false
                    $firstIsolatedPath = $null
                    foreach ($c in $corruptCandidates) {
                        $moveResult = Move-ToInvalid -FilePath $c.File.FullName -Directory $dest
                        if (-not $moveResult.Success) {
                            $lastSpecificError = "quarantine failed: $($moveResult.Error)"
                            $vc = Get-VerdictFailureClass -Outcome QuarantineFailed -Case C
                            if ($attemptRD -ne 'Stop') { $attemptFK = $vc.FailureKind; $attemptRD = $vc.RetryDecision; $attemptReason = $lastSpecificError }
                            $isolationFailed = $true
                            break
                        }
                        if ($null -eq $firstIsolatedPath) { $firstIsolatedPath = $moveResult.NewPath }
                    }
                    if (-not $isolationFailed) {
                        if (-not (Remove-VideoIdFromArchive -ArchivePath $archive -VideoId $workingId)) {
                            $lastSpecificError = "archive cleanup failed (file isolated to $firstIsolatedPath)"
                            Write-Log "Archive cleanup failed after isolation: $firstIsolatedPath. Halting immediately." "Red"
                            if (-not (Set-ItemState -Item $Item -Status "Failed" -Error $lastSpecificError -FailureKind 'Unknown' -RetryDecision 'Stop')) {
                                Write-Log "CRITICAL: Failed to persist failure state for $($Item.Url)." "Red"
                            }
                            return $false
                        }
                        $lastSpecificError = "file was corrupt and isolated to $firstIsolatedPath"
                        $vc = Get-VerdictFailureClass -Outcome Corrupt -Case C
                        if ($attemptRD -ne 'Stop') { $attemptFK = $vc.FailureKind; $attemptRD = $vc.RetryDecision; $attemptReason = $lastSpecificError }
                    }
                }
                # Rule 4: OtherMode only or no candidates - remove ID, no isolation
                else {
                    if (-not (Remove-VideoIdFromArchive -ArchivePath $archive -VideoId $workingId)) {
                        $lastSpecificError = "Archive cleanup failed"
                        Write-Log "Archive cleanup failed. Halting immediately." "Red"
                        if (-not (Set-ItemState -Item $Item -Status "Failed" -Error $lastSpecificError -FailureKind 'Unknown' -RetryDecision 'Stop')) {
                            Write-Log "CRITICAL: Failed to persist failure state for $($Item.Url)." "Red"
                        }
                        return $false
                    }
                    if ($otherModeCandidates.Count -gt 0) {
                        $names = ($otherModeCandidates | ForEach-Object { $_.File.Name }) -join ', '
                        $lastSpecificError = "no valid $($Item.Mode) output (only other-mode files: $names)"
                        $vc = Get-VerdictFailureClass -Outcome OtherMode -Case C
                    }
                    else {
                        $lastSpecificError = "no valid $($Item.Mode) output found"
                        $vc = Get-VerdictFailureClass -Outcome NoOutput -Case C
                    }
                    if ($attemptRD -ne 'Stop') { $attemptFK = $vc.FailureKind; $attemptRD = $vc.RetryDecision; $attemptReason = $lastSpecificError }
                }
             
                # Handle retryable failure for rules 2, 3 (isolation failed), 4
                if (-not [string]::IsNullOrWhiteSpace($lastSpecificError)) {
                    Write-Log "Archive branch failed: $lastSpecificError" "Red"
                    $reason = if ($attemptReason -ne $lastSpecificError -and -not [string]::IsNullOrWhiteSpace($attemptReason)) { "$attemptReason; $lastSpecificError" } else { $lastSpecificError }
                    Write-Log "[Retry] FailureKind: $attemptFK. Decision: $attemptRD. Reason: $reason" "Yellow"
                    if ($attemptRD -eq 'Stop' -and $attemptNumber -lt $maxAttempts) {
                        return (Stop-ItemEarly -Item $Item -Reason $reason -FailureKind $attemptFK -AttemptNumber $attemptNumber -MaxAttempts $maxAttempts)
                    }
                    if ([int]$Item.AttemptCount -lt $maxAttempts) {
                        if (-not (Set-ItemState -Item $Item -Status "Pending" -Error $lastSpecificError -RetryCount $retryNumber -AttemptCount $attemptNumber)) {
                            Write-Log "Cannot persist retry state; aborting this item." "Red"
                            return $false
                        }
                        Write-Log "Attempt $attemptNumber failed. Waiting before retry..." "Yellow"
                        Start-Sleep -Seconds ([Math]::Min(2 * $attemptNumber, 10))
                    }
                    continue
                }
            }
        }

        Write-Log "[Retry] FailureKind: $attemptFK. Decision: $attemptRD. Reason: $attemptReason" "Yellow"
        if ($attemptRD -eq 'Stop' -and $attemptNumber -lt $maxAttempts) {
            return (Stop-ItemEarly -Item $Item -Reason $attemptReason -FailureKind $attemptFK -AttemptNumber $attemptNumber -MaxAttempts $maxAttempts)
        }
        if ([int]$Item.AttemptCount -lt $maxAttempts) {
            if (-not (Set-ItemState -Item $Item -Status "Pending" -Error "Attempt $attemptNumber failed; retry available")) {
                Write-Log "Cannot persist retry state; aborting this item." "Red"
                return $false
            }
            if ([int]$Item.AttemptCount -lt $maxAttempts) {
                Write-Log "Attempt $attemptNumber failed. Waiting before retry..." "Yellow"
                Start-Sleep -Seconds ([Math]::Min(2 * $attemptNumber, 10))
            }
        }
    }

    if ($downloadSucceeded) {
        if (-not (Set-ItemState -Item $Item -Status "Success" -Error "" -OutputFilePath $actualPath -VideoId $workingId)) { return $false }
        return $true
    }

    $finalError = if (-not [string]::IsNullOrWhiteSpace($lastSpecificError)) { "$lastSpecificError; attempt budget $([int]$Item.AttemptCount)/$maxAttempts exhausted" } else { "yt-dlp exit code $ytExitCode; attempt budget $([int]$Item.AttemptCount)/$maxAttempts exhausted" }
    if (-not (Set-ItemState -Item $Item -Status "Failed" -Error $finalError -FailureKind $attemptFK -RetryDecision $attemptRD)) {
        Write-Log "CRITICAL: Failed to persist final failure state for $($Item.Url)." "Red"
    }

    Write-Log "FAILED: $($Item.Url) - attempt budget exhausted ($([int]$Item.AttemptCount)/$maxAttempts)." "Red"
    return $false
}

function Start-DownloadRun {
    param([PSCustomObject[]]$Items, [bool]$IsResume = $false)
    $script:CurrentRunItems = @($Items)

    if (-not $script:RunState.ManifestSaved) {
        Write-Log "CRITICAL: Manifest state is out of sync with disk. Forcing save before run." "Red"
        if (-not (Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest)) {
            Write-Log "CRITICAL: Forced save failed. Aborting run to prevent data loss." "Red"
            return
        }
    }

    $script:RunState.DownloadsCompleted = $true; $script:RunState.VerificationsPassed = $true
    $script:RunState.ManifestSaved = $true; $script:RunState.SettingsSaved = $true
    $script:RunState.LogsWritten = $true; $script:RunState.Interrupted = $false

    $logDir = Join-Path $script:AppDir "Logs"
    $hibernate = $false
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null }
        $logFile = Join-Path $logDir ("Run_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
        $script:CurrentLogPath = $logFile

        if (-not (Save-Settings -LogPath $logFile)) { 
            $script:RunState.SettingsSaved = $false
            Write-Log "CRITICAL: Failed to save settings. Aborting run." "Red"
            return 
        }

        if (-not $IsResume) {
            $defaultDest = Join-Path $env:USERPROFILE "Videos\YouTube"
            $dest = Get-ValidDestination -DefaultPath $defaultDest
            $hibernate = ((Read-Host "`nHibernate after success? (Y/N)") -eq 'Y')
            foreach ($it in $Items) {
                if ([string]::IsNullOrWhiteSpace($it.Destination)) {
                    if (-not (Set-ItemState -Item $it -Status $it.Status -Destination $dest)) { 
                        Write-Log "CRITICAL: Failed to set initial destination. Aborting." "Red"
                        return 
                    }
                }
            }
        }
        else {
            $missingDest = $Items | Where-Object { [string]::IsNullOrWhiteSpace($_.Destination) }
            if ($missingDest) {
                $dest = Get-ValidDestination -DefaultPath (Join-Path $env:USERPROFILE "Videos\YouTube")
                foreach ($it in $missingDest) {
                    if (-not (Set-ItemState -Item $it -Status $it.Status -Destination $dest)) { 
                        Write-Log "CRITICAL: Failed to set resume destination. Aborting." "Red"
                        return 
                    }
                }
            }
        }

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $item = $Items[$i]
            if ($item.Status -eq "Success") {
                if (-not (Test-FileValidity -FilePath $item.OutputFilePath -Mode $item.Mode)) {
                    if (-not (Set-ItemState -Item $item -Status "Pending" -Error "File invalid/missing" -OutputFilePath "")) { 
                        Write-Log "CRITICAL: Failed to revert invalid Success state. Halting." "Red"
                        $script:RunState.DownloadsCompleted = $false
                        break 
                    }
                }
                else { continue }
            }

            if (-not (Invoke-ItemDownload -Item $item)) {
                $script:RunState.DownloadsCompleted = $false; $script:RunState.VerificationsPassed = $false
                if (-not $script:RunState.ManifestSaved) { 
                    Write-Log "CRITICAL: State persistence failed. Halting remaining items." "Red"
                    break 
                }
            }
        }
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        $script:RunState.Interrupted = $true; $script:RunState.DownloadsCompleted = $false
    }
    catch {
        Write-Log "ERROR in download run: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" "Red"
        $script:RunState.Interrupted = $true; $script:RunState.DownloadsCompleted = $false
    }
    finally {
        if ($script:StateInitialized -and $script:RunState.ManifestSaved) {
            $finalManifest = Copy-Manifest $script:Manifest
            $needsSave = $false
            # هذا الجزء كان مفقوداً وهو المسؤول عن حساب قيمة $needsSave
            foreach ($item in $finalManifest) {
                if ($item.Status -eq 'Downloading') { 
                    $item.Status = 'Failed'
                    $item.Error = 'Interrupted'
                    $item.FailureKind = 'Unknown'
                    $item.RetryDecision = 'Retry'
                    $needsSave = $true 
                }
            }
            if ($needsSave) {
                $script:RunState.ManifestSaved = $false # تعيين افتراضي للفشل للأمان
                try {
                    if (Save-AtomicJson -Path $script:ManifestPath -Data $finalManifest) {
                        $script:RunState.ManifestSaved = $true
                        $script:Manifest = $finalManifest
                    }
                }
                catch {
                    $script:RunState.ManifestSaved = $false
                    Write-Log "CRITICAL: Exception during final manifest save: $($_.Exception.Message)" "Red"
                }
            }
        }
        $script:CurrentLogPath = ""
    }
    if (Test-HibernateEligibility -Requested $hibernate) { Invoke-Hibernation }
}

function Test-HibernateEligibility {
    param([bool]$Requested)
    if (-not $Requested) { return $false }
    if (-not $script:RunState.ManifestSaved -or -not $script:RunState.SettingsSaved -or -not $script:RunState.LogsWritten) { return $false }
    if ($script:RunState.Interrupted -or -not $script:StateInitialized -or $script:RunState.PreviousInstanceCrashed) { return $false }
    if (-not $script:RunState.DownloadsCompleted -or -not $script:RunState.VerificationsPassed) { return $false }

    $itemsToVerify = @($script:CurrentRunItems)
    if ($itemsToVerify.Count -eq 0) { $itemsToVerify = @($script:Manifest) }
    foreach ($entry in $itemsToVerify) {
        if ($entry.Status -ne "Success" -or [string]::IsNullOrWhiteSpace($entry.OutputFilePath)) { return $false }
        if (-not (Test-FileValidity -FilePath $entry.OutputFilePath -Mode $entry.Mode)) { return $false }
    }
    return $true
}

function Invoke-Hibernation {
    if (-not (Test-HibernateEligibility -Requested $true)) { return }
    $hibEnabled = $false
    try {
        $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
        $powerSettings = Get-ItemProperty -LiteralPath $powerKey -Name 'HibernateEnabled' -ErrorAction Stop
        $hibEnabled = ([int]$powerSettings.HibernateEnabled -eq 1)
    }
    catch {
        $hibEnabled = $false
    }

    if ($hibEnabled) {
        Write-Log "Initiating hibernation in 5 seconds..." "Cyan"
        Start-Sleep -Seconds 5
        if (-not (Test-HibernateEligibility -Requested $true)) { 
            Write-Log "Hibernate eligibility lost during countdown. Aborting." "Yellow"
            return 
        }
        if (-not $script:RunState.LogsWritten) { return }
        try {
            $proc = Start-Process -FilePath "shutdown.exe" -ArgumentList "/h" -Wait -PassThru -NoNewWindow -ErrorAction Stop
            if ($proc.ExitCode -ne 0) { Write-Log "Hibernate command failed." "Red" }
        }
        catch { Write-Log "Failed to invoke shutdown.exe" "Red" }
    }
    else { Write-Log "Hibernation not supported." "Yellow" }
}

#==============================================================================
# Main Application Loop
#==============================================================================
function Main {
    if (-not (Test-Dependencies)) { Read-Host "Press Enter to exit"; exit 1 }
    while ($true) {
        Show-MainMenu
        $choice = Read-Host "`nSelect an option (1-8)"
        $itemsToRun = @(); $isResume = $false
        switch ($choice) {
            "1" {
                $urls = Get-PlaylistUrls -Url (Read-Host "Enter Playlist URL")
                if (-not $urls -or @($urls).Count -eq 0) { Write-Log "No valid video URLs were found in the playlist." "Yellow"; Read-Host "Press Enter"; continue }
                $quality = Select-VideoQuality
                $newItems = @()
                foreach ($u in $urls) {
                    $newItems += [PSCustomObject]@{ 
                        Id = [guid]::NewGuid().ToString(); Url = $u; VideoId = ""; Mode = "Video"; MaxHeight = $quality; 
                        AudioFormat = ""; Bitrate = 0; Destination = ""; Status = "Pending"; Error = ""; OutputFilePath = ""; RetryCount = 0; AttemptCount=0 ; FailureKind='None'; RetryDecision='None'
                    }
                }
                $tempManifest = Copy-Manifest $script:Manifest
                $tempManifest += $newItems
                if (Save-AtomicJson -Path $script:ManifestPath -Data $tempManifest) {
                    $script:Manifest = $tempManifest
                    $itemsToRun += $newItems
                }
                else { 
                    $script:RunState.ManifestSaved = $false
                    Write-Log "Failed to save manifest. Items discarded." "Red" 
                    continue
                }
            }
            "2" {
                $url = (Read-Host "Enter Video URL").Trim()
                if (-not (Get-VideoId -Url $url)) { Write-Log "Invalid YouTube URL." "Red"; Read-Host "Press Enter"; continue }
                $quality = Select-VideoQuality
                $newItem = [PSCustomObject]@{ 
                    Id = [guid]::NewGuid().ToString(); Url = $url; VideoId = ""; Mode = "Video"; MaxHeight = $quality; 
                    AudioFormat = ""; Bitrate = 0; Destination = ""; Status = "Pending"; Error = ""; OutputFilePath = ""; RetryCount = 0; AttemptCount=0 ; FailureKind='None'; RetryDecision='None'
                }
                $tempManifest = Copy-Manifest $script:Manifest
                $tempManifest += $newItem
                if (Save-AtomicJson -Path $script:ManifestPath -Data $tempManifest) {
                    $script:Manifest = $tempManifest; $itemsToRun += $newItem
                }
                else { 
                    $script:RunState.ManifestSaved = $false
                    Write-Log "Failed to save manifest. Item discarded." "Red" 
                    continue
                }
            }
            "3" {
                $url = (Read-Host "Enter Video URL").Trim()
                if (-not (Get-VideoId -Url $url)) { Write-Log "Invalid YouTube URL." "Red"; Read-Host "Press Enter"; continue }
                $fmt = Select-AudioFormat
                $br = 128; if ($fmt -eq "MP3") { $br = Select-Mp3Bitrate }
                $newItem = [PSCustomObject]@{ 
                    Id = [guid]::NewGuid().ToString(); Url = $url; VideoId = ""; Mode = "Audio"; MaxHeight = 0; AudioFormat = $fmt; 
                    Bitrate = $br; Destination = ""; Status = "Pending"; Error = ""; OutputFilePath = ""; RetryCount = 0; AttemptCount=0 ; FailureKind='None'; RetryDecision='None'
                }
                $tempManifest = Copy-Manifest $script:Manifest
                $tempManifest += $newItem
                if (Save-AtomicJson -Path $script:ManifestPath -Data $tempManifest) {
                    $script:Manifest = $tempManifest; $itemsToRun += $newItem
                }
                else { 
                    $script:RunState.ManifestSaved = $false
                    Write-Log "Failed to save manifest. Item discarded." "Red" 
                    continue
                }
            }
            "4" {
                $urls = Get-UrlsFromInput "Enter URLs:"
                if ($urls.Count -eq 0) { continue }
                $newItems = @()
                foreach ($u in $urls) {
                    $type = Read-Host "Video (V) or Audio (A) for $u ?"
                    if ($type -eq 'A') {
                        $fmt = Select-AudioFormat; $br = 128; if ($fmt -eq "MP3") { $br = Select-Mp3Bitrate }
                        $newItems += [PSCustomObject]@{ 
                            Id = [guid]::NewGuid().ToString(); Url = $u; VideoId = ""; Mode = "Audio"; MaxHeight = 0; AudioFormat = $fmt; 
                            Bitrate = $br; Destination = ""; Status = "Pending"; Error = ""; OutputFilePath = ""; RetryCount = 0; AttemptCount=0 ; FailureKind='None'; RetryDecision='None'
                        }
                    }
                    else {
                        $newItems += [PSCustomObject]@{ 
                            Id = [guid]::NewGuid().ToString(); Url = $u; VideoId = ""; Mode = "Video"; MaxHeight = (Select-VideoQuality); 
                            AudioFormat = ""; Bitrate = 0; Destination = ""; Status = "Pending"; Error = ""; OutputFilePath = ""; RetryCount = 0; AttemptCount=0 ; FailureKind='None'; RetryDecision='None'
                        }
                    }
                }
                $tempManifest = Copy-Manifest $script:Manifest
                $tempManifest += $newItems
                if (Save-AtomicJson -Path $script:ManifestPath -Data $tempManifest) {
                    $script:Manifest = $tempManifest; $itemsToRun += $newItems
                }
                else { 
                    $script:RunState.ManifestSaved = $false
                    Write-Log "Failed to save manifest. Items discarded." "Red" 
                    continue
                }
            }
            "5" {
                $urls = Get-UrlsFromInput "Enter URLs:"
                if ($urls.Count -eq 0) { continue }
                $fmt = Select-AudioFormat; $br = 128; if ($fmt -eq "MP3") { $br = Select-Mp3Bitrate }
                $newItems = @()
                foreach ($u in $urls) {
                    $newItems += [PSCustomObject]@{ 
                        Id = [guid]::NewGuid().ToString(); Url = $u; VideoId = ""; Mode = "Audio"; MaxHeight = 0; AudioFormat = $fmt; 
                        Bitrate = $br; Destination = ""; Status = "Pending"; Error = ""; OutputFilePath = ""; RetryCount = 0; AttemptCount=0 ; FailureKind='None'; RetryDecision='None'
                    }
                }
                $tempManifest = Copy-Manifest $script:Manifest
                $tempManifest += $newItems
                if (Save-AtomicJson -Path $script:ManifestPath -Data $tempManifest) {
                    $script:Manifest = $tempManifest; $itemsToRun += $newItems
                }
                else { 
                    $script:RunState.ManifestSaved = $false
                    Write-Log "Failed to save manifest. Items discarded." "Red" 
                    continue
                }
            }
            "6" {
                $plan = Invoke-RetryPlanFlow
                if (-not $plan) { continue }

                if (Save-AtomicJson -Path $script:ManifestPath -Data $plan.ModifiedManifest) {
                    $script:Manifest = $plan.ModifiedManifest
                    $itemsToRun = $plan.ItemsToRun
                    $isResume = $true
                }
                else {
                    $script:RunState.ManifestSaved = $false
                    Write-Log "Failed to persist resume state atomically. Aborting Option 6." "Red"
                    continue
                }
            }
            "7" {
                if (Test-Path -LiteralPath $script:SettingsPath) {
                    try {
                        $s = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
                        if ($s.LogPath -and (Test-Path -LiteralPath $s.LogPath)) { Get-Content -LiteralPath $s.LogPath | More }
                    }
                    catch {}
                }
                Read-Host "Press Enter"
            }
            "8" { exit 0 }
        }
        if ($itemsToRun.Count -gt 0) {
            Start-DownloadRun -Items $itemsToRun -IsResume $isResume
            Read-Host "Press Enter to return to the menu"
        }
    }
}

#==============================================================================
# Safe Execution Guard for Main Loop
#==============================================================================
if ($script:RunAsMain) {
    try {
        Initialize-App
        Main
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        $script:RunState.Interrupted = $true
    }
    catch {
        Write-Host "[ERROR] Unhandled script error: $($_.Exception.Message)" -ForegroundColor Red
        $script:RunState.Interrupted = $true
    }
    finally {
        if ($script:StateInitialized -and $script:RunState.ManifestSaved) {
            $finalManifest = Copy-Manifest $script:Manifest
            $needsSave = $false
            foreach ($item in $finalManifest) {
                if ($item.Status -eq 'Downloading') {
                    $item.Status = 'Failed'; $item.Error = 'Global interrupt'
                    $item.FailureKind = 'Unknown'
                    $item.RetryDecision = 'Retry'
                    $needsSave = $true
                }
            }
            if ($needsSave) {
                try {
                    if (Save-AtomicJson -Path $script:ManifestPath -Data $finalManifest) {
                        $script:Manifest = $finalManifest
                    }
                    else {
                        $script:RunState.ManifestSaved = $false
                        Write-Host "[ERROR] Final manifest save failed; in-memory state was not promoted." -ForegroundColor Red
                    }
                }
                catch {
                    $script:RunState.ManifestSaved = $false
                    Write-Host "[ERROR] Exception during final manifest save: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        if ($script:MainMutex) { try { $script:MainMutex.ReleaseMutex() } catch {}; $script:MainMutex.Dispose() }
        if ($script:ArchiveMutex) { $script:ArchiveMutex.Dispose() }
    }
}
