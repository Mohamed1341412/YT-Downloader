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
    . "$PSScriptRoot\..\Development\YT-Downloader.ps1"

    function global:yt-dlp { }   # placeholder علشان Pester يقدر يعمل Mock لها

    # 5. Mocks لوظائف النظام
    Mock Start-Sleep { }
    Mock Read-Host { return "1" }
    Mock Start-Process { return @{ ExitCode = 0 } }
}

AfterAll {
    $env:APPDATA = $script:OrigAppData
    $env:PATH = $script:OrigPath
    Remove-Item function:global:yt-dlp -ErrorAction SilentlyContinue
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
        $scriptPath = Join-Path $PSScriptRoot "..\Development\YT-Downloader.ps1"
        $scriptBlock = @"
`$env:APPDATA = '$testDrivePath'
. '$scriptPath'
`$script:Config.MaxRetries = 'invalid'
Initialize-App
"@
        $result = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $scriptBlock 2>&1
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
        Mock Get-FileVerdict { return @{ Verdict = "Valid"; Reason = "OK" } }
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
        $item.AttemptCount | Should -Be 2
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

Describe "Phase 3 - Delivery 1: Pure Helper Functions" {
     BeforeAll {
        function global:ffprobe { }
    }

    AfterAll {
        Remove-Item function:global:ffprobe -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:TestDir = Join-Path $TestDrive "TestDir"
        $script:TestDir2 = Join-Path $TestDrive "TestDir2"
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        New-Item -ItemType Directory -Path $script:TestDir2 -Force | Out-Null

        $script:ValidVideoPath = Join-Path $script:TestDir "valid_video.mp4"
        $script:ValidAudioPath = Join-Path $script:TestDir "valid_audio.mp3"
        $script:ZeroLengthPath = Join-Path $script:TestDir "zero_length.mp4"

        Set-Content -Path $script:ValidVideoPath -Value "dummy video content" -Force
        Set-Content -Path $script:ValidAudioPath -Value "dummy audio content" -Force
        New-Item -ItemType File -Path $script:ZeroLengthPath -Force | Out-Null
    }

    Context "Get-MediaInfo" {
        It "Parses real-world case: video without nb_read_packets, audio with it" {
            Mock ffprobe {
                $global:LASTEXITCODE = 0
                return '{"streams":[{"codec_type":"video"},{"codec_type":"audio","nb_read_packets":"3002"}],"format":{"duration":"60.041000"}}'
            }
            $info = Get-MediaInfo -FilePath $script:ValidVideoPath
            $info.Success | Should -BeTrue
            $info.VideoPackets | Should -Be 0
            $info.AudioPackets | Should -Be 3002
            $info.Duration | Should -Be 60.041
            $info.IsCommandFailure | Should -BeFalse
        }

        It "Parses 'N/A' as 0 without throwing exception" {
            Mock ffprobe {
                $global:LASTEXITCODE = 0
                return '{"streams":[{"codec_type":"video","nb_read_packets":"N/A"}],"format":{"duration":"10.0"}}'
            }
            $info = Get-MediaInfo -FilePath $script:ValidVideoPath
            $info.Success | Should -BeTrue
            $info.VideoPackets | Should -Be 0
            $info.IsCommandFailure | Should -BeFalse
        }

        It "Returns Success=false, IsCommandFailure=false on exit code 1" {
            Mock ffprobe {
                $global:LASTEXITCODE = 1
                return "Invalid data found when processing input"
            }
            $info = Get-MediaInfo -FilePath $script:ValidVideoPath
            $info.Success | Should -BeFalse
            $info.IsCommandFailure | Should -BeFalse
        }

        It "Returns IsCommandFailure=true on exception (throw)" {
            Mock ffprobe {
                $global:LASTEXITCODE = 0
                throw "boom"
            }
            $info = Get-MediaInfo -FilePath $script:ValidVideoPath
            $info.Success | Should -BeFalse
            $info.IsCommandFailure | Should -BeTrue
        }

        It "Returns IsCommandFailure=true on corrupt JSON with exit 0" {
            Mock ffprobe {
                $global:LASTEXITCODE = 0
                return "this is not valid json"
            }
            $info = Get-MediaInfo -FilePath $script:ValidVideoPath
            $info.Success | Should -BeFalse
            $info.IsCommandFailure | Should -BeTrue
        }
    }

    Context "Get-FileVerdict" {
        It "Returns Corrupt for zero-length file" {
            $verdict = Get-FileVerdict -FilePath $script:ZeroLengthPath -Mode "Video"
            $verdict.Verdict | Should -Be "Corrupt"
        }

        It "Returns Corrupt when file has no audio or video streams" {
            Mock Get-MediaInfo { 
                return @{ Success = $true; HasVideo = $false; HasAudio = $false; VideoPackets = 0; AudioPackets = 0; Duration = 10.0; Error = $null; IsCommandFailure = $false } 
            }
            $verdict = Get-FileVerdict -FilePath $script:ValidVideoPath -Mode "Video"
            $verdict.Verdict | Should -Be "Corrupt"
            $verdict.Reason | Should -Be "No audio or video streams"
        }

        It "Returns Valid for proper Video mode" {
            Mock Get-MediaInfo { return @{ Success = $true; HasVideo = $true; HasAudio = $false; VideoPackets = 100; AudioPackets = 0; Duration = 10.0; Error = $null; IsCommandFailure = $false } }
            $verdict = Get-FileVerdict -FilePath $script:ValidVideoPath -Mode "Video"
            $verdict.Verdict | Should -Be "Valid"
        }

        It "Returns Corrupt for Video with 0 packets" {
            Mock Get-MediaInfo { return @{ Success = $true; HasVideo = $true; HasAudio = $false; VideoPackets = 0; AudioPackets = 0; Duration = 10.0; Error = $null; IsCommandFailure = $false } }
            $verdict = Get-FileVerdict -FilePath $script:ValidVideoPath -Mode "Video"
            $verdict.Verdict | Should -Be "Corrupt"
        }
        
        It "Returns Corrupt for Duration <= 0" {
            Mock Get-MediaInfo { return @{ Success = $true; HasVideo = $true; HasAudio = $false; VideoPackets = 100; AudioPackets = 0; Duration = 0.0; Error = $null; IsCommandFailure = $false } }
            $verdict = Get-FileVerdict -FilePath $script:ValidVideoPath -Mode "Video"
            $verdict.Verdict | Should -Be "Corrupt"
        }

        It "Returns OtherMode when checking Video mode on an Audio-only file" {
            Mock Get-MediaInfo { return @{ Success = $true; HasVideo = $false; HasAudio = $true; VideoPackets = 0; AudioPackets = 100; Duration = 10.0; Error = $null; IsCommandFailure = $false } }
            $verdict = Get-FileVerdict -FilePath $script:ValidAudioPath -Mode "Video"
            $verdict.Verdict | Should -Be "OtherMode"
        }

        It "Returns OtherMode when checking Audio mode on a file containing Video" {
            Mock Get-MediaInfo { return @{ Success = $true; HasVideo = $true; HasAudio = $true; VideoPackets = 100; AudioPackets = 100; Duration = 10.0; Error = $null; IsCommandFailure = $false } }
            $verdict = Get-FileVerdict -FilePath $script:ValidVideoPath -Mode "Audio"
            $verdict.Verdict | Should -Be "OtherMode"
        }

        It "Returns Unknown when Get-MediaInfo indicates command failure" {
            Mock Get-MediaInfo { return @{ Success = $false; Error = "ffprobe not found"; IsCommandFailure = $true } }
            $verdict = Get-FileVerdict -FilePath $script:ValidVideoPath -Mode "Video"
            $verdict.Verdict | Should -Be "Unknown"
        }
        
        It "Returns Corrupt when Get-MediaInfo indicates file read failure (non-zero exit)" {
            Mock Get-MediaInfo { return @{ Success = $false; Error = "ffprobe exited with code 1"; IsCommandFailure = $false } }
            $verdict = Get-FileVerdict -FilePath $script:ValidVideoPath -Mode "Video"
            $verdict.Verdict | Should -Be "Corrupt"
        }
    }

    Context "Test-PathInsideDirectory" {
        It "Returns true for valid direct child file" {
            Test-PathInsideDirectory -Path $script:ValidVideoPath -Directory $script:TestDir | Should -BeTrue
        }

        It "Returns false for path outside directory (C:\out vs C:\out2 trap)" {
            $outsideFile = Join-Path $script:TestDir2 "outside.mp4"
            Set-Content -Path $outsideFile -Value "x" -Force
            Test-PathInsideDirectory -Path $outsideFile -Directory $script:TestDir | Should -BeFalse
        }

        It "Returns false for directory traversal (..)" {
            $escapePath = Join-Path $script:TestDir "..\escape.txt"
            New-Item -ItemType File -Path (Join-Path $TestDrive "escape.txt") -Force | Out-Null
            Test-PathInsideDirectory -Path $escapePath -Directory $script:TestDir | Should -BeFalse
        }

        It "Returns false if path is a directory, not a file" {
            Test-PathInsideDirectory -Path $script:TestDir -Directory $TestDrive | Should -BeFalse
        }

        It "Returns false for empty path" {
            Test-PathInsideDirectory -Path "" -Directory $script:TestDir | Should -BeFalse
        }
        
        It "Returns false for file in subdirectory (not direct child)" {
            $subDir = Join-Path $script:TestDir "SubDir"
            New-Item -ItemType Directory -Path $subDir -Force | Out-Null
            $subFile = Join-Path $subDir "sub.mp4"
            Set-Content -Path $subFile -Value "x" -Force
            Test-PathInsideDirectory -Path $subFile -Directory $script:TestDir | Should -BeFalse
        }
    }

    Context "Move-ToInvalid" {
        It "Successfully moves file and generates correct naming convention" {
            $moveResult = Move-ToInvalid -FilePath $script:ValidVideoPath -Directory $script:TestDir
            $moveResult.Success | Should -BeTrue
            $moveResult.NewPath | Should -Match "\.mp4\.invalid_\d{8}_\d{6}_[0-9a-f]{8}$"
            Test-Path -LiteralPath $script:ValidVideoPath | Should -BeFalse
            Test-Path -LiteralPath $moveResult.NewPath | Should -BeTrue
        }

        It "Fails if path is outside the target directory" {
            $moveResult = Move-ToInvalid -FilePath $script:ValidVideoPath -Directory $script:TestDir2
            $moveResult.Success | Should -BeFalse
            $moveResult.Error | Should -Match "validation failed"
            Test-Path -LiteralPath $script:ValidVideoPath | Should -BeTrue
        }

        It "Retries on collision and succeeds on second attempt" {
            $mockExistingPath = Join-Path $script:TestDir "valid_video.mp4.invalid_20231010_120000_12345678"
            Set-Content -Path $mockExistingPath -Value "existing" -Force

            $script:callCount = 0
            Mock Get-InvalidTargetPath {
                $script:callCount++
                if ($script:callCount -eq 1) { return $mockExistingPath }
                return Join-Path $script:TestDir "valid_video.mp4.invalid_20231010_120001_87654321"
            }

            $moveResult = Move-ToInvalid -FilePath $script:ValidVideoPath -Directory $script:TestDir
            $moveResult.Success | Should -BeTrue
            Should -Invoke -CommandName Get-InvalidTargetPath -Times 2 -Exactly
            Test-Path -LiteralPath $script:ValidVideoPath | Should -BeFalse
        }

        It "Fails after 5 attempts if collisions persist" {
            $mockExistingPath = Join-Path $script:TestDir "valid_video.mp4.invalid_20231010_120000_12345678"
            Set-Content -Path $mockExistingPath -Value "existing" -Force

            Mock Get-InvalidTargetPath { return $mockExistingPath }

            $moveResult = Move-ToInvalid -FilePath $script:ValidVideoPath -Directory $script:TestDir
            $moveResult.Success | Should -BeFalse
            $moveResult.Error | Should -Match "5 attempts"
            Should -Invoke -CommandName Get-InvalidTargetPath -Times 5 -Exactly
            Test-Path -LiteralPath $script:ValidVideoPath | Should -BeTrue
        }
    }

    Describe "Phase 3 - Delivery 2: Find-OutputCandidates" {
    BeforeAll {
        function global:ffprobe { }
    }

    AfterAll {
        Remove-Item function:global:ffprobe -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:CandidateDir = Join-Path $TestDrive "CandidateDir"
        New-Item -ItemType Directory -Path $script:CandidateDir -Force | Out-Null
        
        $script:SubDir = Join-Path $script:CandidateDir "SubDir"
        New-Item -ItemType Directory -Path $script:SubDir -Force | Out-Null

        $videoId = "AbC12345678"
        
        # ملفات مرشحة صحيحة
        $script:ValidVideoFile = Join-Path $script:CandidateDir "prefix_${videoId}.mp4"
        $script:ValidAudioFile = Join-Path $script:CandidateDir "prefix_${videoId}.mp3"
        Set-Content -Path $script:ValidVideoFile -Value "dummy" -Force
        Set-Content -Path $script:ValidAudioFile -Value "dummy" -Force

        # ملفات مستبعدة (Excluded)
        Set-Content -Path (Join-Path $script:CandidateDir "prefix_${videoId}.mp4.part") -Value "x" -Force
        Set-Content -Path (Join-Path $script:CandidateDir "prefix_${videoId}.invalid_123.mp4") -Value "x" -Force
        Set-Content -Path (Join-Path $script:CandidateDir "prefix_${videoId}.ytdl") -Value "x" -Force
        Set-Content -Path (Join-Path $script:CandidateDir "prefix_${videoId}-Frag1.part") -Value "x" -Force
        Set-Content -Path (Join-Path $script:CandidateDir "prefix_${videoId}.f137.mp4") -Value "x" -Force
        Set-Content -Path (Join-Path $script:CandidateDir "prefix_${videoId}.mp4.bak") -Value "x" -Force
        Set-Content -Path (Join-Path $script:CandidateDir "prefix_${videoId}.mp4.tmp") -Value "x" -Force
        
        # ملف بمعرف خطأ في حالة الأحرف (Case-Sensitive Check)
        Set-Content -Path (Join-Path $script:CandidateDir "prefix_abc12345678.mp4") -Value "x" -Force
        
        # ملف في مجلد فرعي (يجب تجاهله)
        Set-Content -Path (Join-Path $script:SubDir "prefix_${videoId}.mp4") -Value "x" -Force
    }

    It "Finds valid candidates and assigns correct verdicts" {
        Mock ffprobe {
            $global:LASTEXITCODE = 0
            return '{"streams":[{"codec_type":"video","nb_read_packets":"100"}],"format":{"duration":"10.0"}}'
        }

        $candidates = @(Find-OutputCandidates -Directory $script:CandidateDir -VideoId "AbC12345678" -Mode "Video")
        $candidates.Count | Should -Be 2
        $names = @($candidates | ForEach-Object { $_.File.Name })
        $names | Should -Contain "prefix_AbC12345678.mp4"
        $names | Should -Contain "prefix_AbC12345678.mp3"
        @($candidates | Where-Object { $_.Verdict -ne "Valid" }).Count | Should -Be 0
    }

    It "Excludes .part, .ytdl, .invalid_*, -FragN.part, .fNNN, .bak, and .tmp files" {
        Mock ffprobe {
            $global:LASTEXITCODE = 0
            return '{"streams":[{"codec_type":"video","nb_read_packets":"100"}],"format":{"duration":"10.0"}}'
        }

        $candidates = @(Find-OutputCandidates -Directory $script:CandidateDir -VideoId "AbC12345678" -Mode "Video")
        @($candidates).Count | Should -BeGreaterThan 0
        
        $names = @($candidates | ForEach-Object { $_.File.Name })
        $names | Should -Not -Contain "prefix_AbC12345678.mp4.part"
        $names | Should -Not -Contain "prefix_AbC12345678.invalid_123.mp4"
        $names | Should -Not -Contain "prefix_AbC12345678.ytdl"
        $names | Should -Not -Contain "prefix_AbC12345678-Frag1.part"
        $names | Should -Not -Contain "prefix_AbC12345678.f137.mp4"
        $names | Should -Not -Contain "prefix_AbC12345678.mp4.bak"
        $names | Should -Not -Contain "prefix_AbC12345678.mp4.tmp"
    }

    It "Enforces case-sensitive VideoId matching" {
        Mock ffprobe {
            $global:LASTEXITCODE = 0
            return '{"streams":[{"codec_type":"video","nb_read_packets":"100"}],"format":{"duration":"10.0"}}'
        }

        $candidates = @(Find-OutputCandidates -Directory $script:CandidateDir -VideoId "aBc12345678" -Mode "Video")
        $candidates.Count | Should -Be 0
    }

    It "Ignores files in subdirectories" {
        Mock ffprobe {
            $global:LASTEXITCODE = 0
            return '{"streams":[{"codec_type":"video","nb_read_packets":"100"}],"format":{"duration":"10.0"}}'
        }

        $candidates = @(Find-OutputCandidates -Directory $script:CandidateDir -VideoId "AbC12345678" -Mode "Video")
        $foundInSubdir = $candidates | Where-Object { $_.File.DirectoryName -eq $script:SubDir }
        $foundInSubdir | Should -BeNullOrEmpty
    }

    It "Correctly identifies OtherMode when checking Video mode on an Audio file" {
        Mock ffprobe {
            $global:LASTEXITCODE = 0
            return '{"streams":[{"codec_type":"audio","nb_read_packets":"100"}],"format":{"duration":"10.0"}}'
        }

        $candidates = @(Find-OutputCandidates -Directory $script:CandidateDir -VideoId "AbC12345678" -Mode "Video")
        $audioCandidate = $candidates | Where-Object { $_.File.Name -eq "prefix_AbC12345678.mp3" }
        $audioCandidate | Should -Not -BeNullOrEmpty
        $audioCandidate.Verdict | Should -Be "OtherMode"
    }

    It "Returns empty array if directory does not exist" {
        $candidates = @(Find-OutputCandidates -Directory "C:\NonExistentDir12345" -VideoId "AbC12345678" -Mode "Video")
        $candidates.Count | Should -Be 0
    }

    It "Returns empty array if VideoId is empty" {
        $candidates = @(Find-OutputCandidates -Directory $script:CandidateDir -VideoId "" -Mode "Video")
        $candidates.Count | Should -Be 0
    }
}

Describe "Phase 3 - Delivery 3: Invoke-ItemDownload Corrupt/Unknown/OtherMode Handling" {
    BeforeAll {
        $script:OrigAppData = $env:APPDATA
        $env:APPDATA = $TestDrive
        
        $script:AppDir = Join-Path $env:APPDATA "YT-DL-CLI"
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AppDir "Logs") -Force | Out-Null
        
        . "$PSScriptRoot\..\Development\YT-Downloader.ps1"
        
        function global:yt-dlp { }
        function global:ffprobe { }
        
        Mock Start-Sleep { }
        Mock Remove-VideoIdFromArchive { return $true }
        Mock Test-FileValidity { return $true }
        Mock Move-ToInvalid { return @{ Success = $true; NewPath = "x"; Error = $null } }
    }

    AfterAll {
        Remove-Item function:global:yt-dlp -ErrorAction SilentlyContinue
        Remove-Item function:global:ffprobe -ErrorAction SilentlyContinue
        $env:APPDATA = $script:OrigAppData
    }

    BeforeEach {
        $script:Config.MaxRetries = 0 # maxAttempts = 1 for deterministic single-attempt tests
        
        $script:TestDest = Join-Path $TestDrive "TestDest"
        if (-not (Test-Path $script:TestDest)) { New-Item -ItemType Directory -Path $script:TestDest -Force | Out-Null }
        
        $script:TestFile = Join-Path $script:TestDest "TestVideo_AbC12345678.mp4"
        Set-Content -Path $script:TestFile -Value "dummy" -Force
    }

    It "Valid file (Case A): succeeds without isolation or archive modification" {
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                "AbC12345678" | Out-File -FilePath $args[$i+2] -Encoding UTF8
                $script:TestFile | Out-File -FilePath $args[$i+5] -Encoding UTF8
            }
        }
        Mock Get-FileVerdict { return @{ Verdict = "Valid"; Reason = "OK" } }
        Mock Move-ToInvalid { return @{ Success = $true; NewPath = "x"; Error = $null } }
        
        $item = [PSCustomObject]@{ Id=[guid]::NewGuid().ToString(); Url="https://youtube.com/watch?v=AbC12345678"; Mode="Video"; MaxHeight=720; AudioFormat=""; Bitrate=0; Destination=$script:TestDest; Status="Pending"; Error=""; OutputFilePath=""; VideoId="AbC12345678"; RetryCount=0; AttemptCount=0 }
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeTrue
        $item.Status | Should -Be "Success"
        Should -Invoke -CommandName Move-ToInvalid -Times 0 -Exactly
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 0 -Exactly
    }

    It "Corrupt file (Case A): isolates successfully and cleans archive" {
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                "AbC12345678" | Out-File -FilePath $args[$i+2] -Encoding UTF8
                $script:TestFile | Out-File -FilePath $args[$i+5] -Encoding UTF8
            }
        }
        Mock Get-FileVerdict { return @{ Verdict = "Corrupt"; Reason = "0 packets" } }
        Mock Move-ToInvalid { return @{ Success = $true; NewPath = "$script:TestFile.invalid_123"; Error = $null } }
        
        $item = [PSCustomObject]@{ Id=[guid]::NewGuid().ToString(); Url="https://youtube.com/watch?v=AbC12345678"; Mode="Video"; MaxHeight=720; AudioFormat=""; Bitrate=0; Destination=$script:TestDest; Status="Pending"; Error=""; OutputFilePath=""; VideoId="AbC12345678"; RetryCount=0; AttemptCount=0 }
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.Status | Should -Be "Failed"
        $item.Error | Should -Match "file was corrupt and isolated to"
        Should -Invoke -CommandName Move-ToInvalid -Times 1 -Exactly
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 1 -Exactly
    }

    It "Corrupt file (Case B, Exit != 0): isolates successfully but DOES NOT clean archive" {
        Mock yt-dlp {
            $global:LASTEXITCODE = 1
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                "AbC12345678" | Out-File -FilePath $args[$i+2] -Encoding UTF8
                $script:TestFile | Out-File -FilePath $args[$i+5] -Encoding UTF8
            }
        }
        Mock Get-FileVerdict { return @{ Verdict = "Corrupt"; Reason = "Invalid data" } }
        Mock Move-ToInvalid { return @{ Success = $true; NewPath = "$script:TestFile.invalid_123"; Error = $null } }
        
        $item = [PSCustomObject]@{ Id=[guid]::NewGuid().ToString(); Url="https://youtube.com/watch?v=AbC12345678"; Mode="Video"; MaxHeight=720; AudioFormat=""; Bitrate=0; Destination=$script:TestDest; Status="Pending"; Error=""; OutputFilePath=""; VideoId="AbC12345678"; RetryCount=0; AttemptCount=0 }
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.Status | Should -Be "Failed"
        $item.Error | Should -Match "file was corrupt and isolated to"
        Should -Invoke -CommandName Move-ToInvalid -Times 1 -Exactly
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 0 -Exactly
    }

    It "Corrupt file: isolation fails, archive untouched" {
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                "AbC12345678" | Out-File -FilePath $args[$i+2] -Encoding UTF8
                $script:TestFile | Out-File -FilePath $args[$i+5] -Encoding UTF8
            }
        }
        Mock Get-FileVerdict { return @{ Verdict = "Corrupt"; Reason = "0 packets" } }
        Mock Move-ToInvalid { return @{ Success = $false; NewPath = $null; Error = "disk full" } }
        
        $item = [PSCustomObject]@{ Id=[guid]::NewGuid().ToString(); Url="https://youtube.com/watch?v=AbC12345678"; Mode="Video"; MaxHeight=720; AudioFormat=""; Bitrate=0; Destination=$script:TestDest; Status="Pending"; Error=""; OutputFilePath=""; VideoId="AbC12345678"; RetryCount=0; AttemptCount=0 }
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.Status | Should -Be "Failed"
        $item.Error | Should -Match "quarantine failed: disk full"
        Should -Invoke -CommandName Move-ToInvalid -Times 1 -Exactly
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 0 -Exactly
    }

    It "Corrupt file: isolation succeeds but archive cleanup fails (Rule 6) -> immediate halt" {
        $script:Config.MaxRetries = 1
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                "AbC12345678" | Out-File -FilePath $args[$i+2] -Encoding UTF8
                $script:TestFile | Out-File -FilePath $args[$i+5] -Encoding UTF8
            }
        }
        Mock Get-FileVerdict { return @{ Verdict = "Corrupt"; Reason = "0 packets" } }
        Mock Move-ToInvalid { return @{ Success = $true; NewPath = "$script:TestFile.invalid_123"; Error = $null } }
        Mock Remove-VideoIdFromArchive { return $false }
        
        $item = [PSCustomObject]@{ Id=[guid]::NewGuid().ToString(); Url="https://youtube.com/watch?v=AbC12345678"; Mode="Video"; MaxHeight=720; AudioFormat=""; Bitrate=0; Destination=$script:TestDest; Status="Pending"; Error=""; OutputFilePath=""; VideoId="AbC12345678"; RetryCount=0; AttemptCount=0 }
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.Status | Should -Be "Failed"
        $item.Error | Should -Match "archive cleanup failed"
        $item.Error | Should -Match "isolated to"
        Should -Invoke -CommandName yt-dlp -Times 1 -Exactly
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 1 -Exactly
    }

    It "Unknown verdict (Exit 0): fails without isolation or archive modification" {
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                "AbC12345678" | Out-File -FilePath $args[$i+2] -Encoding UTF8
                $script:TestFile | Out-File -FilePath $args[$i+5] -Encoding UTF8
            }
        }
        Mock Get-FileVerdict { return @{ Verdict = "Unknown"; Reason = "ffprobe not found" } }
        
        $item = [PSCustomObject]@{ Id=[guid]::NewGuid().ToString(); Url="https://youtube.com/watch?v=AbC12345678"; Mode="Video"; MaxHeight=720; AudioFormat=""; Bitrate=0; Destination=$script:TestDest; Status="Pending"; Error=""; OutputFilePath=""; VideoId="AbC12345678"; RetryCount=0; AttemptCount=0 }
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.Status | Should -Be "Failed"
        $item.Error | Should -Match "verdict Unknown: ffprobe not found"
        Should -Invoke -CommandName Move-ToInvalid -Times 0 -Exactly
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 0 -Exactly
    }

    It "OtherMode verdict (Exit 0): fails without isolation or archive modification" {
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                "AbC12345678" | Out-File -FilePath $args[$i+2] -Encoding UTF8
                $script:TestFile | Out-File -FilePath $args[$i+5] -Encoding UTF8
            }
        }
        Mock Get-FileVerdict { return @{ Verdict = "OtherMode"; Reason = "Contains video stream" } }
        
        $item = [PSCustomObject]@{ Id=[guid]::NewGuid().ToString(); Url="https://youtube.com/watch?v=AbC12345678"; Mode="Audio"; MaxHeight=0; AudioFormat="MP3"; Bitrate=128; Destination=$script:TestDest; Status="Pending"; Error=""; OutputFilePath=""; VideoId="AbC12345678"; RetryCount=0; AttemptCount=0 }
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.Status | Should -Be "Failed"
        $item.Error | Should -Match "verdict OtherMode: Contains video stream"
        Should -Invoke -CommandName Move-ToInvalid -Times 0 -Exactly
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 0 -Exactly
    }

    It "Case B (Exit != 0 with path): Valid verdict does not isolate, fails with exit code" {
        Mock yt-dlp {
            $global:LASTEXITCODE = 1
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                "AbC12345678" | Out-File -FilePath $args[$i+2] -Encoding UTF8
                $script:TestFile | Out-File -FilePath $args[$i+5] -Encoding UTF8
            }
        }
        Mock Get-FileVerdict { return @{ Verdict = "Valid"; Reason = "OK" } }
        Mock Move-ToInvalid { return @{ Success = $true; NewPath = "x"; Error = $null } }
        
        $item = [PSCustomObject]@{ Id=[guid]::NewGuid().ToString(); Url="https://youtube.com/watch?v=AbC12345678"; Mode="Video"; MaxHeight=720; AudioFormat=""; Bitrate=0; Destination=$script:TestDest; Status="Pending"; Error=""; OutputFilePath=""; VideoId="AbC12345678"; RetryCount=0; AttemptCount=0 }
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.Status | Should -Be "Failed"
        $item.Error | Should -Match "yt-dlp exit code 1"
        Should -Invoke -CommandName Move-ToInvalid -Times 0 -Exactly
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 0 -Exactly
    }

    It "MaxRetries=1: 1st attempt Corrupt, 2nd Valid -> Success, AttemptCount=2" {
        $script:Config.MaxRetries = 1 # maxAttempts = 2
        $script:verdictCallCount = 0
        Mock Get-FileVerdict {
            $script:verdictCallCount++
            if ($script:verdictCallCount -eq 1) {
                return @{ Verdict = "Corrupt"; Reason = "0 packets" }
            } else {
                return @{ Verdict = "Valid"; Reason = "OK" }
            }
        }
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                "AbC12345678" | Out-File -FilePath $args[$i+2] -Encoding UTF8
                $script:TestFile | Out-File -FilePath $args[$i+5] -Encoding UTF8
            }
        }
        Mock Move-ToInvalid { return @{ Success = $true; NewPath = "$script:TestFile.invalid_123"; Error = $null } }
        
        $item = [PSCustomObject]@{ Id=[guid]::NewGuid().ToString(); Url="https://youtube.com/watch?v=AbC12345678"; Mode="Video"; MaxHeight=720; AudioFormat=""; Bitrate=0; Destination=$script:TestDest; Status="Pending"; Error=""; OutputFilePath=""; VideoId="AbC12345678"; RetryCount=0; AttemptCount=0 }
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeTrue
        $item.Status | Should -Be "Success"
        $item.AttemptCount | Should -Be 2
        Should -Invoke -CommandName Move-ToInvalid -Times 1 -Exactly
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 1 -Exactly
    }
}
Describe "Phase 3 - Delivery 4: Archive Branch (Case C) and Unified Cleanup Failure" {
    BeforeAll {
        $script:OrigAppData = $env:APPDATA
        $env:APPDATA = $TestDrive
        
        $script:AppDir = Join-Path $env:APPDATA "YT-DL-CLI"
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AppDir "Logs") -Force | Out-Null
        
        function global:yt-dlp { }
        function global:ffprobe { }
        
        . "$PSScriptRoot\..\Development\YT-Downloader.ps1"
        
        Mock Start-Sleep { }
        Mock Test-FileValidity { return $true }
        Mock Test-IdInArchive { return @{ Status = 'Found' } }
        Mock Get-FileVerdict { return @{ Verdict = "Valid"; Reason = "OK" } }
        
        # Helper functions moved to BeforeAll for reuse across tests
        function script:New-TestItem {
            param([string]$Status = "Pending", [int]$AttemptCount = 0)
            [PSCustomObject]@{
                Id = [guid]::NewGuid().ToString()
                Url = "https://youtube.com/watch?v=AbC12345678"
                Mode = "Video"
                MaxHeight = 720
                AudioFormat = ""
                Bitrate = 0
                Destination = $script:TestDest
                Status = $Status
                Error = ""
                OutputFilePath = ""
                VideoId = "AbC12345678"
                RetryCount = 0
                AttemptCount = $AttemptCount
            }
        }
        
        function script:New-Candidate {
            param([string]$Name, [string]$Verdict, [datetime]$LastWriteTimeUtc, [string]$Reason = "")
            $filePath = Join-Path $script:TestDest $Name
            if (-not (Test-Path -LiteralPath $filePath)) {
                Set-Content -Path $filePath -Value "dummy" -Force
            }
            $file = Get-Item -LiteralPath $filePath
            $wrapper = [PSCustomObject]@{
                FullName = $file.FullName
                Name = $file.Name
                LastWriteTimeUtc = $LastWriteTimeUtc
            }
            [PSCustomObject]@{
                File = $wrapper
                Verdict = $Verdict
                Reason = $Reason
            }
        }
    }

    AfterAll {
        Remove-Item function:global:yt-dlp -ErrorAction SilentlyContinue
        Remove-Item function:global:ffprobe -ErrorAction SilentlyContinue
        $env:APPDATA = $script:OrigAppData
    }

    BeforeEach {
        $script:Config.MaxRetries = 0
        
        $script:TestDest = Join-Path $TestDrive "TestDest"
        if (-not (Test-Path $script:TestDest)) { New-Item -ItemType Directory -Path $script:TestDest -Force | Out-Null }
        
        # yt-dlp exits 0 without writing a path (triggers archive branch)
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                "AbC12345678" | Out-File -FilePath $args[$i+2] -Encoding UTF8
                # pathFile intentionally left empty to force archive branch
            }
        }
    }

    It "C-Rule1: Single Valid candidate -> success without isolation" {
        Mock Find-OutputCandidates {
            return @(
                (New-Candidate -Name "video_AbC12345678.mp4" -Verdict "Valid" -LastWriteTimeUtc (Get-Date).ToUniversalTime())
            )
        }
        Mock Move-ToInvalid { throw "Should not be called" }
        Mock Remove-VideoIdFromArchive { throw "Should not be called" }
        
        $item = New-TestItem
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeTrue
        $item.Status | Should -Be "Success"
        $item.OutputFilePath | Should -Match "video_AbC12345678\.mp4$"
        Should -Invoke -CommandName Move-ToInvalid -Times 0 -Exactly
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 0 -Exactly
    }

    It "C-Rule1: Multiple Valid candidates -> newest wins" {
        $script:oldTime = (Get-Date).ToUniversalTime().AddHours(-2)
        $script:newTime = (Get-Date).ToUniversalTime()
        Mock Find-OutputCandidates {
            return @(
                (New-Candidate -Name "old_AbC12345678.mp4" -Verdict "Valid" -LastWriteTimeUtc $script:oldTime),
                (New-Candidate -Name "new_AbC12345678.mp4" -Verdict "Valid" -LastWriteTimeUtc $script:newTime)
            )
        }
        
        $item = New-TestItem
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeTrue
        $item.Status | Should -Be "Success"
        $item.OutputFilePath | Should -Match "new_AbC12345678\.mp4$"
    }

    It "C-Rule1: Two Valid candidates with same LastWriteTimeUtc -> Ordinal name wins (B_ before a_)" {
        # This test proves that Ordinal comparison is used, not CurrentCulture.
        # In Ordinal, 'B' (0x42) < 'a' (0x61), so B_... should be chosen.
        # We use B_ and a_ (not A_ and a_) because A_/a_ would be the same file on NTFS.
        $script:sameTime = [datetime]::new(2024, 1, 1, 12, 0, 0, [DateTimeKind]::Utc)
        
        # Verify the Ordinal comparison expectation
        [System.StringComparer]::Ordinal.Compare("B_AbC12345678.mp4", "a_AbC12345678.mp4") | Should -BeLessThan 0
        
        Mock Find-OutputCandidates {
            return @(
                (New-Candidate -Name "a_AbC12345678.mp4" -Verdict "Valid" -LastWriteTimeUtc $script:sameTime),
                (New-Candidate -Name "B_AbC12345678.mp4" -Verdict "Valid" -LastWriteTimeUtc $script:sameTime)
            )
        }
        
        $item = New-TestItem
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeTrue
        $item.Status | Should -Be "Success"
        $item.OutputFilePath | Should -Match "B_AbC12345678\.mp4$"
    }

    It "C-Rule1: Valid with Corrupt -> success, no isolation" {
        Mock Find-OutputCandidates {
            return @(
                (New-Candidate -Name "valid_AbC12345678.mp4" -Verdict "Valid" -LastWriteTimeUtc (Get-Date).ToUniversalTime()),
                (New-Candidate -Name "corrupt_AbC12345678.mp4" -Verdict "Corrupt" -LastWriteTimeUtc (Get-Date).ToUniversalTime())
            )
        }
        Mock Move-ToInvalid { throw "Should not be called" }
        Mock Remove-VideoIdFromArchive { throw "Should not be called" }
        
        $item = New-TestItem
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeTrue
        $item.Status | Should -Be "Success"
        Should -Invoke -CommandName Move-ToInvalid -Times 0 -Exactly
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 0 -Exactly
    }

    It "C-Rule3: Corrupt -> isolate, remove ID, then retry succeeds via path file (MaxRetries=1)" {
        $script:Config.MaxRetries = 1
        $script:callCount = 0
        Mock yt-dlp {
            $script:callCount++
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                "AbC12345678" | Out-File -FilePath $args[$i+2] -Encoding UTF8
                if ($script:callCount -ge 2) {
                    # Second attempt: write path file to trigger Case A with Valid verdict
                    $script:TestFileRetry = Join-Path $script:TestDest "retry_AbC12345678.mp4"
                    Set-Content -Path $script:TestFileRetry -Value "dummy" -Force
                    $script:TestFileRetry | Out-File -FilePath $args[$i+5] -Encoding UTF8
                }
            }
        }
        Mock Find-OutputCandidates {
            # Only called in first attempt (archive branch)
            return @(
                (New-Candidate -Name "corrupt_AbC12345678.mp4" -Verdict "Corrupt" -LastWriteTimeUtc (Get-Date).ToUniversalTime())
            )
        }
        Mock Move-ToInvalid { return @{ Success = $true; NewPath = "corrupt_AbC12345678.mp4.invalid_123"; Error = $null } }
        Mock Remove-VideoIdFromArchive { return $true }
        Mock Get-FileVerdict { return @{ Verdict = "Valid"; Reason = "OK" } }
        
        $item = New-TestItem
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeTrue
        $item.Status | Should -Be "Success"
        $item.AttemptCount | Should -Be 2
        Should -Invoke -CommandName yt-dlp -Times 2 -Exactly
        Should -Invoke -CommandName Find-OutputCandidates -Times 1 -Exactly
        Should -Invoke -CommandName Move-ToInvalid -Times 1 -Exactly
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 1 -Exactly
    }

    It "C-Rule3: Corrupt with isolation failure -> archive untouched" {
        Mock Find-OutputCandidates {
            return @(
                (New-Candidate -Name "corrupt_AbC12345678.mp4" -Verdict "Corrupt" -LastWriteTimeUtc (Get-Date).ToUniversalTime())
            )
        }
        Mock Move-ToInvalid { return @{ Success = $false; NewPath = $null; Error = "disk full" } }
        Mock Remove-VideoIdFromArchive { throw "Should not be called" }
        
        $item = New-TestItem
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.Status | Should -Be "Failed"
        $item.Error | Should -Match "quarantine failed: disk full"
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 0 -Exactly
    }

        It "C-Rule3: Partial isolation (first succeeds, second fails) -> archive untouched" {
        $script:moveCallCount = 0
        Mock Find-OutputCandidates {
            return @(
                (New-Candidate -Name "corrupt1_AbC12345678.mp4" -Verdict "Corrupt" -LastWriteTimeUtc (Get-Date).ToUniversalTime()),
                (New-Candidate -Name "corrupt2_AbC12345678.mp4" -Verdict "Corrupt" -LastWriteTimeUtc (Get-Date).ToUniversalTime())
            )
        }
        Mock Move-ToInvalid {
            $script:moveCallCount++
            if ($script:moveCallCount -eq 1) {
                return @{ Success = $true; NewPath = "corrupt1.invalid_123"; Error = $null }
            }
            return @{ Success = $false; NewPath = $null; Error = "disk full on second" }
        }
        Mock Remove-VideoIdFromArchive { throw "Should not be called" }
        
        $item = New-TestItem
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.Status | Should -Be "Failed"
        $item.Error | Should -Match "quarantine failed: disk full on second"
        Should -Invoke -CommandName Move-ToInvalid -Times 2 -Exactly
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 0 -Exactly
    }

    It "C-Rule2: Unknown only -> no isolation, no archive modification" {
        Mock Find-OutputCandidates {
            return @(
                (New-Candidate -Name "unknown_AbC12345678.mp4" -Verdict "Unknown" -LastWriteTimeUtc (Get-Date).ToUniversalTime() -Reason "ffprobe not found")
            )
        }
        Mock Move-ToInvalid { throw "Should not be called" }
        Mock Remove-VideoIdFromArchive { throw "Should not be called" }
        
        $item = New-TestItem
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.Status | Should -Be "Failed"
        $item.Error | Should -Match "verdict Unknown: ffprobe not found"
        Should -Invoke -CommandName Move-ToInvalid -Times 0 -Exactly
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 0 -Exactly
    }

    It "C-Rule2: Unknown with Corrupt -> Unknown has priority, no isolation" {
        Mock Find-OutputCandidates {
            return @(
                (New-Candidate -Name "unknown_AbC12345678.mp4" -Verdict "Unknown" -LastWriteTimeUtc (Get-Date).ToUniversalTime() -Reason "ffprobe crashed"),
                (New-Candidate -Name "corrupt_AbC12345678.mp4" -Verdict "Corrupt" -LastWriteTimeUtc (Get-Date).ToUniversalTime())
            )
        }
        Mock Move-ToInvalid { throw "Should not be called" }
        Mock Remove-VideoIdFromArchive { throw "Should not be called" }
        
        $item = New-TestItem
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.Status | Should -Be "Failed"
        $item.Error | Should -Match "verdict Unknown: ffprobe crashed"
        Should -Invoke -CommandName Move-ToInvalid -Times 0 -Exactly
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 0 -Exactly
    }

    It "C-Rule4: OtherMode only -> remove ID, then retry succeeds via path file (MaxRetries=1)" {
        $script:Config.MaxRetries = 1
        $script:callCount = 0
        Mock yt-dlp {
            $script:callCount++
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                "AbC12345678" | Out-File -FilePath $args[$i+2] -Encoding UTF8
                if ($script:callCount -ge 2) {
                    $script:TestFileRetry = Join-Path $script:TestDest "retry_AbC12345678.mp4"
                    Set-Content -Path $script:TestFileRetry -Value "dummy" -Force
                    $script:TestFileRetry | Out-File -FilePath $args[$i+5] -Encoding UTF8
                }
            }
        }
        Mock Find-OutputCandidates {
            return @(
                (New-Candidate -Name "audio_AbC12345678.mp3" -Verdict "OtherMode" -LastWriteTimeUtc (Get-Date).ToUniversalTime() -Reason "Contains audio only")
            )
        }
        Mock Move-ToInvalid { throw "Should not be called" }
        Mock Remove-VideoIdFromArchive { return $true }
        Mock Get-FileVerdict { return @{ Verdict = "Valid"; Reason = "OK" } }
        
        $item = New-TestItem
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeTrue
        $item.Status | Should -Be "Success"
        $item.AttemptCount | Should -Be 2
        Should -Invoke -CommandName yt-dlp -Times 2 -Exactly
        Should -Invoke -CommandName Find-OutputCandidates -Times 1 -Exactly
        Should -Invoke -CommandName Move-ToInvalid -Times 0 -Exactly
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 1 -Exactly
    }

    It "C-Rule4: No candidates -> remove ID, then retry succeeds via path file (MaxRetries=1)" {
        $script:Config.MaxRetries = 1
        $script:callCount = 0
        Mock yt-dlp {
            $script:callCount++
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                "AbC12345678" | Out-File -FilePath $args[$i+2] -Encoding UTF8
                if ($script:callCount -ge 2) {
                    $script:TestFileRetry = Join-Path $script:TestDest "retry_AbC12345678.mp4"
                    Set-Content -Path $script:TestFileRetry -Value "dummy" -Force
                    $script:TestFileRetry | Out-File -FilePath $args[$i+5] -Encoding UTF8
                }
            }
        }
        Mock Find-OutputCandidates { return @() }
        Mock Remove-VideoIdFromArchive { return $true }
        Mock Get-FileVerdict { return @{ Verdict = "Valid"; Reason = "OK" } }
        
        $item = New-TestItem
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeTrue
        $item.Status | Should -Be "Success"
        $item.AttemptCount | Should -Be 2
        Should -Invoke -CommandName yt-dlp -Times 2 -Exactly
        Should -Invoke -CommandName Find-OutputCandidates -Times 1 -Exactly
        Should -Invoke -CommandName Remove-VideoIdFromArchive -Times 1 -Exactly
    }

    It "C-ReadError: preserves existing behavior" {
        Mock Test-IdInArchive { return @{ Status = 'ReadError' } }
        
        $item = New-TestItem
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.Status | Should -Be "Failed"
        $item.Error | Should -Be "Archive read error"
    }

    It "C-Rule3: Corrupt isolation succeeds but archive cleanup fails -> Failed immediately (MaxRetries=1)" {
        $script:Config.MaxRetries = 1
        Mock Find-OutputCandidates {
            return @(
                (New-Candidate -Name "corrupt_AbC12345678.mp4" -Verdict "Corrupt" -LastWriteTimeUtc (Get-Date).ToUniversalTime())
            )
        }
        Mock Move-ToInvalid { return @{ Success = $true; NewPath = "corrupt_AbC12345678.mp4.invalid_123"; Error = $null } }
        Mock Remove-VideoIdFromArchive { return $false }
        
        $item = New-TestItem
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.Status | Should -Be "Failed"
        $item.Error | Should -Match "archive cleanup failed"
        $item.Error | Should -Match "isolated to"
        Should -Invoke -CommandName yt-dlp -Times 1 -Exactly
    }

    It "C-Rule4: OtherMode only with archive cleanup failure -> Failed immediately (MaxRetries=1)" {
        $script:Config.MaxRetries = 1
        Mock Find-OutputCandidates {
            return @(
                (New-Candidate -Name "audio_AbC12345678.mp3" -Verdict "OtherMode" -LastWriteTimeUtc (Get-Date).ToUniversalTime() -Reason "Contains audio only")
            )
        }
        Mock Remove-VideoIdFromArchive { return $false }
        
        $item = New-TestItem
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.Status | Should -Be "Failed"
        $item.Error | Should -Be "Archive cleanup failed"
        Should -Invoke -CommandName yt-dlp -Times 1 -Exactly
    }

        It "C-Rule3: Set-ItemState failure during archive cleanup logs CRITICAL" {
        $script:Config.MaxRetries = 0
        Mock Find-OutputCandidates {
            return @(
                (New-Candidate -Name "corrupt_AbC12345678.mp4" -Verdict "Corrupt" -LastWriteTimeUtc (Get-Date).ToUniversalTime())
            )
        }
        Mock Move-ToInvalid { return @{ Success = $true; NewPath = "corrupt.invalid_123"; Error = $null } }
        Mock Remove-VideoIdFromArchive { return $false }
        Mock Write-Log { }
        Mock Set-ItemState {
            if ($Status -eq "Failed") { return $false }
            return $true
        }
        
        $item = New-TestItem
        $script:Manifest = @($item)
        
        Invoke-ItemDownload -Item $item | Should -BeFalse
        # Status remains unchanged because Set-ItemState is mocked
        Should -Invoke -CommandName Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like 'CRITICAL*' }
    }
}

}
