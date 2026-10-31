#Requires -Modules Pester
# YT-Downloader.Tests.ps1

BeforeAll {
    # 1. عزل البيئة تماماً عن بيانات المستخدم الحقيقية
    $script:OrigAppData = $env:APPDATA
    $env:APPDATA = $TestDrive
    
    # إنشاء مجلدات وهمية
    $script:AppDir = Join-Path $env:APPDATA "YT-DL-CLI"
    New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:AppDir "Logs") -Force | Out-Null
    
    # 2. إنشاء Stubs آمنة للأوامر الخارجية (كاحتياط، لكن Mocks هي التي ستتحكم)
    $stubDir = Join-Path $TestDrive "stubs"
    New-Item -ItemType Directory -Path $stubDir -Force | Out-Null
    
    Set-Content -Path (Join-Path $stubDir "yt-dlp.ps1") -Value @'
param([string]$Url)
if ($global:MockYtDlpExitCode -is [int]) {
    $global:LASTEXITCODE = $global:MockYtDlpExitCode
} else {
    $global:LASTEXITCODE = 0
}
if ($global:LASTEXITCODE -eq 0) {
    $idx1 = [Array]::IndexOf($args, '--print-to-file')
    if ($idx1 -ge 0 -and ($idx1 + 2) -lt $args.Count) {
        "MockVideoId123" | Out-File -FilePath $args[$idx1 + 2] -Encoding UTF8
    }
    $idx2 = [Array]::IndexOf($args, '--print-to-file', $idx1 + 1)
    if ($idx2 -ge 0 -and ($idx2 + 2) -lt $args.Count) {
        "C:\Mock\Path\video.mp4" | Out-File -FilePath $args[$idx2 + 2] -Encoding UTF8
    }
}
'@

    Set-Content -Path (Join-Path $stubDir "ffprobe.ps1") -Value @'
$global:LASTEXITCODE = 0
'{"format":{"duration":"10.0"},"streams":[{"codec_type":"video"}]}'
'@

    Set-Content -Path (Join-Path $stubDir "ffmpeg.ps1") -Value '$global:LASTEXITCODE = 0'

    # 3. تعديل PATH مؤقتاً
    $script:OrigPath = $env:PATH
    $env:PATH = "$stubDir;$env:PATH"

    # 4. تحميل السكريبت (Dot-sourcing) قبل أي Mocks للدوال الداخلية لتجنب أخطاء Pester
    . "$PSScriptRoot\YT-Downloader.ps1"

    # 5. Mocks لوظائف النظام
    Mock Start-Sleep { }
    Mock Read-Host { return "1" }
    Mock Start-Process { return @{ ExitCode = 0 } }
}

AfterAll {
    $env:APPDATA = $script:OrigAppData
    $env:PATH = $script:OrigPath
}

Describe "Phase 1: Configuration and Schema Validation" {
    BeforeEach {
        $script:Config.MaxRetries = 3
    }

    It "Calculates correct max attempts for valid MaxRetries" {
        $script:Config.MaxRetries = 0; (Get-MaxAttempts) | Should -Be 1
        $script:Config.MaxRetries = 3; (Get-MaxAttempts) | Should -Be 4
        $script:Config.MaxRetries = 10; (Get-MaxAttempts) | Should -Be 11
    }

    It "Rejects invalid MaxRetries values strictly" {
        Test-MaxRetriesConfig -Value -1 | Should -BeFalse
        Test-MaxRetriesConfig -Value 3.5 | Should -BeFalse
        Test-MaxRetriesConfig -Value "3" | Should -BeFalse
        Test-MaxRetriesConfig -Value 11 | Should -BeFalse
        Test-MaxRetriesConfig -Value $null | Should -BeFalse
        Test-MaxRetriesConfig -Value 0 | Should -BeTrue
        Test-MaxRetriesConfig -Value 3 | Should -BeTrue
        Test-MaxRetriesConfig -Value 10 | Should -BeTrue
    }

    It "Exits with code 1 on invalid MaxRetries (Child Process Test)" {
        $testDrivePath = $TestDrive
        $scriptPath = Join-Path $PSScriptRoot "YT-Downloader.ps1"
        $scriptBlock = @"
`$env:APPDATA = '$testDrivePath'
. '$scriptPath'
`$script:Config.MaxRetries = 'invalid'
Initialize-App
"@
        $result = & powershell.exe -NoProfile -Command $scriptBlock 2>&1
        $result | Should -Match "FATAL"
        $LASTEXITCODE | Should -Be 1
    }
}

Describe "Phase 1: Manifest History and Migration" {
    BeforeEach {
        $script:Config.MaxRetries = 3
        $manifestPath = Join-Path $script:AppDir "manifest.json"
        if (Test-Path $manifestPath) { Remove-Item $manifestPath -Force }
    }

    It "Tolerates AttemptCount = 5 when MaxRetries = 3, treats as exhausted, and Get-RetryPlan resets it" {
        $guid = [guid]::NewGuid().ToString()
        $manifest = @([PSCustomObject]@{
            Id=$guid; Url="https://youtube.com/watch?v=12345678901"; Mode="Video"; MaxHeight=720; 
            AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Failed"; Error=""; OutputFilePath=""; VideoId="12345678901";
            RetryCount=3; AttemptCount=5
        })
        Save-AtomicJson -Path (Join-Path $script:AppDir "manifest.json") -Data $manifest
        Initialize-App
        $script:Manifest[0].AttemptCount | Should -Be 5
        ([int]$script:Manifest[0].AttemptCount -lt (Get-MaxAttempts)) | Should -BeFalse
        
        $plan = Get-RetryPlan
        $plan.ItemsToRun.Count | Should -Be 1
        $plan.ItemsToRun[0].AttemptCount | Should -Be 0
    }

    It "Preserves history when changing MaxRetries from 3 to 5 and back" {
        $guid = [guid]::NewGuid().ToString()
        $manifest = @([PSCustomObject]@{
            Id=$guid; Url="https://youtube.com/watch?v=12345678901"; Mode="Video"; MaxHeight=720; 
            AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Failed"; Error=""; OutputFilePath=""; VideoId="12345678901";
            RetryCount=2; AttemptCount=3
        })
        Save-AtomicJson -Path (Join-Path $script:AppDir "manifest.json") -Data $manifest
        
        $script:Config.MaxRetries = 5
        Initialize-App
        $script:Manifest[0].AttemptCount | Should -Be 3
        
        $script:Config.MaxRetries = 3
        Initialize-App
        $script:Manifest[0].AttemptCount | Should -Be 3
    }

    It "Migrates old elements missing AttemptCount and RetryCount with actual values" {
        $guid = [guid]::NewGuid().ToString()
        $manifest = @([PSCustomObject]@{
            Id=$guid; Url="https://youtube.com/watch?v=12345678901"; Mode="Video"; MaxHeight=720; 
            AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Failed"; Error=""; OutputFilePath=""; VideoId="12345678901"
        })
        Save-AtomicJson -Path (Join-Path $script:AppDir "manifest.json") -Data $manifest
        Initialize-App
        $script:Manifest[0].AttemptCount | Should -Be 0
        $script:Manifest[0].RetryCount | Should -Be 0
    }

    It "Corrupt AttemptCount/RetryCount becomes exhausted (HistoricalMaxAttempts)" {
        $guid = [guid]::NewGuid().ToString()
        $manifest = @([PSCustomObject]@{
            Id=$guid; Url="https://youtube.com/watch?v=12345678901"; Mode="Video"; MaxHeight=720; 
            AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Failed"; Error=""; OutputFilePath=""; VideoId="12345678901";
            RetryCount="invalid"; AttemptCount="invalid"
        })
        $res = Copy-Manifest -Source $manifest
        $res[0].AttemptCount | Should -Be $script:HistoricalMaxAttempts
        $res[0].RetryCount | Should -Be $script:HistoricalMaxAttempts
    }
}

Describe "Phase 1: Execution and State Logic" {
    BeforeEach {
        $script:Config.MaxRetries = 3
        $global:MockYtDlpExitCode = 0
        
        # Mock مركزي لـ yt-dlp يتحكم فيه الاختبار
        Mock yt-dlp {
            param([string]$Url)
            $global:LASTEXITCODE = $global:MockYtDlpExitCode
            
            if ($global:LASTEXITCODE -eq 0) {
                $idx1 = [Array]::IndexOf($args, '--print-to-file')
                if ($idx1 -ge 0 -and ($idx1 + 2) -lt $args.Count) {
                    "MockVideoId123" | Out-File -FilePath $args[$idx1 + 2] -Encoding UTF8
                }
                $idx2 = [Array]::IndexOf($args, '--print-to-file', $idx1 + 1)
                if ($idx2 -ge 0 -and ($idx2 + 2) -lt $args.Count) {
                    "C:\Mock\Path\video.mp4" | Out-File -FilePath $args[$idx2 + 2] -Encoding UTF8
                }
            }
        }
        Mock Test-FileValidity { return $true }
    }

    It "Exhausted element does not start new download (yt-dlp not invoked)" {
        $guid = [guid]::NewGuid().ToString()
        $item = [PSCustomObject]@{
            Id=$guid; Url="https://youtube.com/watch?v=12345678901"; Mode="Video"; MaxHeight=720; 
            AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Failed"; Error=""; OutputFilePath=""; VideoId="12345678901";
            RetryCount=3; AttemptCount=4
        }
        $script:Manifest = @($item)
        Save-AtomicJson -Path (Join-Path $script:AppDir "manifest.json") -Data $script:Manifest
        
        $result = Invoke-ItemDownload -Item $item
        $result | Should -BeFalse
        $item.Status | Should -Be "Failed"
        Should -Invoke -CommandName yt-dlp -Times 0
    }

    It "Failure results in exactly 4 calls to yt-dlp (MaxRetries=3)" {
        $global:MockYtDlpExitCode = 1 # Force failure
        $guid = [guid]::NewGuid().ToString()
        $item = [PSCustomObject]@{
            Id=$guid; Url="https://youtube.com/watch?v=12345678901"; Mode="Video"; MaxHeight=720; 
            AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Pending"; Error=""; OutputFilePath=""; VideoId="12345678901";
            RetryCount=0; AttemptCount=0
        }
        $script:Manifest = @($item)
        Save-AtomicJson -Path (Join-Path $script:AppDir "manifest.json") -Data $script:Manifest
        
        Invoke-ItemDownload -Item $item | Should -BeFalse
        Should -Invoke -CommandName yt-dlp -Times 4 -Exactly
        $item.AttemptCount | Should -Be 4
    }

    It "Success on attempt 2 stops the loop" {
        $script:callCount = 0
        Mock yt-dlp { 
            param([string]$Url)
            $script:callCount++
            if ($script:callCount -eq 1) { 
                $global:LASTEXITCODE = 1 
            } else { 
                $global:LASTEXITCODE = 0 
                $idx1 = [Array]::IndexOf($args, '--print-to-file')
                if ($idx1 -ge 0 -and ($idx1 + 2) -lt $args.Count) {
                    "MockVideoId123" | Out-File -FilePath $args[$idx1 + 2] -Encoding UTF8
                }
                $idx2 = [Array]::IndexOf($args, '--print-to-file', $idx1 + 1)
                if ($idx2 -ge 0 -and ($idx2 + 2) -lt $args.Count) {
                    "C:\Mock\Path\video.mp4" | Out-File -FilePath $args[$idx2 + 2] -Encoding UTF8
                }
            }
        }
        
        $guid = [guid]::NewGuid().ToString()
        $item = [PSCustomObject]@{
            Id=$guid; Url="https://youtube.com/watch?v=12345678901"; Mode="Video"; MaxHeight=720; 
            AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Pending"; Error=""; OutputFilePath=""; VideoId="12345678901";
            RetryCount=0; AttemptCount=0
        }
        $script:Manifest = @($item)
        Save-AtomicJson -Path (Join-Path $script:AppDir "manifest.json") -Data $script:Manifest
        
        Invoke-ItemDownload -Item $item | Should -BeTrue
        Should -Invoke -CommandName yt-dlp -Times 2 -Exactly
        $item.Status | Should -Be "Success"
    }

    It "AttemptCount is saved BEFORE yt-dlp is invoked" {
        $global:MockYtDlpExitCode = 0
        $guid = [guid]::NewGuid().ToString()
        $item = [PSCustomObject]@{
            Id=$guid; Url="https://youtube.com/watch?v=12345678901"; Mode="Video"; MaxHeight=720; 
            AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Pending"; Error=""; OutputFilePath=""; VideoId="12345678901";
            RetryCount=0; AttemptCount=0
        }
        $script:Manifest = @($item)
        Save-AtomicJson -Path (Join-Path $script:AppDir "manifest.json") -Data $script:Manifest

        $script:testGuid = $guid
        $script:savedAttemptAtCall = $null
        Mock yt-dlp {
            param([string]$Url)
            $global:LASTEXITCODE = 0
            $m = Get-Content -LiteralPath (Join-Path $script:AppDir "manifest.json") -Raw | ConvertFrom-Json
            $script:savedAttemptAtCall = (@($m) | Where-Object { $_.Id -eq $script:testGuid }).AttemptCount
            $idx1 = [Array]::IndexOf($args, '--print-to-file')
            if ($idx1 -ge 0) { "MockVideoId123" | Out-File -FilePath $args[$idx1 + 2] -Encoding UTF8 }
            $idx2 = [Array]::IndexOf($args, '--print-to-file', $idx1 + 1)
            if ($idx2 -ge 0) { "C:\Mock\Path\video.mp4" | Out-File -FilePath $args[$idx2 + 2] -Encoding UTF8 }
        }

        Invoke-ItemDownload -Item $item | Should -BeTrue
        Should -Invoke -CommandName yt-dlp -Times 1 -Exactly
        $script:savedAttemptAtCall | Should -Be 1
    }

    It "Save failure prevents download" {
        Mock Save-AtomicJson { return $false }
        $guid = [guid]::NewGuid().ToString()
        $item = [PSCustomObject]@{
            Id=$guid; Url="https://youtube.com/watch?v=12345678901"; Mode="Video"; MaxHeight=720; 
            AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Pending"; Error=""; OutputFilePath=""; VideoId="12345678901";
            RetryCount=0; AttemptCount=0
        }
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeFalse
        Should -Invoke -CommandName yt-dlp -Times 0
    }

    It "Copy-Manifest handles 0, 1, and multiple elements" {
        $res0 = Copy-Manifest -Source @()
        $res0.Count | Should -Be 0
        
        $guid1 = [guid]::NewGuid().ToString()
        $item1 = [PSCustomObject]@{ Id=$guid1; Url="https://youtube.com/watch?v=12345678901"; Mode="Video"; MaxHeight=0; AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Pending"; Error=""; VideoId="12345678901"; OutputFilePath=""; RetryCount=0; AttemptCount=0 }
        $res1 = Copy-Manifest -Source @($item1)
        $res1.Count | Should -Be 1
        
        $guid2 = [guid]::NewGuid().ToString()
        $item2 = [PSCustomObject]@{ Id=$guid2; Url="https://youtube.com/watch?v=12345678902"; Mode="Video"; MaxHeight=0; AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Pending"; Error=""; VideoId="12345678902"; OutputFilePath=""; RetryCount=0; AttemptCount=0 }
        $res2 = Copy-Manifest -Source @($item1, $item2)
        $res2.Count | Should -Be 2
    }

    It "Saving one element does not change another's counters" {
        $guid1 = [guid]::NewGuid().ToString()
        $guid2 = [guid]::NewGuid().ToString()
        $item1 = [PSCustomObject]@{ Id=$guid1; Url="https://youtube.com/watch?v=12345678901"; Mode="Video"; MaxHeight=0; AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Pending"; Error=""; VideoId="12345678901"; OutputFilePath=""; RetryCount=0; AttemptCount=0 }
        $item2 = [PSCustomObject]@{ Id=$guid2; Url="https://youtube.com/watch?v=12345678902"; Mode="Video"; MaxHeight=0; AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Pending"; Error=""; VideoId="12345678902"; OutputFilePath=""; RetryCount=2; AttemptCount=3 }
        $script:Manifest = @($item1, $item2)
        Save-AtomicJson -Path (Join-Path $script:AppDir "manifest.json") -Data $script:Manifest
        
        Set-ItemState -Item $item1 -Status "Downloading" -AttemptCount 1 -RetryCount 0
        $script:Manifest[1].AttemptCount | Should -Be 3
        $script:Manifest[1].RetryCount | Should -Be 2
    }
}

Describe "Phase 1: Get-RetryPlan Logic" {
    BeforeEach {
        $script:Config.MaxRetries = 3
    }

    It "Resets counters ONLY if AttemptCount >= MaxAttempts" {
        $guid1 = [guid]::NewGuid().ToString()
        $guid2 = [guid]::NewGuid().ToString()
        $manifest = @(
            [PSCustomObject]@{ Id=$guid1; Url="https://youtube.com/watch?v=11111111111"; Mode="Video"; MaxHeight=720; AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Failed"; Error=""; OutputFilePath=""; VideoId="11111111111"; RetryCount=3; AttemptCount=4 },
            [PSCustomObject]@{ Id=$guid2; Url="https://youtube.com/watch?v=22222222222"; Mode="Video"; MaxHeight=720; AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Failed"; Error=""; OutputFilePath=""; VideoId="22222222222"; RetryCount=1; AttemptCount=2 }
        )
        
        $plan = Get-RetryPlan -Manifest $manifest
        
        $exhaustedItem = $plan.ItemsToRun | Where-Object { $_.Id -eq $guid1 }
        $eligibleItem = $plan.ItemsToRun | Where-Object { $_.Id -eq $guid2 }
        
        $exhaustedItem.AttemptCount | Should -Be 0
        $exhaustedItem.RetryCount | Should -Be 0
        
        $eligibleItem.AttemptCount | Should -Be 2
        $eligibleItem.RetryCount | Should -Be 1
    }

    It 'Does not save or touch $script:Manifest' {
        $guid = [guid]::NewGuid().ToString()
        $originalManifest = @(
            [PSCustomObject]@{ Id=$guid; Url="https://youtube.com/watch?v=12345678901"; Mode="Video"; MaxHeight=720; AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Failed"; Error=""; OutputFilePath=""; VideoId="12345678901"; RetryCount=3; AttemptCount=4 }
        )
        $script:Manifest = $originalManifest
        
        Mock Save-AtomicJson { throw "Should not be called" }
        
        $plan = Get-RetryPlan
        $plan.ItemsToRun.Count | Should -Be 1
        $script:Manifest[0].AttemptCount | Should -Be 4 # Unchanged
    }

    It "Includes Success with invalid file, excludes Success with valid file" {
        $guid1 = [guid]::NewGuid().ToString()
        $guid2 = [guid]::NewGuid().ToString()
        $manifest = @(
            [PSCustomObject]@{ Id=$guid1; Url="https://youtube.com/watch?v=11111111111"; Mode="Video"; MaxHeight=720; AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Success"; Error=""; OutputFilePath="C:\invalid.mp4"; VideoId="11111111111"; RetryCount=0; AttemptCount=1 },
            [PSCustomObject]@{ Id=$guid2; Url="https://youtube.com/watch?v=22222222222"; Mode="Video"; MaxHeight=720; AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Success"; Error=""; OutputFilePath="C:\valid.mp4"; VideoId="22222222222"; RetryCount=0; AttemptCount=1 }
        )
        
        Mock Test-FileValidity { 
            param($FilePath, $Mode)
            return ($FilePath -eq "C:\valid.mp4")
        }
        
        $plan = Get-RetryPlan -Manifest $manifest
        $plan.ItemsToRun.Id | Should -Contain $guid1
        $plan.ItemsToRun.Id | Should -Not -Contain $guid2
    }

It "Marks invalid-VideoId item Failed while still running valid ones" {
    $good = [guid]::NewGuid().ToString(); $bad = [guid]::NewGuid().ToString()
    $manifest = @(
        [PSCustomObject]@{ Id=$bad;  Url="https://example.com/video"; Mode="Video"; MaxHeight=720; AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Failed"; Error=""; OutputFilePath=""; VideoId=""; RetryCount=0; AttemptCount=1 },
        [PSCustomObject]@{ Id=$good; Url="https://youtube.com/watch?v=12345678901"; Mode="Video"; MaxHeight=720; AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Failed"; Error=""; OutputFilePath=""; VideoId="12345678901"; RetryCount=0; AttemptCount=1 }
    )
    $plan = Get-RetryPlan -Manifest $manifest
    $plan.ItemsToRun.Count | Should -Be 1
    $plan.ItemsToRun[0].Id | Should -Be $good
    $badEntry = $plan.ModifiedManifest | Where-Object { $_.Id -eq $bad }
    $badEntry.Status | Should -Be "Failed"
    $badEntry.Error | Should -Be "Invalid YouTube URL / VideoId"
}

It "Returns no plan when the only candidate has an invalid VideoId" {
    $bad = [guid]::NewGuid().ToString()
    $manifest = @([PSCustomObject]@{ Id=$bad; Url="https://example.com/video"; Mode="Video"; MaxHeight=720; AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Failed"; Error=""; OutputFilePath=""; VideoId=""; RetryCount=0; AttemptCount=1 })
    $plan = Get-RetryPlan -Manifest $manifest
    $plan.ItemsToRun.Count | Should -Be 0
    $plan.ModifiedManifest | Should -BeNullOrEmpty
}
}

Describe "Phase 1: Set-ItemState Mutation" {
    It "Mutates the original object in memory" {
        $guid = [guid]::NewGuid().ToString()
        $item = [PSCustomObject]@{ Id=$guid; Url="https://youtube.com/watch?v=12345678901"; Mode="Video"; MaxHeight=0; AudioFormat=""; Bitrate=0; Destination=$TestDrive; Status="Pending"; Error=""; VideoId="12345678901"; OutputFilePath=""; RetryCount=0; AttemptCount=0 }
        $script:Manifest = @($item)
        Save-AtomicJson -Path (Join-Path $script:AppDir "manifest.json") -Data $script:Manifest
        
        Set-ItemState -Item $item -Status "Downloading" -AttemptCount 1 -RetryCount 0
        $item.Status | Should -Be "Downloading"
        $item.AttemptCount | Should -Be 1
        $script:Manifest[0].Status | Should -Be "Downloading"
    }
}
