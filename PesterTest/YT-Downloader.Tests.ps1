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
    Remove-Item function:\yt-dlp -ErrorAction SilentlyContinue
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
        Remove-Item function:\ffprobe -ErrorAction SilentlyContinue
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
}

Describe "Phase 3 - Delivery 2: Find-OutputCandidates" {
    BeforeAll {
        function global:ffprobe { }
    }

    AfterAll {
        Remove-Item function:\ffprobe -ErrorAction SilentlyContinue
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
        Remove-Item function:\yt-dlp -ErrorAction SilentlyContinue
        Remove-Item function:\ffprobe -ErrorAction SilentlyContinue
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
        Remove-Item function:\yt-dlp -ErrorAction SilentlyContinue
        Remove-Item function:\ffprobe -ErrorAction SilentlyContinue
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

Describe "Phase 4 - Delivery 1: Get-FailureKind" {
    BeforeDiscovery {
        $fixturesDirD = Join-Path $PSScriptRoot 'Fixtures\yt-dlp'
        $expectedTable = @{
            'success-baseline' = @{ FailureKind = 'None'; RetryDecision = 'None' }
            'private-video' = @{ FailureKind = 'Permanent'; RetryDecision = 'Stop' }
            'invalid-id-truncated' = @{ FailureKind = 'Permanent'; RetryDecision = 'Stop' }
            'age-restricted' = @{ FailureKind = 'Configuration'; RetryDecision = 'Stop' }
            'format-unavailable' = @{ FailureKind = 'Configuration'; RetryDecision = 'Stop' }
            'bad-option' = @{ FailureKind = 'Configuration'; RetryDecision = 'Stop' }
            'deleted-video' = @{ FailureKind = 'Unknown'; RetryDecision = 'Retry' }
            'nonexistent-id' = @{ FailureKind = 'Unknown'; RetryDecision = 'Retry' }
            'no-network' = @{ FailureKind = 'Transient'; RetryDecision = 'Retry' }
            'http-429' = @{ FailureKind = 'Transient'; RetryDecision = 'Retry' }
            'http-500' = @{ FailureKind = 'Transient'; RetryDecision = 'Retry' }
            'http-503' = @{ FailureKind = 'Transient'; RetryDecision = 'Retry' }
            'http-404' = @{ FailureKind = 'Unknown'; RetryDecision = 'Retry' }
        }
        
        $cases = @()
        foreach ($file in (Get-ChildItem -LiteralPath $fixturesDirD -Filter '*.txt' -File)) {
            $content = Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Raw
            $lines = $content -split '\r?\n'
            $headerEndIndex = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^---\s*$') {
                    $headerEndIndex = $i
                    break
                }
            }
            if ($headerEndIndex -lt 0) { continue }
            
            $header = ($lines[0..($headerEndIndex-1)]) -join "`n"
            $body = ($lines[($headerEndIndex+1)..($lines.Count-1)]) -join "`n"
            
            $exitCodeMatch = [regex]::Match($header, 'exit code:\s*(-?\d+)')
            if (-not $exitCodeMatch.Success) { continue }
            $exitCode = [int]$exitCodeMatch.Groups[1].Value
            
            $caseName = $file.BaseName
            if ($expectedTable.ContainsKey($caseName)) {
                $cases += @{
                    CaseName = $caseName
                    ExitCode = $exitCode
                    ErrorText = @($body)
                    Expected = $expectedTable[$caseName]
                }
            }
        }
        
        $guardData = @(@{
            ExpectedNames = @($expectedTable.Keys)
            ActualNames = @(Get-ChildItem -LiteralPath $fixturesDirD -Filter '*.txt' -File | ForEach-Object { $_.BaseName })
        })
    }
    
    BeforeAll {
        $script:OrigAppData = $env:APPDATA
        $env:APPDATA = $TestDrive
        
        $script:AppDir = Join-Path $env:APPDATA "YT-DL-CLI"
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AppDir "Logs") -Force | Out-Null
        
        . "$PSScriptRoot\..\Development\YT-Downloader.ps1"
    }

    AfterAll {
        $env:APPDATA = $script:OrigAppData
    }
    
    Context "Fixture-based tests" {
        It "Fixture <CaseName> matches expected classification" -ForEach $cases {
            param($CaseName, $ExitCode, $ErrorText, $Expected)
            
            $result = Get-FailureKind -ExitCode $ExitCode -ErrorText $ErrorText
            $result.FailureKind | Should -Be $Expected.FailureKind
            $result.RetryDecision | Should -Be $Expected.RetryDecision
        }
        
        It "Fixture invariants: Permanent/Configuration -> Stop, Transient/Unknown -> Retry, None -> None" -ForEach $cases {
            param($CaseName, $ExitCode, $ErrorText, $Expected)
            
            $result = Get-FailureKind -ExitCode $ExitCode -ErrorText $ErrorText
            
            if ($result.FailureKind -in @('Permanent', 'Configuration')) {
                $result.RetryDecision | Should -Be 'Stop'
            }
            elseif ($result.FailureKind -in @('Transient', 'Unknown')) {
                $result.RetryDecision | Should -Be 'Retry'
            }
            elseif ($result.FailureKind -eq 'None') {
                $result.RetryDecision | Should -Be 'None'
            }
        }
    }
    
    Context "Synthetic tests" {
        It "Exit 0 returns None/None without analyzing text" {
            $errorText = @("ERROR: [youtube] abc: Private video")
            $result = Get-FailureKind -ExitCode 0 -ErrorText $errorText
            $result.FailureKind | Should -Be 'None'
            $result.RetryDecision | Should -Be 'None'
        }
        
        It "Exit 2 with parser error returns Configuration/Stop" {
            $errorText = @("yt-dlp.exe: error: no such option: --invalid")
            $result = Get-FailureKind -ExitCode 2 -ErrorText $errorText
            $result.FailureKind | Should -Be 'Configuration'
            $result.RetryDecision | Should -Be 'Stop'
            $result.Reason | Should -Be 'invalid yt-dlp option'
        }
        
        It "Exit 2 without parser error returns Unknown/Retry" {
            $errorText = @("Some random error")
            $result = Get-FailureKind -ExitCode 2 -ErrorText $errorText
            $result.FailureKind | Should -Be 'Unknown'
            $result.RetryDecision | Should -Be 'Retry'
        }
        
        It "Exit 1 with parser error line returns Unknown/Retry" {
            $errorText = @("yt-dlp.exe: error: no such option: --invalid")
            $result = Get-FailureKind -ExitCode 1 -ErrorText $errorText
            $result.FailureKind | Should -Be 'Unknown'
            $result.RetryDecision | Should -Be 'Retry'
        }
        
        It "Exit -1 returns Unknown/Retry" {
            $result = Get-FailureKind -ExitCode -1 -ErrorText @()
            $result.FailureKind | Should -Be 'Unknown'
            $result.RetryDecision | Should -Be 'Retry'
        }
        
        It "Exit 100 returns Unknown/Retry" {
            $result = Get-FailureKind -ExitCode 100 -ErrorText @()
            $result.FailureKind | Should -Be 'Unknown'
            $result.RetryDecision | Should -Be 'Retry'
        }
        
        It "Null ErrorText returns Unknown/Retry" {
            $result = Get-FailureKind -ExitCode 1 -ErrorText $null
            $result.FailureKind | Should -Be 'Unknown'
            $result.RetryDecision | Should -Be 'Retry'
        }
        
        It "Empty ErrorText array returns Unknown/Retry" {
            $result = Get-FailureKind -ExitCode 1 -ErrorText @()
            $result.FailureKind | Should -Be 'Unknown'
            $result.RetryDecision | Should -Be 'Retry'
        }
        
        It "WARNING lines are ignored in classification" {
            $errorText = @(
                "WARNING: [youtube] Some warning",
                "WARNING: [youtube] Another warning",
                "ERROR: [youtube] abc: Private video"
            )
            $result = Get-FailureKind -ExitCode 1 -ErrorText $errorText
            $result.FailureKind | Should -Be 'Permanent'
            $result.RetryDecision | Should -Be 'Stop'
        }
        
        It "Case-insensitive matching works" {
            $errorText = @("ERROR: [youtube] abc: PRIVATE VIDEO")
            $result = Get-FailureKind -ExitCode 1 -ErrorText $errorText
            $result.FailureKind | Should -Be 'Permanent'
            $result.RetryDecision | Should -Be 'Stop'
        }
        
        It "Evidence length is truncated to 300 characters" {
            $fixtureFile = Join-Path $PSScriptRoot "Fixtures\yt-dlp\age-restricted.txt"
            $content = Get-Content -LiteralPath $fixtureFile -Encoding UTF8 -Raw
            $lines = $content -split '\r?\n'
            $headerEndIndex = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^---\s*$') {
                    $headerEndIndex = $i
                    break
                }
            }
            $body = ($lines[($headerEndIndex+1)..($lines.Count-1)]) -join "`n"
            
            $result = Get-FailureKind -ExitCode 1 -ErrorText @($body)
            $result.Evidence.Length | Should -BeLessOrEqual 300
        }
        
        It "ID with hyphen is correctly matched for Private video" {
            $errorText = @("ERROR: [youtube] abcdefghij-: Private video")
            $result = Get-FailureKind -ExitCode 1 -ErrorText $errorText
            $result.FailureKind | Should -Be 'Permanent'
            $result.RetryDecision | Should -Be 'Stop'
        }
        
        It "Weak pattern: Private video + Video unavailable returns Permanent/Stop (no conflict)" {
            $errorText = @("ERROR: [youtube] abc: Private video. Video unavailable")
            $result = Get-FailureKind -ExitCode 1 -ErrorText $errorText
            $result.FailureKind | Should -Be 'Permanent'
            $result.RetryDecision | Should -Be 'Stop'
        }
        
        It "Weak pattern: TransportError + HTTP Error 404 returns Transient/Retry (no conflict)" {
            $errorText = @("ERROR: [youtube] abc: TransportError. HTTP Error 404: Not Found")
            $result = Get-FailureKind -ExitCode 1 -ErrorText $errorText
            $result.FailureKind | Should -Be 'Transient'
            $result.RetryDecision | Should -Be 'Retry'
        }
        
        It "Real conflict: Private video + HTTP Error 429 returns Unknown/Retry" {
            $errorText = @("ERROR: [youtube] abc: Private video. HTTP Error 429: Too Many Requests")
            $result = Get-FailureKind -ExitCode 1 -ErrorText $errorText
            $result.FailureKind | Should -Be 'Unknown'
            $result.RetryDecision | Should -Be 'Retry'
            $result.Reason | Should -Be 'conflicting evidence'
        }
        
        It "Embedded newlines in array element are split correctly" {
            $errorText = @("WARNING: test`r`nERROR: [youtube] abc: Private video")
            $result = Get-FailureKind -ExitCode 1 -ErrorText $errorText
            $result.FailureKind | Should -Be 'Permanent'
            $result.RetryDecision | Should -Be 'Stop'
        }
        
        It "ANSI escape codes are removed before pattern matching" {
            $errorText = @("ERROR: [youtube] abc: $([char]27)[31mPrivate video$([char]27)[0m")
            $result = Get-FailureKind -ExitCode 1 -ErrorText $errorText
            $result.FailureKind | Should -Be 'Permanent'
            $result.RetryDecision | Should -Be 'Stop'
        }
        
        It "ExitCode parameter is mandatory" {
            $attr = (Get-Command Get-FailureKind).Parameters['ExitCode'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
            $attr.Mandatory | Should -BeTrue
        }
    }
    
    Context "Fixture guard" {
        It "All fixtures have expected classifications and no extras" -ForEach $guardData {
            param($ExpectedNames, $ActualNames)
            
            foreach ($expected in $ExpectedNames) {
                $ActualNames | Should -Contain $expected
            }
            
            foreach ($actual in $ActualNames) {
                $ExpectedNames | Should -Contain $actual
            }
        }
    }
}

Describe 'Phase 4 - Delivery 2: FailureKind and RetryDecision' {
    BeforeAll {
        $script:OrigAppData = $env:APPDATA
        $env:APPDATA = $TestDrive
        
        $script:AppDir = Join-Path $env:APPDATA 'YT-DL-CLI'
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AppDir 'Logs') -Force | Out-Null
        
        . "$PSScriptRoot\..\Development\YT-Downloader.ps1"
        
        # Safety guard: ensure ManifestPath is under TestDrive
        $normalizedTestDrive = [System.IO.Path]::GetFullPath($TestDrive).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        $normalizedManifestPath = [System.IO.Path]::GetFullPath($script:ManifestPath)
        if (-not $normalizedManifestPath.StartsWith($normalizedTestDrive, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Safety check failed: ManifestPath '$script:ManifestPath' is not under TestDrive '$TestDrive'. Aborting to prevent data loss."
        }

        function script:ConvertFrom-JsonArray {
            param([string]$Json)
            $items = @(ConvertFrom-Json -InputObject $Json | ForEach-Object { $_ })
            return ,$items
        }
        
        function global:yt-dlp { }
        function global:ffprobe { }
        
        Mock Start-Sleep { }
        Mock Test-FileValidity { return $true }
        Mock Get-FileVerdict { return @{ Verdict = 'Valid'; Reason = 'OK' } }
        
        function script:New-LegacyItem {
            param([string]$Status = 'Pending', [string]$Id = ([guid]::NewGuid().ToString()))
            [PSCustomObject]@{
                Id = $Id
                Url = 'https://youtube.com/watch?v=AbC12345678'
                Mode = 'Video'
                MaxHeight = 720
                AudioFormat = ''
                Bitrate = 0
                Destination = $TestDrive
                Status = $Status
                Error = ''
                OutputFilePath = ''
                VideoId = 'AbC12345678'
                RetryCount = 0
                AttemptCount = 0
            }
        }
    }

    AfterAll {
        Remove-Item function:\yt-dlp -ErrorAction SilentlyContinue
        Remove-Item function:\ffprobe -ErrorAction SilentlyContinue
        $env:APPDATA = $script:OrigAppData
    }

    BeforeEach {
        $script:Config.MaxRetries = 3
        $script:RunState.ManifestSaved = $true
        if (Test-Path $script:ManifestPath) { Remove-Item $script:ManifestPath -Force }
        
        $script:ValidVideoPath = Join-Path $TestDrive 'valid_video.mp4'
        Set-Content -Path $script:ValidVideoPath -Value 'dummy video content' -Force
    }

    Context 'Normalize-FailureClassification' {
        It 'Returns Reason=Valid when both fields are canonical' {
            $r = Normalize-FailureClassification -Status 'Failed' -FailureKind 'Transient' -RetryDecision 'Retry'
            $r.FailureKind | Should -Be 'Transient'
            $r.RetryDecision | Should -Be 'Retry'
            $r.Reason | Should -Be 'Valid'
        }
        It 'Returns Reason=Default when both absent, Status=Failed' {
            $r = Normalize-FailureClassification -Status 'Failed' -FailureKind $null -RetryDecision $null
            $r.FailureKind | Should -Be 'Unknown'
            $r.RetryDecision | Should -Be 'Retry'
            $r.Reason | Should -Be 'Default'
        }
        It 'Returns Reason=Default when both absent, Status=Pending' {
            $r = Normalize-FailureClassification -Status 'Pending' -FailureKind $null -RetryDecision $null
            $r.FailureKind | Should -Be 'None'
            $r.RetryDecision | Should -Be 'None'
            $r.Reason | Should -Be 'Default'
        }
        It 'Returns Reason=Invalid for non-canonical FailureKind' {
            $r = Normalize-FailureClassification -Status 'Failed' -FailureKind 'permanent' -RetryDecision 'Retry'
            $r.FailureKind | Should -Be 'Unknown'
            $r.RetryDecision | Should -Be 'Retry'
            $r.Reason | Should -Be 'Invalid'
        }
        It 'Returns Reason=Invalid for non-canonical RetryDecision' {
            $r = Normalize-FailureClassification -Status 'Failed' -FailureKind 'Transient' -RetryDecision 'retry'
            $r.FailureKind | Should -Be 'Unknown'
            $r.RetryDecision | Should -Be 'Retry'
            $r.Reason | Should -Be 'Invalid'
        }
        It 'Returns Reason=Invalid for empty string FailureKind' {
            $r = Normalize-FailureClassification -Status 'Failed' -FailureKind '' -RetryDecision 'Retry'
            $r.FailureKind | Should -Be 'Unknown'
            $r.RetryDecision | Should -Be 'Retry'
            $r.Reason | Should -Be 'Invalid'
        }
        It 'Returns Reason=FailedNone for Failed + FailureKind=None' {
            $r = Normalize-FailureClassification -Status 'Failed' -FailureKind 'None' -RetryDecision 'Retry'
            $r.FailureKind | Should -Be 'Unknown'
            $r.RetryDecision | Should -Be 'Retry'
            $r.Reason | Should -Be 'FailedNone'
        }
        It 'Returns Reason=Success for Success status (ignores passed values)' {
            $r = Normalize-FailureClassification -Status 'Success' -FailureKind 'Transient' -RetryDecision 'Retry'
            $r.FailureKind | Should -Be 'None'
            $r.RetryDecision | Should -Be 'None'
            $r.Reason | Should -Be 'Success'
        }
        It 'Returns Reason=Default when only FailureKind absent' {
            $r = Normalize-FailureClassification -Status 'Failed' -FailureKind $null -RetryDecision 'Retry'
            $r.FailureKind | Should -Be 'Unknown'
            $r.RetryDecision | Should -Be 'Retry'
            $r.Reason | Should -Be 'Default'
        }
        It 'Returns Reason=Default when only RetryDecision absent' {
            $r = Normalize-FailureClassification -Status 'Pending' -FailureKind 'Transient' -RetryDecision $null
            $r.FailureKind | Should -Be 'None'
            $r.RetryDecision | Should -Be 'None'
            $r.Reason | Should -Be 'Default'
        }
    }

    Context 'Copy-Manifest' {
        It 'Adds FailureKind/RetryDecision to legacy items without them' {
            $item = New-LegacyItem -Status 'Pending'
            $res = Copy-Manifest -Source @($item)
            $res[0].FailureKind | Should -Be 'None'
            $res[0].RetryDecision | Should -Be 'None'
        }
        It 'Normalizes Failed legacy item to Unknown/Retry' {
            $item = New-LegacyItem -Status 'Failed'
            $res = Copy-Manifest -Source @($item)
            $res[0].FailureKind | Should -Be 'Unknown'
            $res[0].RetryDecision | Should -Be 'Retry'
        }
        It 'Normalizes invalid FailureKind to Unknown/Retry' {
            $item = New-LegacyItem -Status 'Failed'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'permanent'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Retry'
            $res = Copy-Manifest -Source @($item)
            $res[0].FailureKind | Should -Be 'Unknown'
            $res[0].RetryDecision | Should -Be 'Retry'
        }
        It 'Preserves valid FailureKind/RetryDecision' {
            $item = New-LegacyItem -Status 'Failed'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'Transient'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Retry'
            $res = Copy-Manifest -Source @($item)
            $res[0].FailureKind | Should -Be 'Transient'
            $res[0].RetryDecision | Should -Be 'Retry'
        }
        It 'Normalizes Success with stale values to None/None' {
            $item = New-LegacyItem -Status 'Success'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'Transient'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Retry'
            $res = Copy-Manifest -Source @($item)
            $res[0].FailureKind | Should -Be 'None'
            $res[0].RetryDecision | Should -Be 'None'
        }
        It 'Normalizes Failed + FailureKind=None to Unknown/Retry' {
            $item = New-LegacyItem -Status 'Failed'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'None'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'None'
            $res = Copy-Manifest -Source @($item)
            $res[0].FailureKind | Should -Be 'Unknown'
            $res[0].RetryDecision | Should -Be 'Retry'
        }
        It 'Corrupt fields: other item properties remain intact' {
            $item = New-LegacyItem -Status 'Failed'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'garbage'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'invalid'
            $res = Copy-Manifest -Source @($item)
            $res[0].FailureKind | Should -Be 'Unknown'
            $res[0].RetryDecision | Should -Be 'Retry'
            $res[0].Url | Should -Be 'https://youtube.com/watch?v=AbC12345678'
            $res[0].Mode | Should -Be 'Video'
            $res[0].Status | Should -Be 'Failed'
        }
        It 'JSON null values are treated as absent (Pending case)' {
            $json = '[{"Id":"00000000-0000-0000-0000-000000000001","Url":"https://youtube.com/watch?v=AbC12345678","Mode":"Video","MaxHeight":720,"AudioFormat":"","Bitrate":0,"Destination":"C:\\temp","Status":"Pending","Error":"","OutputFilePath":"","VideoId":"AbC12345678","RetryCount":0,"AttemptCount":0,"FailureKind":null,"RetryDecision":null}]'
            $parsed = ConvertFrom-JsonArray $json
            $res = Copy-Manifest -Source $parsed
            $res[0].FailureKind | Should -Be 'None'
            $res[0].RetryDecision | Should -Be 'None'
        }
        It 'JSON null values are treated as absent (Failed case)' {
            $json = '[{"Id":"00000000-0000-0000-0000-000000000001","Url":"https://youtube.com/watch?v=AbC12345678","Mode":"Video","MaxHeight":720,"AudioFormat":"","Bitrate":0,"Destination":"C:\\temp","Status":"Failed","Error":"","OutputFilePath":"","VideoId":"AbC12345678","RetryCount":0,"AttemptCount":0,"FailureKind":null,"RetryDecision":null}]'
            $parsed = ConvertFrom-JsonArray $json
            $res = Copy-Manifest -Source $parsed
            $res[0].FailureKind | Should -Be 'Unknown'
            $res[0].RetryDecision | Should -Be 'Retry'
        }
    }

    Context 'Initialize-App' {
        It 'Loads legacy manifest without FailureKind/RetryDecision and normalizes' {
            $item = New-LegacyItem -Status 'Failed'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            Initialize-App
            $script:Manifest[0].FailureKind | Should -Be 'Unknown'
            $script:Manifest[0].RetryDecision | Should -Be 'Retry'
        }
        It 'Preserves valid FailureKind/RetryDecision on load' {
            $item = New-LegacyItem -Status 'Failed'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'Transient'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Retry'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            Initialize-App
            $script:Manifest[0].FailureKind | Should -Be 'Transient'
            $script:Manifest[0].RetryDecision | Should -Be 'Retry'
        }
        It 'Round-trip: save and reload preserves values' {
            $item = New-LegacyItem -Status 'Failed'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'Permanent'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Stop'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            Initialize-App
            $script:Manifest[0].FailureKind | Should -Be 'Permanent'
            $script:Manifest[0].RetryDecision | Should -Be 'Stop'
        }
        It 'Manifest with corrupt FailureKind passes Test-ManifestSchema' {
            $item = New-LegacyItem -Status 'Failed'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'garbage'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Retry'
            Test-ManifestSchema -Data @($item) | Should -BeTrue
        }
        It 'Failed with Transient/Retry survives load, copy, save' {
            $item = New-LegacyItem -Status 'Failed'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'Transient'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Retry'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            Initialize-App
            $script:Manifest[0].FailureKind | Should -Be 'Transient'
            $script:Manifest[0].RetryDecision | Should -Be 'Retry'
            $copied = Copy-Manifest -Source $script:Manifest
            $copied[0].FailureKind | Should -Be 'Transient'
            $copied[0].RetryDecision | Should -Be 'Retry'
        }
        It 'JSON null values are treated as absent' {
            $testDest = Join-Path $TestDrive 'test_dest'
            New-Item -ItemType Directory -Path $testDest -Force | Out-Null
            
            $item = [ordered]@{
                Id = '00000000-0000-0000-0000-000000000001'
                Url = 'https://youtube.com/watch?v=AbC12345678'
                Mode = 'Video'
                MaxHeight = 720
                AudioFormat = ''
                Bitrate = 0
                Destination = $testDest
                Status = 'Failed'
                Error = ''
                OutputFilePath = ''
                VideoId = 'AbC12345678'
                RetryCount = 0
                AttemptCount = 0
                FailureKind = $null
                RetryDecision = $null
            }
            
            $json = ConvertTo-Json -InputObject @($item) -Depth 10
            $json.TrimStart() | Should -Match '^\['
            [System.IO.File]::WriteAllText($script:ManifestPath, $json, [System.Text.Encoding]::UTF8)
            
            Initialize-App
            $script:Manifest[0].FailureKind | Should -Be 'Unknown'
            $script:Manifest[0].RetryDecision | Should -Be 'Retry'
        }
        It 'Corrupt fields: other properties remain intact after Initialize-App' {
            $item = New-LegacyItem -Status 'Failed'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'garbage'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'invalid'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            Initialize-App
            $script:Manifest[0].FailureKind | Should -Be 'Unknown'
            $script:Manifest[0].RetryDecision | Should -Be 'Retry'
            $script:Manifest[0].Url | Should -Be 'https://youtube.com/watch?v=AbC12345678'
            $script:Manifest[0].Mode | Should -Be 'Video'
        }
        It 'Initialize-App warns on Invalid reason' {
            Mock Write-Log { }
            $item = New-LegacyItem -Status 'Failed'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'garbage'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'invalid'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            Initialize-App
            Should -Invoke -CommandName Write-Log -Times 1 -Exactly -ParameterFilter { 
                $Message -like '*(Reason: Invalid)*' 
            }
        }
        It 'Initialize-App warns on FailedNone reason' {
            Mock Write-Log { }
            $item = New-LegacyItem -Status 'Failed'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'None'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'None'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            Initialize-App
            Should -Invoke -CommandName Write-Log -Times 1 -Exactly -ParameterFilter { 
                $Message -like '*(Reason: FailedNone)*' 
            }
        }
        It 'Initialize-App is silent on Default reason (Pending)' {
            Mock Write-Log { }
            $item = New-LegacyItem -Status 'Pending'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            Initialize-App
            Should -Invoke -CommandName Write-Log -Times 0 -Exactly -ParameterFilter { 
                $Message -like '*(Reason:*' 
            }
        }
        It 'Initialize-App is silent on Success reason' {
            Mock Write-Log { }
            $item = New-LegacyItem -Status 'Success'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'Transient'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Retry'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            Initialize-App
            Should -Invoke -CommandName Write-Log -Times 0 -Exactly -ParameterFilter { 
                $Message -like '*(Reason:*' 
            }
        }
        It 'Initialize-App with Success plus stale/invalid values normalizes to None/None' {
            $item = New-LegacyItem -Status 'Success'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'garbage'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'invalid'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            Initialize-App
            $script:Manifest[0].FailureKind | Should -Be 'None'
            $script:Manifest[0].RetryDecision | Should -Be 'None'
        }
    }

    Context 'Set-ItemState with FailureKind/RetryDecision' {
        It 'Success clears to None/None regardless of passed values' {
            $item = New-LegacyItem -Status 'Pending'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'Transient'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Retry'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            Mock Test-FileValidity { return $true }
            $item.OutputFilePath = $script:ValidVideoPath
            $result = Set-ItemState -Item $item -Status 'Success' -OutputFilePath $item.OutputFilePath -FailureKind 'Transient' -RetryDecision 'Retry'
            $result | Should -BeTrue
            $item.FailureKind | Should -Be 'None'
            $item.RetryDecision | Should -Be 'None'
        }
        It 'Pending without passed fields gives None/None (no warning)' {
            Mock Write-Log { }
            $item = New-LegacyItem -Status 'Pending'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $result = Set-ItemState -Item $item -Status 'Pending'
            $result | Should -BeTrue
            $item.FailureKind | Should -Be 'None'
            $item.RetryDecision | Should -Be 'None'
            Should -Invoke -CommandName Write-Log -Times 0 -Exactly -ParameterFilter {
                $Message -like '*WARNING*FailureKind*'
            }
        }
        It 'Downloading without passed fields gives None/None' {
            $item = New-LegacyItem -Status 'Pending'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $result = Set-ItemState -Item $item -Status 'Downloading'
            $result | Should -BeTrue
            $item.FailureKind | Should -Be 'None'
            $item.RetryDecision | Should -Be 'None'
        }
        It 'Downloading with passed Transient/Retry is overridden to None/None' {
            $item = New-LegacyItem -Status 'Pending'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $result = Set-ItemState -Item $item -Status 'Downloading' -FailureKind 'Transient' -RetryDecision 'Retry'
            $result | Should -BeTrue
            $item.FailureKind | Should -Be 'None'
            $item.RetryDecision | Should -Be 'None'
        }
        It 'Failed without passed fields gives Unknown/Retry and logs warning' {
            Mock Write-Log { }
            $item = New-LegacyItem -Status 'Pending'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $result = Set-ItemState -Item $item -Status 'Failed'
            $result | Should -BeTrue
            $item.FailureKind | Should -Be 'Unknown'
            $item.RetryDecision | Should -Be 'Retry'
            Should -Invoke -CommandName Write-Log -Times 1 -Exactly -ParameterFilter {
                $Message -like '*WARNING*Failed without FailureKind*'
            }
        }
        It 'Failed with valid passed values stores them' {
            $item = New-LegacyItem -Status 'Pending'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $result = Set-ItemState -Item $item -Status 'Failed' -FailureKind 'Permanent' -RetryDecision 'Stop'
            $result | Should -BeTrue
            $item.FailureKind | Should -Be 'Permanent'
            $item.RetryDecision | Should -Be 'Stop'
        }
        It 'Pending with passed Transient/Retry is overridden to None/None' {
            $item = New-LegacyItem -Status 'Pending'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $result = Set-ItemState -Item $item -Status 'Pending' -FailureKind 'Transient' -RetryDecision 'Retry'
            $result | Should -BeTrue
            $item.FailureKind | Should -Be 'None'
            $item.RetryDecision | Should -Be 'None'
        }
        It 'Only FailureKind passed: keeps it, fills RetryDecision=Retry, logs warning' {
            Mock Write-Log { }
            $item = New-LegacyItem -Status 'Failed'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $result = Set-ItemState -Item $item -Status 'Failed' -FailureKind 'Permanent'
            $result | Should -BeTrue
            $item.FailureKind | Should -Be 'Permanent'
            $item.RetryDecision | Should -Be 'Retry'
            Should -Invoke -CommandName Write-Log -Times 1 -Exactly -ParameterFilter {
                $Message -like '*WARNING*Only one of FailureKind*'
            }
        }
        It 'Only RetryDecision passed: fills FailureKind=Unknown, keeps it, logs warning' {
            Mock Write-Log { }
            $item = New-LegacyItem -Status 'Failed'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $result = Set-ItemState -Item $item -Status 'Failed' -RetryDecision 'Stop'
            $result | Should -BeTrue
            $item.FailureKind | Should -Be 'Unknown'
            $item.RetryDecision | Should -Be 'Stop'
            Should -Invoke -CommandName Write-Log -Times 1 -Exactly -ParameterFilter {
                $Message -like '*WARNING*Only one of FailureKind*'
            }
        }
        It 'Rejects non-canonical FailureKind (return $false, no save, no memory change, Status unchanged)' {
            $item = New-LegacyItem -Status 'Pending'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'Transient'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Retry'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $before = Get-Content -Path $script:ManifestPath -Raw
            $result = Set-ItemState -Item $item -Status 'Failed' -FailureKind 'permanent' -RetryDecision 'Retry'
            $result | Should -BeFalse
            $after = Get-Content -Path $script:ManifestPath -Raw
            $after | Should -Be $before
            $item.FailureKind | Should -Be 'Transient'
            $item.RetryDecision | Should -Be 'Retry'
            $item.Status | Should -Be 'Pending'
        }
        It 'Rejects non-canonical RetryDecision (return $false, no save, no memory change, Status unchanged)' {
            $item = New-LegacyItem -Status 'Pending'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'Transient'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Retry'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $before = Get-Content -Path $script:ManifestPath -Raw
            $result = Set-ItemState -Item $item -Status 'Failed' -FailureKind 'Transient' -RetryDecision 'retry'
            $result | Should -BeFalse
            $after = Get-Content -Path $script:ManifestPath -Raw
            $after | Should -Be $before
            $item.FailureKind | Should -Be 'Transient'
            $item.RetryDecision | Should -Be 'Retry'
            $item.Status | Should -Be 'Pending'
        }
        It 'Rejects non-canonical FailureKind alone (Status=Pending, no save, no memory change)' {
            $item = New-LegacyItem -Status 'Pending'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'Transient'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Retry'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $before = Get-Content -Path $script:ManifestPath -Raw
            $result = Set-ItemState -Item $item -Status 'Pending' -FailureKind 'permanent'
            $result | Should -BeFalse
            $after = Get-Content -Path $script:ManifestPath -Raw
            $after | Should -Be $before
            $item.Status | Should -Be 'Pending'
            $item.FailureKind | Should -Be 'Transient'
            $item.RetryDecision | Should -Be 'Retry'
        }
        It 'Rejects non-canonical RetryDecision alone (Status=Pending, no save, no memory change)' {
            $item = New-LegacyItem -Status 'Pending'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'Transient'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Retry'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $before = Get-Content -Path $script:ManifestPath -Raw
            $result = Set-ItemState -Item $item -Status 'Pending' -RetryDecision 'retry'
            $result | Should -BeFalse
            $after = Get-Content -Path $script:ManifestPath -Raw
            $after | Should -Be $before
            $item.Status | Should -Be 'Pending'
            $item.FailureKind | Should -Be 'Transient'
            $item.RetryDecision | Should -Be 'Retry'
        }
        It 'Rejects non-canonical FailureKind alone (Status=Failed, no save, no memory change)' {
            $item = New-LegacyItem -Status 'Pending'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'Transient'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Retry'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $before = Get-Content -Path $script:ManifestPath -Raw
            $result = Set-ItemState -Item $item -Status 'Failed' -FailureKind 'permanent'
            $result | Should -BeFalse
            $after = Get-Content -Path $script:ManifestPath -Raw
            $after | Should -Be $before
            $item.Status | Should -Be 'Pending'
            $item.FailureKind | Should -Be 'Transient'
            $item.RetryDecision | Should -Be 'Retry'
        }
        It 'Rejects non-canonical RetryDecision alone (Status=Failed, no save, no memory change)' {
            $item = New-LegacyItem -Status 'Pending'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'Transient'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Retry'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $before = Get-Content -Path $script:ManifestPath -Raw
            $result = Set-ItemState -Item $item -Status 'Failed' -RetryDecision 'retry'
            $result | Should -BeFalse
            $after = Get-Content -Path $script:ManifestPath -Raw
            $after | Should -Be $before
            $item.Status | Should -Be 'Pending'
            $item.FailureKind | Should -Be 'Transient'
            $item.RetryDecision | Should -Be 'Retry'
        }
        It 'Adds FailureKind/RetryDecision to legacy item without them' {
            $item = New-LegacyItem -Status 'Pending'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $item.PSObject.Properties.Name | Should -Not -Contain 'FailureKind'
            $result = Set-ItemState -Item $item -Status 'Pending'
            $result | Should -BeTrue
            $item.FailureKind | Should -Be 'None'
            $item.RetryDecision | Should -Be 'None'
        }
        It 'Failed + FailureKind=None passed normalizes to Unknown/Retry' {
            $item = New-LegacyItem -Status 'Pending'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $result = Set-ItemState -Item $item -Status 'Failed' -FailureKind 'None' -RetryDecision 'None'
            $result | Should -BeTrue
            $item.FailureKind | Should -Be 'Unknown'
            $item.RetryDecision | Should -Be 'Retry'
        }
        It 'Unrecognized Status: Set-ItemState returns $false (schema rejects it)' {
            $item = New-LegacyItem -Status 'Pending'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'Transient'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Retry'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $result = Set-ItemState -Item $item -Status 'WeirdStatus'
            $result | Should -BeFalse
            $item.FailureKind | Should -Be 'Transient'
            $item.RetryDecision | Should -Be 'Retry'
            $item.Status | Should -Be 'Pending'
        }
    }

    Context 'Get-RetryPlan clears fields' {
        It 'Clears FailureKind/RetryDecision on rescheduling' {
            $item = New-LegacyItem -Status 'Failed'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'Transient'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Retry'
            $item.AttemptCount = 1
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            $plan = Get-RetryPlan -Manifest $script:Manifest
            $plan.ItemsToRun.Count | Should -Be 1
            $plan.ItemsToRun[0].FailureKind | Should -Be 'None'
            $plan.ItemsToRun[0].RetryDecision | Should -Be 'None'
        }
        It 'Invalid VideoId marks item Failed with Permanent/Stop while keeping valid item' {
            $bad = [guid]::NewGuid().ToString()
            $good = [guid]::NewGuid().ToString()
            $manifest = @(
                [PSCustomObject]@{ Id=$bad; Url='https://example.com/video'; Mode='Video'; MaxHeight=720; AudioFormat=''; Bitrate=0; Destination=$TestDrive; Status='Failed'; Error=''; OutputFilePath=''; VideoId=''; RetryCount=0; AttemptCount=1; FailureKind='Transient'; RetryDecision='Retry' },
                [PSCustomObject]@{ Id=$good; Url='https://youtube.com/watch?v=AbC12345678'; Mode='Video'; MaxHeight=720; AudioFormat=''; Bitrate=0; Destination=$TestDrive; Status='Failed'; Error=''; OutputFilePath=''; VideoId='AbC12345678'; RetryCount=0; AttemptCount=1; FailureKind='Transient'; RetryDecision='Retry' }
            )
            $plan = Get-RetryPlan -Manifest $manifest
            $plan.ItemsToRun.Count | Should -Be 1
            $plan.ItemsToRun[0].Id | Should -Be $good
            $badEntry = @($plan.ModifiedManifest) | Where-Object { $_.Id -eq $bad }
            $badEntry.Status | Should -Be 'Failed'
            $badEntry.Error | Should -Be 'Invalid YouTube URL / VideoId'
            $badEntry.FailureKind | Should -Be 'Permanent'
            $badEntry.RetryDecision | Should -Be 'Stop'
        }
    }

    Context 'Interrupt handlers' {
        It 'Start-DownloadRun handler sets Unknown/Retry on Downloading items (assert on saved file)' {
            $item = New-LegacyItem -Status 'Pending'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'None'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'None'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            
            # Ensure StateInitialized is true so the finally block runs
            $script:StateInitialized = $true
            $script:StateInitialized | Should -BeTrue
            
            # Mocks to prevent side effects
            Mock Save-Settings { return $true }
            Mock Test-HibernateEligibility { return $false }
            Mock Invoke-Hibernation { }
            
            $script:reachedDownloading = $false
            $script:capturedItemId = $null
            Mock Invoke-ItemDownload {
                param([PSCustomObject]$Item)
                $script:capturedItemId = $Item.Id
                Set-ItemState -Item $Item -Status 'Downloading'
                $script:reachedDownloading = $true
                throw 'Simulated interruption'
            }
            Mock Read-Host { return '' }
            
            Start-DownloadRun -Items @($item) -IsResume $true
            
            Should -Invoke -CommandName Invoke-ItemDownload -Times 1 -Exactly
            $script:capturedItemId | Should -Be $item.Id
            $script:reachedDownloading | Should -BeTrue
            
            $saved = ConvertFrom-JsonArray (Get-Content -Path $script:ManifestPath -Raw)
            $saved[0].Status | Should -Be 'Failed'
            $saved[0].Error | Should -Be 'Interrupted'
            $saved[0].FailureKind | Should -Be 'Unknown'
            $saved[0].RetryDecision | Should -Be 'Retry'
        }
        It 'Global interrupt handler sets Unknown/Retry (static check)' {
            $scriptPath = Join-Path $PSScriptRoot '..\Development\YT-Downloader.ps1'
            $content = Get-Content -LiteralPath $scriptPath -Raw
            $pattern = "\`$item\.Error = 'Global interrupt'[\s\r\n]+\`$item\.FailureKind = 'Unknown'[\s\r\n]+\`$item\.RetryDecision = 'Retry'"
            $content | Should -Match $pattern
        }
    }

    Context 'Startup Success to Pending' {
        It 'Success to Pending clears FailureKind/RetryDecision via Start-DownloadRun' {
            $item = New-LegacyItem -Status 'Success'
            $item | Add-Member -NotePropertyName FailureKind -NotePropertyValue 'Transient'
            $item | Add-Member -NotePropertyName RetryDecision -NotePropertyValue 'Retry'
            $item.OutputFilePath = 'C:\nonexistent.mp4'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            
            $script:StateInitialized = $true
            
            # Mocks to prevent side effects
            Mock Save-Settings { return $true }
            Mock Test-HibernateEligibility { return $false }
            Mock Invoke-Hibernation { }
            
            Mock Test-FileValidity {
                param([string]$FilePath, [string]$Mode)
                return $false
            }
            
            $script:capturedStatus = $null
            $script:capturedFailureKind = $null
            $script:capturedRetryDecision = $null
            Mock Invoke-ItemDownload {
                param([PSCustomObject]$Item)
                $script:capturedStatus = $Item.Status
                $script:capturedFailureKind = $Item.FailureKind
                $script:capturedRetryDecision = $Item.RetryDecision
                return $true
            }
            Mock Read-Host { return '' }
            
            Start-DownloadRun -Items @($item) -IsResume $true
            
            Should -Invoke -CommandName Test-FileValidity -Times 1 -Exactly -ParameterFilter { 
                $FilePath -eq 'C:\nonexistent.mp4' 
            }
            Should -Invoke -CommandName Invoke-ItemDownload -Times 1 -Exactly
            
            $script:capturedStatus | Should -Be 'Pending'
            $script:capturedFailureKind | Should -Be 'None'
            $script:capturedRetryDecision | Should -Be 'None'
            
            $saved = ConvertFrom-JsonArray (Get-Content -Path $script:ManifestPath -Raw)
            $saved[0].Status | Should -Be 'Pending'
            $saved[0].FailureKind | Should -Be 'None'
            $saved[0].RetryDecision | Should -Be 'None'
        }
    }

    Context 'Construction sites' {
        It 'All six new-item construction sites include FailureKind/RetryDecision' {
            $scriptPath = Join-Path $PSScriptRoot '..\Development\YT-Downloader.ps1'
            $content = Get-Content -LiteralPath $scriptPath -Raw
            $regexMatches = [regex]::Matches($content, "FailureKind='None';\s*RetryDecision='None'")
            $regexMatches.Count | Should -Be 6
        }
        It 'No construction site ends with AttemptCount=0 without the new fields' {
            $scriptPath = Join-Path $PSScriptRoot '..\Development\YT-Downloader.ps1'
            $content = Get-Content -LiteralPath $scriptPath -Raw
            $badPattern = 'AttemptCount=0\s*\}'
            $badMatches = [regex]::Matches($content, $badPattern)
            $badMatches.Count | Should -Be 0
        }
    }

    Context 'Saved JSON' {
        It 'Saved JSON contains both FailureKind and RetryDecision properties after Set-ItemState' {
            $item = New-LegacyItem -Status 'Pending'
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            
            Set-ItemState -Item $item -Status 'Failed' -FailureKind 'Transient' -RetryDecision 'Retry'
            
            $raw = Get-Content -Path $script:ManifestPath -Raw
            $raw | Should -Match '"FailureKind"'
            $raw | Should -Match '"RetryDecision"'
            
            $parsed = ConvertFrom-JsonArray $raw
            $parsed[0].FailureKind | Should -Be 'Transient'
            $parsed[0].RetryDecision | Should -Be 'Retry'
        }
        It 'Legacy manifest saved without data loss after Initialize-App (all 13 properties preserved)' {
            $item = New-LegacyItem -Status 'Failed'
            $originalValues = @{
                Id = $item.Id
                Url = $item.Url
                Mode = $item.Mode
                MaxHeight = $item.MaxHeight
                AudioFormat = $item.AudioFormat
                Bitrate = $item.Bitrate
                Destination = $item.Destination
                Status = $item.Status
                Error = $item.Error
                OutputFilePath = $item.OutputFilePath
                VideoId = $item.VideoId
                RetryCount = $item.RetryCount
                AttemptCount = $item.AttemptCount
            }
            
            $script:Manifest = @($item)
            Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest
            
            Initialize-App
            
            Set-ItemState -Item $script:Manifest[0] -Status 'Failed' -Error 'Test error'
            
            $raw = Get-Content -Path $script:ManifestPath -Raw
            $parsed = ConvertFrom-JsonArray $raw
            $parsed.Count | Should -Be 1
            
            $parsed[0].Status | Should -Be 'Failed'
            $parsed[0].Error | Should -Be 'Test error'
            
            $propertiesToCompare = @('Id', 'Url', 'Mode', 'MaxHeight', 'AudioFormat', 'Bitrate', 
                                     'Destination', 'OutputFilePath', 'VideoId', 'RetryCount', 'AttemptCount')
            foreach ($prop in $propertiesToCompare) {
                $parsed[0].$prop | Should -Be $originalValues[$prop]
            }
            
            $parsed[0].PSObject.Properties.Name | Should -Contain 'FailureKind'
            $parsed[0].PSObject.Properties.Name | Should -Contain 'RetryDecision'
            $parsed[0].FailureKind | Should -Be 'Unknown'
            $parsed[0].RetryDecision | Should -Be 'Retry'
        }
    }
}

# =====================================================================
# Phase 4 - Delivery 3: FINAL BLOCK
# Covers A1-A17, F10b, F13, F14, F16, F17, F30.
# Apply after the closing '}' of 'Describe "Phase 4 - Delivery 2: ..."'
# =====================================================================


# ---------------------------------------------------------------------
# 1. Pure helpers: Add-CapturedLine (A1), Get-VerdictFailureClass (A3),
#    Fixture roundtrip (A2), ANSI prefix (F17b)
# ---------------------------------------------------------------------
Describe 'Phase 4 - Delivery 3: Pure helpers' {

    BeforeDiscovery {
        $fixturesDir = Join-Path $PSScriptRoot 'Fixtures\yt-dlp'
        $expectedTable = @{
            'success-baseline'    = @{ FailureKind = 'None';          RetryDecision = 'None' }
            'private-video'       = @{ FailureKind = 'Permanent';     RetryDecision = 'Stop' }
            'invalid-id-truncated'= @{ FailureKind = 'Permanent';     RetryDecision = 'Stop' }
            'age-restricted'      = @{ FailureKind = 'Configuration'; RetryDecision = 'Stop' }
            'format-unavailable'  = @{ FailureKind = 'Configuration'; RetryDecision = 'Stop' }
            'bad-option'          = @{ FailureKind = 'Configuration'; RetryDecision = 'Stop' }
            'deleted-video'       = @{ FailureKind = 'Unknown';       RetryDecision = 'Retry' }
            'nonexistent-id'      = @{ FailureKind = 'Unknown';       RetryDecision = 'Retry' }
            'no-network'          = @{ FailureKind = 'Transient';     RetryDecision = 'Retry' }
            'http-429'            = @{ FailureKind = 'Transient';     RetryDecision = 'Retry' }
            'http-500'            = @{ FailureKind = 'Transient';     RetryDecision = 'Retry' }
            'http-503'            = @{ FailureKind = 'Transient';     RetryDecision = 'Retry' }
            'http-404'            = @{ FailureKind = 'Unknown';       RetryDecision = 'Retry' }
        }
        $script:A2Cases = @()
        foreach ($file in (Get-ChildItem -LiteralPath $fixturesDir -Filter '*.txt' -File)) {
            $raw = Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Raw
            $lines = $raw -split '\r?\n'
            $sep = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^---\s*$') { $sep = $i; break }
            }
            if ($sep -lt 0) { continue }
            $exitMatch = [regex]::Match(($lines[0..($sep-1)] -join "`n"), 'exit code:\s*(-?\d+)')
            if (-not $exitMatch.Success) { continue }
            $caseName = $file.BaseName
            if (-not $expectedTable.ContainsKey($caseName)) { continue }
            $script:A2Cases += @{
                CaseName  = $caseName
                ExitCode  = [int]$exitMatch.Groups[1].Value
                BodyLines = @($lines[($sep + 1)..($lines.Count - 1)])
                Expected  = $expectedTable[$caseName]
            }
        }
    }

    BeforeAll {
        $script:OrigAppData = $env:APPDATA
        $env:APPDATA = $TestDrive
        $script:AppDir = Join-Path $env:APPDATA 'YT-DL-CLI'
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AppDir 'Logs') -Force | Out-Null
        . "$PSScriptRoot\..\Development\YT-Downloader.ps1"
    }
    AfterAll { $env:APPDATA = $script:OrigAppData }

    # ---------- A1: Add-CapturedLine ----------
    It 'A1a Add-CapturedLine: null and empty inputs are ignored' {
        $q = New-Object 'System.Collections.Generic.Queue[string]'
        Add-CapturedLine -Queue $q -Line $null
        Add-CapturedLine -Queue $q -Line ''
        Add-CapturedLine -Queue $q -Line '   '
        $q.Count | Should -Be 0
    }
    It 'A1b Add-CapturedLine: non-matching lines are dropped' {
        $q = New-Object 'System.Collections.Generic.Queue[string]'
        Add-CapturedLine -Queue $q -Line 'just info'
        Add-CapturedLine -Queue $q -Line '[debug] downloading'
        $q.Count | Should -Be 0
    }
    It 'A1c Add-CapturedLine: ERROR, WARNING, and yt-dlp parser lines are kept' {
        $q = New-Object 'System.Collections.Generic.Queue[string]'
        Add-CapturedLine -Queue $q -Line 'ERROR: [youtube] abc: Private video'
        Add-CapturedLine -Queue $q -Line 'WARNING: something'
        Add-CapturedLine -Queue $q -Line 'yt-dlp.exe: error: no such option: --x'
        $q.Count | Should -Be 3
    }
    It 'A1d Add-CapturedLine: cap 200 keeps the tail' {
        $q = New-Object 'System.Collections.Generic.Queue[string]'
        for ($i = 1; $i -le 250; $i++) { Add-CapturedLine -Queue $q -Line "ERROR: line $i" }
        $q.Count | Should -Be 200
        $q.Peek() | Should -Match 'line 51$'
    }
    It 'A1e Add-CapturedLine: truncates to 1000 chars' {
        $q = New-Object 'System.Collections.Generic.Queue[string]'
        Add-CapturedLine -Queue $q -Line ('ERROR: ' + ('x' * 2000))
        $q.Peek().Length | Should -Be 1000
    }
    It 'A1f Add-CapturedLine: ErrorRecord input is coerced via string' {
        $q = New-Object 'System.Collections.Generic.Queue[string]'
        $ex  = [System.Exception]::new('ERROR: fake')
        $err = [System.Management.Automation.ErrorRecord]::new($ex, 'id', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        Add-CapturedLine -Queue $q -Line $err
        $q.Count | Should -Be 1
        $q.Peek() | Should -Match 'ERROR: fake'
    }

    # ---------- A3: Get-VerdictFailureClass ----------
    It 'A3a Corrupt -> Transient/Retry' {
        $r = Get-VerdictFailureClass -Outcome Corrupt
        $r.FailureKind | Should -Be 'Transient'; $r.RetryDecision | Should -Be 'Retry'
    }
    It 'A3b QuarantineFailed -> Unknown/Retry' {
        $r = Get-VerdictFailureClass -Outcome QuarantineFailed
        $r.FailureKind | Should -Be 'Unknown'; $r.RetryDecision | Should -Be 'Retry'
    }
    It 'A3c NoOutput -> Unknown/Retry' {
        $r = Get-VerdictFailureClass -Outcome NoOutput
        $r.FailureKind | Should -Be 'Unknown'; $r.RetryDecision | Should -Be 'Retry'
    }
    It 'A3d OtherMode Case A -> Configuration/Stop' {
        $r = Get-VerdictFailureClass -Outcome OtherMode -Case A
        $r.FailureKind | Should -Be 'Configuration'; $r.RetryDecision | Should -Be 'Stop'
    }
    It 'A3e OtherMode Case C -> Unknown/Retry' {
        $r = Get-VerdictFailureClass -Outcome OtherMode -Case C
        $r.FailureKind | Should -Be 'Unknown'; $r.RetryDecision | Should -Be 'Retry'
    }
    It 'A3f Unknown with ffprobe missing -> Configuration/Stop' {
        $r = Get-VerdictFailureClass -Outcome Unknown -FfprobeAvailable $false
        $r.FailureKind | Should -Be 'Configuration'; $r.RetryDecision | Should -Be 'Stop'
    }
    It 'A3g Unknown with ffprobe present -> Unknown/Retry' {
        $r = Get-VerdictFailureClass -Outcome Unknown -FfprobeAvailable $true
        $r.FailureKind | Should -Be 'Unknown'; $r.RetryDecision | Should -Be 'Retry'
    }

    # ---------- A2: Fixture roundtrip through Add-CapturedLine ----------
    It 'A2 capture roundtrip (<CaseName>) preserves classification' -ForEach $script:A2Cases {
        $q = New-Object 'System.Collections.Generic.Queue[string]'
        foreach ($line in $BodyLines) { Add-CapturedLine -Queue $q -Line $line }
        $captured = Get-FailureKind -ExitCode $ExitCode -ErrorText @($q.ToArray())
        $full     = Get-FailureKind -ExitCode $ExitCode -ErrorText @($BodyLines)
        $captured.FailureKind   | Should -Be $full.FailureKind
        $captured.RetryDecision | Should -Be $full.RetryDecision
        $captured.FailureKind   | Should -Be $Expected.FailureKind
        $captured.RetryDecision | Should -Be $Expected.RetryDecision
    }

    # ---------- F17b: ANSI prefix ----------
    It 'F17b ANSI-prefixed ERROR: line passes Add-CapturedLine and classifies' {
        $q = New-Object 'System.Collections.Generic.Queue[string]'
        $ansiLine = "$([char]27)[31mERROR: [youtube] abc: Private video$([char]27)[0m"
        Add-CapturedLine -Queue $q -Line $ansiLine
        $q.Count | Should -Be 1
        $r = Get-FailureKind -ExitCode 1 -ErrorText @($q.ToArray())
        $r.FailureKind   | Should -Be 'Permanent'
        $r.RetryDecision | Should -Be 'Stop'
    }
}


# ---------------------------------------------------------------------
# 2. Invoke-ItemDownload behavior (A4-A11, A13, A15, A16, F10b, F17a)
# ---------------------------------------------------------------------
Describe 'Phase 4 - Delivery 3: Invoke-ItemDownload behavior' {

    BeforeAll {
        $script:OrigAppData = $env:APPDATA
        $env:APPDATA = $TestDrive
        $script:AppDir = Join-Path $env:APPDATA 'YT-DL-CLI'
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AppDir 'Logs') -Force | Out-Null

        . "$PSScriptRoot\..\Development\YT-Downloader.ps1"
        function global:yt-dlp { }
        function global:ffprobe { }
        Mock Start-Sleep { }

        function script:Install-YtDlpFixtureMock {
            param([string]$FixtureName)
            $fxDir = Join-Path $PSScriptRoot 'Fixtures\yt-dlp'
            $raw   = Get-Content -LiteralPath (Join-Path $fxDir "$FixtureName.txt") -Encoding UTF8 -Raw
            $lines = $raw -split '\r?\n'
            $sep   = -1
            for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^---\s*$') { $sep = $i; break } }
            $body  = @($lines[($sep + 1)..($lines.Count - 1)])
            $exit  = [int]([regex]::Match(($lines[0..($sep-1)] -join "`n"), 'exit code:\s*(-?\d+)').Groups[1].Value)
            $script:FxExit = $exit
            $script:FxBody = $body
            Mock yt-dlp {
                $global:LASTEXITCODE = $script:FxExit
                foreach ($l in $script:FxBody) { $l }
            }
        }

        function script:New-TestItem {
            param(
                [string]$Mode = 'Video',
                [int]$MaxHeight = 720,
                [string]$Destination = $null
            )
            if (-not $Destination) { $Destination = Join-Path $TestDrive 'dest' }
            if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
            [PSCustomObject]@{
                Id             = [guid]::NewGuid().ToString()
                Url            = 'https://youtube.com/watch?v=AbC12345678'
                Mode           = $Mode
                MaxHeight      = $MaxHeight
                AudioFormat    = 'MP3'
                Bitrate        = 128
                Destination    = $Destination
                Status         = 'Pending'
                Error          = ''
                OutputFilePath = ''
                VideoId        = 'AbC12345678'
                RetryCount     = 0
                AttemptCount   = 0
                FailureKind    = 'None'
                RetryDecision  = 'None'
            }
        }

        function script:Set-ManifestForItem {
            param($Item)
            $script:Manifest = @($Item)
            [void](Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest)
        }
    }

    AfterAll {
        Remove-Item function:\yt-dlp  -ErrorAction SilentlyContinue
        Remove-Item function:\ffprobe -ErrorAction SilentlyContinue
        $env:APPDATA = $script:OrigAppData
    }

    BeforeEach {
        $script:Config.MaxRetries = 3
        if (Test-Path $script:ManifestPath) { Remove-Item $script:ManifestPath -Force }
    }


    # ---------- Sanity: fixture mock registers ----------
    It 'A4-pre sanity: fixture mock intercepts yt-dlp' -Tag FixtureSanity {
        Install-YtDlpFixtureMock -FixtureName 'private-video'
        $global:LASTEXITCODE = $null
        & yt-dlp 'https://example.invalid/watch?v=x' 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 1
        Should -Invoke yt-dlp -Times 1 -Exactly
    }

    # ---------- A4: private video, 1 attempt, Permanent/Stop ----------
    It 'A4 private video -> Permanent/Stop, 1 attempt, retry-skipped message' {
        Install-YtDlpFixtureMock -FixtureName 'private-video'
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        Should -Invoke yt-dlp -Times 1 -Exactly
        $item.Status         | Should -Be 'Failed'
        $item.FailureKind    | Should -Be 'Permanent'
        $item.RetryDecision  | Should -Be 'Stop'
        $item.Error          | Should -Match 'retry skipped \(FailureKind=Permanent, attempt 1/4\)'
    }

    # ---------- A5: format-unavailable and bad-option, Configuration/Stop ----------
    It 'A5a format-unavailable -> Configuration/Stop, 1 attempt' {
        Install-YtDlpFixtureMock -FixtureName 'format-unavailable'
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        Should -Invoke yt-dlp -Times 1 -Exactly
        $item.FailureKind   | Should -Be 'Configuration'
        $item.RetryDecision | Should -Be 'Stop'
    }
    It 'A5b bad-option (exit 2) -> Configuration/Stop, 1 attempt' {
        Install-YtDlpFixtureMock -FixtureName 'bad-option'
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        Should -Invoke yt-dlp -Times 1 -Exactly
        $item.FailureKind   | Should -Be 'Configuration'
        $item.RetryDecision | Should -Be 'Stop'
    }

    # ---------- A6: no-network, 4 attempts, Transient/Retry ----------
    It 'A6 no-network -> Transient/Retry, 4 attempts, exhaustion message' {
        Install-YtDlpFixtureMock -FixtureName 'no-network'
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        Should -Invoke yt-dlp -Times 4 -Exactly
        $item.FailureKind   | Should -Be 'Transient'
        $item.RetryDecision | Should -Be 'Retry'
        $item.Error         | Should -Match 'attempt budget 4/4 exhausted'
    }

    # ---------- A7: deleted-video, 4 attempts, Unknown/Retry ----------
    It 'A7 deleted-video -> Unknown/Retry, 4 attempts' {
        Install-YtDlpFixtureMock -FixtureName 'deleted-video'
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        Should -Invoke yt-dlp -Times 4 -Exactly
        $item.FailureKind   | Should -Be 'Unknown'
        $item.RetryDecision | Should -Be 'Retry'
    }

    # ---------- A8: Test-3, Case C OtherMode then Case A OtherMode ----------
    It 'A8 Case C OtherMode then Case A OtherMode -> 2 attempts, Configuration/Stop' {
        $script:ytCall = 0
        $script:retryFile = Join-Path (Join-Path $TestDrive 'dest') 'retry_AbC12345678.m4a'
        Mock yt-dlp {
            $script:ytCall++
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                'AbC12345678' | Out-File -FilePath $args[$i+2] -Encoding UTF8
                if ($script:ytCall -ge 2) {
                    Set-Content -Path $script:retryFile -Value 'x' -Force
                    $script:retryFile | Out-File -FilePath $args[$i+5] -Encoding UTF8
                }
            }
        }
        Mock Test-IdInArchive { @{ Status = 'Found' } }
        Mock Find-OutputCandidates {
            @([PSCustomObject]@{
                File    = [PSCustomObject]@{ Name='a_AbC12345678.mp4'; FullName='x'; LastWriteTimeUtc=(Get-Date).ToUniversalTime() }
                Verdict = 'OtherMode'
                Reason  = 'contains video stream'
            })
        }
        Mock Remove-VideoIdFromArchive { $true }
        Mock Get-FileVerdict { @{ Verdict='OtherMode'; Reason='contains video stream' } }
        Mock Test-FfprobeAvailable { $true }
        Mock Write-Log { }
        $item = New-TestItem -Mode 'Audio' -MaxHeight 0
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        Should -Invoke yt-dlp -Times 2 -Exactly
        $item.FailureKind   | Should -Be 'Configuration'
        $item.RetryDecision | Should -Be 'Stop'
        $item.AttemptCount  | Should -Be 2
        $item.Error         | Should -Match 'attempt 2/4'
    }

    # ---------- A9: Case A Unknown, ffprobe missing vs present ----------
    It 'A9a Case A Unknown, ffprobe missing -> Configuration/Stop, 1 attempt' {
        $script:goodFile = Join-Path (Join-Path $TestDrive 'dest') 'vid_AbC12345678.mp4'
        Set-Content -Path $script:goodFile -Value 'x' -Force
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                'AbC12345678' | Out-File -FilePath $args[$i+2] -Encoding UTF8
                $script:goodFile | Out-File -FilePath $args[$i+5] -Encoding UTF8
            }
        }
        Mock Get-FileVerdict { @{ Verdict='Unknown'; Reason='ffprobe failed' } }
        Mock Test-FfprobeAvailable { $false }
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        Should -Invoke yt-dlp -Times 1 -Exactly
        $item.FailureKind   | Should -Be 'Configuration'
        $item.RetryDecision | Should -Be 'Stop'
    }
    It 'A9b Case A Unknown, ffprobe present -> Unknown/Retry, 4 attempts' {
        $script:goodFile = Join-Path (Join-Path $TestDrive 'dest') 'vid_AbC12345678.mp4'
        Set-Content -Path $script:goodFile -Value 'x' -Force
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                'AbC12345678' | Out-File -FilePath $args[$i+2] -Encoding UTF8
                $script:goodFile | Out-File -FilePath $args[$i+5] -Encoding UTF8
            }
        }
        Mock Get-FileVerdict { @{ Verdict='Unknown'; Reason='ffprobe failed' } }
        Mock Test-FfprobeAvailable { $true }
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        Should -Invoke yt-dlp -Times 4 -Exactly
        $item.FailureKind   | Should -Be 'Unknown'
        $item.RetryDecision | Should -Be 'Retry'
    }

    # ---------- A10: private text + Corrupt -> Permanent/Stop wins ----------
    It 'A10 private text + Corrupt isolated -> Permanent/Stop wins (1 attempt)' {
        $script:goodFile = Join-Path (Join-Path $TestDrive 'dest') 'vid_AbC12345678.mp4'
        Set-Content -Path $script:goodFile -Value 'x' -Force
        Mock yt-dlp {
            $global:LASTEXITCODE = 1
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                'AbC12345678' | Out-File -FilePath $args[$i+2] -Encoding UTF8
                $script:goodFile | Out-File -FilePath $args[$i+5] -Encoding UTF8
            }
        }
        Mock Get-FailureKind { @{ FailureKind='Permanent'; RetryDecision='Stop'; Reason='private video'; Evidence='ERROR: Private video' } }
        Mock Get-FileVerdict { @{ Verdict='Corrupt'; Reason='0 packets' } }
        Mock Move-ToInvalid { @{ Success=$true; NewPath='x.invalid_123'; Error=$null } }
        Mock Remove-VideoIdFromArchive { $true }
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        Should -Invoke yt-dlp -Times 1 -Exactly
        $item.FailureKind   | Should -Be 'Permanent'
        $item.RetryDecision | Should -Be 'Stop'
    }

    # ---------- A11: Stop at attempt 4/4 ----------
    It 'A11 Stop decided at attempt 4/4 -> exhaustion message, pair persisted' {
        Mock yt-dlp { $global:LASTEXITCODE = 1 } 
        $script:gkCall = 0
        Mock Get-FailureKind {
            $script:gkCall++
            if ($script:gkCall -lt 4) { @{ FailureKind='Transient'; RetryDecision='Retry'; Reason='net' } }
            else                       { @{ FailureKind='Configuration'; RetryDecision='Stop'; Reason='last' } }
        }
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        Should -Invoke yt-dlp -Times 4 -Exactly
        $item.FailureKind   | Should -Be 'Configuration'
        $item.RetryDecision | Should -Be 'Stop'
        $item.Error         | Should -Match 'attempt budget 4/4 exhausted'
    }

    # ---------- A13: AttemptCount persisted before each yt-dlp call ----------
    It 'A13a AttemptCount is persisted to manifest before yt-dlp call' {
        $script:testGuid = $null
        $script:savedAtCall = $null
        $script:goodFile = Join-Path (Join-Path $TestDrive 'dest') 'vid_AbC12345678.mp4'
        Set-Content -Path $script:goodFile -Value 'x' -Force
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $m = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
            $script:savedAtCall = (@($m) | Where-Object { $_.Id -eq $script:testGuid }).AttemptCount
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                'AbC12345678' | Out-File -FilePath $args[$i+2] -Encoding UTF8
                $script:goodFile | Out-File -FilePath $args[$i+5] -Encoding UTF8
            }
        }
        Mock Get-FileVerdict { @{ Verdict='Valid'; Reason='OK' } }
        Mock Test-FileValidity { $true }
        $script:Config.MaxRetries = 0
        $item = New-TestItem
        $script:testGuid = $item.Id
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeTrue
        $script:savedAtCall | Should -Be 1
    }
    It 'A13b Early stop leaves AttemptCount at 1' {
        Install-YtDlpFixtureMock -FixtureName 'private-video'
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.AttemptCount | Should -Be 1
        $m = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
        (@($m) | Where-Object { $_.Id -eq $item.Id }).AttemptCount | Should -Be 1
    }

    It 'A13c 4-attempt retry persists AttemptCount=4 and Failed' {
        Install-YtDlpFixtureMock -FixtureName 'no-network'
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Out-Null

        $item.AttemptCount | Should -Be 4
        $saved = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
        $entry = @($saved) | Where-Object { $_.Id -eq $item.Id }
        $entry.AttemptCount | Should -Be 4
        $entry.Status       | Should -Be 'Failed'
    }

    It 'A13d Pending rows persisted as None/None with attempt 1,2,3' {
        Install-YtDlpFixtureMock -FixtureName 'no-network'
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        $script:a13Id = $item.Id
        $script:pendingRows = @()
        Mock Start-Sleep {
            $m = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
            $row = @($m) | Where-Object { $_.Id -eq $script:a13Id }
            $script:pendingRows += [PSCustomObject]@{ S=$row.Status; FK=$row.FailureKind; RD=$row.RetryDecision; AC=$row.AttemptCount }
        }
        Invoke-ItemDownload -Item $item | Out-Null
        $script:pendingRows.Count | Should -Be 3
        (($script:pendingRows | ForEach-Object { $_.AC }) -join ',') | Should -Be '1,2,3'
        foreach ($r in $script:pendingRows) { $r.S | Should -Be 'Pending'; $r.FK | Should -Be 'None'; $r.RD | Should -Be 'None' }
    }

    # ---------- A15: Success paths -> None/None ----------
    It 'A15a Case A Valid -> Success/None/None' {
        $script:goodFile = Join-Path (Join-Path $TestDrive 'dest') 'vid_AbC12345678.mp4'
        Set-Content -Path $script:goodFile -Value 'x' -Force
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                'AbC12345678' | Out-File -FilePath $args[$i+2] -Encoding UTF8
                $script:goodFile | Out-File -FilePath $args[$i+5] -Encoding UTF8
            }
        }
        Mock Get-FileVerdict { @{ Verdict='Valid'; Reason='OK' } }
        Mock Test-FileValidity { $true }
        $script:Config.MaxRetries = 0
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeTrue
        $item.Status        | Should -Be 'Success'
        $item.FailureKind   | Should -Be 'None'
        $item.RetryDecision | Should -Be 'None'
    }
    It 'A15b Case C Valid (archive) -> Success/None/None' {
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) { 'AbC12345678' | Out-File -FilePath $args[$i+2] -Encoding UTF8 }
        }
        Mock Test-IdInArchive { @{ Status = 'Found' } }
        Mock Find-OutputCandidates {
            @([PSCustomObject]@{
                File    = [PSCustomObject]@{ Name='v_AbC12345678.mp4'; FullName='x'; LastWriteTimeUtc=(Get-Date).ToUniversalTime() }
                Verdict = 'Valid'
                Reason  = 'OK'
            })
        }
        Mock Test-FileValidity { $true }
        $script:Config.MaxRetries = 0
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeTrue
        $item.Status        | Should -Be 'Success'
        $item.FailureKind   | Should -Be 'None'
        $item.RetryDecision | Should -Be 'None'
    }
    It 'A15c Existing-output shortcut -> Success/None/None' {
        $script:goodFile = Join-Path (Join-Path $TestDrive 'dest') 'existing_AbC12345678.mp4'
        Set-Content -Path $script:goodFile -Value 'x' -Force
        Mock Test-FileValidity { $true }
        Mock Get-FileVerdict { @{ Verdict = 'Valid'; Reason = 'OK' } }
        Mock yt-dlp { } 
        $item = New-TestItem
        $item.OutputFilePath = $script:goodFile
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeTrue
        Should -Invoke yt-dlp -Times 0 -Exactly
        $item.Status        | Should -Be 'Success'
        $item.FailureKind   | Should -Be 'None'
        $item.RetryDecision | Should -Be 'None'
    }

    # ---------- A16: [Retry] log format (F15) ----------
    It 'A16a [Retry] logged exactly once with period format (MaxRetries=0)' {
        $script:Config.MaxRetries = 0
        Install-YtDlpFixtureMock -FixtureName 'no-network'
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
            $Message -match '^\[Retry\] FailureKind: Transient\. Decision: Retry\. Reason: .+'
        }
    }
    It 'A16b [Retry] logged once per failed attempt on 4-attempt run' {
        Install-YtDlpFixtureMock -FixtureName 'no-network'
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        Should -Invoke Write-Log -Times 4 -Exactly -ParameterFilter {
            $Message -match '^\[Retry\] FailureKind: .+\. Decision: .+\. Reason: .+'
        }
    }

    It 'F4-regression archive Rule 4 no candidates -> [Retry] once per attempt, not twice' {
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) { 'AbC12345678' | Out-File -FilePath $args[$i+2] -Encoding UTF8 }
        }
        Mock Test-IdInArchive { @{ Status = 'Found' } }
        Mock Find-OutputCandidates { @() }
        Mock Remove-VideoIdFromArchive { $true }
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        Should -Invoke yt-dlp                  -Times 4 -Exactly
        Should -Invoke Remove-VideoIdFromArchive -Times 4 -Exactly
        # Pre-F4 this would be 7: attempts 1-3 logged twice, attempt 4 once.
        Should -Invoke Write-Log               -Times 4 -Exactly -ParameterFilter {
            $Message -match '^\[Retry\] FailureKind: Unknown\. Decision: Retry\. Reason: '
        }
    }

    # ---------- F10b: CommandNotFoundException -> Configuration/Stop ----------
    It 'F10b Mock-throw CommandNotFoundException -> Configuration/Stop, 1 attempt' {
        Mock yt-dlp { throw [System.Management.Automation.CommandNotFoundException]::new('yt-dlp') }
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        Should -Invoke yt-dlp -Times 1 -Exactly
        $item.FailureKind   | Should -Be 'Configuration'
        $item.RetryDecision | Should -Be 'Stop'
        $item.Error         | Should -Match 'yt-dlp not found'
    }

    # ---------- F17a: single boolean return on every exit path ----------
    It 'F17a Stop path returns exactly one boolean' {
        Install-YtDlpFixtureMock -FixtureName 'private-video'
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        @(Invoke-ItemDownload -Item $item).Count | Should -Be 1
    }
    It 'F17a Exhaustion path returns exactly one boolean' {
        Install-YtDlpFixtureMock -FixtureName 'no-network'
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        @(Invoke-ItemDownload -Item $item).Count | Should -Be 1
    }
    It 'F17a Success path returns exactly one boolean' {
        $script:goodFile = Join-Path (Join-Path $TestDrive 'dest') 'vid_AbC12345678.mp4'
        Set-Content -Path $script:goodFile -Value 'x' -Force
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                'AbC12345678' | Out-File -FilePath $args[$i+2] -Encoding UTF8
                $script:goodFile | Out-File -FilePath $args[$i+5] -Encoding UTF8
            }
        }
        Mock Get-FileVerdict { @{ Verdict='Valid'; Reason='OK' } }
        Mock Test-FileValidity { $true }
        $script:Config.MaxRetries = 0
        $item = New-TestItem
        Set-ManifestForItem $item
        @(Invoke-ItemDownload -Item $item).Count | Should -Be 1
    }
    It 'F17a Archive path returns exactly one boolean' {
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) { 'AbC12345678' | Out-File -FilePath $args[$i+2] -Encoding UTF8 }
        }
        Mock Test-IdInArchive { @{ Status = 'Found' } }
        Mock Find-OutputCandidates { @() }
        Mock Remove-VideoIdFromArchive { $true }
        Mock Write-Log { }
        $script:Config.MaxRetries = 0
        $item = New-TestItem
        Set-ManifestForItem $item
        @(Invoke-ItemDownload -Item $item).Count | Should -Be 1
    }
}


# ---------------------------------------------------------------------
# 3. Pair persistence at 3 early sites + 4 cleanup sites (A12, F16)
# ---------------------------------------------------------------------
Describe 'Phase 4 - Delivery 3: Pair persistence at all sites' {

    BeforeDiscovery {
        try {
            [System.IO.Path]::GetFullPath("C:\x$([char]0)y") | Out-Null
            $script:NullCharThrows = $false
        } catch { $script:NullCharThrows = $true }
    }

    BeforeAll {
        $script:OrigAppData = $env:APPDATA
        $env:APPDATA = $TestDrive
        $script:AppDir = Join-Path $env:APPDATA 'YT-DL-CLI'
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AppDir 'Logs') -Force | Out-Null
        . "$PSScriptRoot\..\Development\YT-Downloader.ps1"
        function global:yt-dlp { }
        function global:ffprobe { }
        Mock Start-Sleep { }

        function script:New-TestItem {
            param([string]$Mode = 'Video', [int]$MaxHeight = 720, [string]$Destination = $null)
            if (-not $Destination) { $Destination = Join-Path $TestDrive 'dest' }
            if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
            [PSCustomObject]@{
                Id=[guid]::NewGuid().ToString(); Url='https://youtube.com/watch?v=AbC12345678';
                Mode=$Mode; MaxHeight=$MaxHeight; AudioFormat='MP3'; Bitrate=128;
                Destination=$Destination; Status='Pending'; Error=''; OutputFilePath='';
                VideoId='AbC12345678'; RetryCount=0; AttemptCount=0;
                FailureKind='None'; RetryDecision='None'
            }
        }
        function script:Set-ManifestForItem { param($Item) $script:Manifest = @($Item); [void](Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest) }
    }
    AfterAll {
        Remove-Item function:\yt-dlp  -ErrorAction SilentlyContinue
        Remove-Item function:\ffprobe -ErrorAction SilentlyContinue
        $env:APPDATA = $script:OrigAppData
    }
    BeforeEach {
        $script:Config.MaxRetries = 0
        if (Test-Path $script:ManifestPath) { Remove-Item $script:ManifestPath -Force }
    }

    It 'A12a No destination -> Configuration/Stop' {
        $item = New-TestItem; $item.Destination = ''
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.FailureKind   | Should -Be 'Configuration'
        $item.RetryDecision | Should -Be 'Stop'
    }
    It 'A12b Invalid destination -> Configuration/Stop' -Skip:(-not $script:NullCharThrows) {
        $item = New-TestItem; $item.Destination = "C:\x$([char]0)y"
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.FailureKind   | Should -Be 'Configuration'
        $item.RetryDecision | Should -Be 'Stop'
    }
    It 'A12c Cannot extract video id -> Permanent/Stop' {
        Mock Get-VideoId { '' }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.FailureKind   | Should -Be 'Permanent'
        $item.RetryDecision | Should -Be 'Stop'
    }
    It 'A12d Archive read error -> Unknown/Stop' {
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) { 'AbC12345678' | Out-File -FilePath $args[$i+2] -Encoding UTF8 }
        }
        Mock Test-IdInArchive { @{ Status = 'ReadError' } }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.FailureKind   | Should -Be 'Unknown'
        $item.RetryDecision | Should -Be 'Stop'
    }
    It 'A12e Case A corrupt archive-cleanup failure -> Unknown/Stop' {
        $script:goodFile = Join-Path (Join-Path $TestDrive 'dest') 'vid_AbC12345678.mp4'
        Set-Content -Path $script:goodFile -Value 'x' -Force
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) {
                'AbC12345678' | Out-File -FilePath $args[$i+2] -Encoding UTF8
                $script:goodFile | Out-File -FilePath $args[$i+5] -Encoding UTF8
            }
        }
        Mock Get-FileVerdict { @{ Verdict='Corrupt'; Reason='0 packets' } }
        Mock Move-ToInvalid { @{ Success=$true; NewPath='x.invalid_123'; Error=$null } }
        Mock Remove-VideoIdFromArchive { $false }
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.FailureKind   | Should -Be 'Unknown'
        $item.RetryDecision | Should -Be 'Stop'
    }
    It 'A12f Case C corrupt archive-cleanup failure -> Unknown/Stop' {
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) { 'AbC12345678' | Out-File -FilePath $args[$i+2] -Encoding UTF8 }
        }
        Mock Test-IdInArchive { @{ Status = 'Found' } }
        Mock Find-OutputCandidates {
            @([PSCustomObject]@{
                File    = [PSCustomObject]@{ Name='c_AbC12345678.mp4'; FullName='x'; LastWriteTimeUtc=(Get-Date).ToUniversalTime() }
                Verdict = 'Corrupt'; Reason = 'bad'
            })
        }
        Mock Move-ToInvalid { @{ Success=$true; NewPath='c.invalid'; Error=$null } }
        Mock Remove-VideoIdFromArchive { $false }
        Mock Write-Log { }
        $item = New-TestItem
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.FailureKind   | Should -Be 'Unknown'
        $item.RetryDecision | Should -Be 'Stop'
    }
    It 'A12g Case C OtherMode archive-cleanup failure -> Unknown/Stop' {
        Mock yt-dlp {
            $global:LASTEXITCODE = 0
            $i = [array]::IndexOf($args, '--print-to-file')
            if ($i -ge 0) { 'AbC12345678' | Out-File -FilePath $args[$i+2] -Encoding UTF8 }
        }
        Mock Test-IdInArchive { @{ Status = 'Found' } }
        Mock Find-OutputCandidates {
            @([PSCustomObject]@{
                File    = [PSCustomObject]@{ Name='om_AbC12345678.mp4'; FullName='x'; LastWriteTimeUtc=(Get-Date).ToUniversalTime() }
                Verdict = 'OtherMode'; Reason = 'video only'
            })
        }
        Mock Remove-VideoIdFromArchive { $false }
        Mock Write-Log { }
        $item = New-TestItem -Mode 'Audio' -MaxHeight 0
        Set-ManifestForItem $item
        Invoke-ItemDownload -Item $item | Should -BeFalse
        $item.FailureKind   | Should -Be 'Unknown'
        $item.RetryDecision | Should -Be 'Stop'
    }
}


# ---------------------------------------------------------------------
# 4. Stop-ItemEarly (A14)
# ---------------------------------------------------------------------
Describe 'Phase 4 - Delivery 3: Stop-ItemEarly' {

    BeforeAll {
        $script:OrigAppData = $env:APPDATA
        $env:APPDATA = $TestDrive
        $script:AppDir = Join-Path $env:APPDATA 'YT-DL-CLI'
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AppDir 'Logs') -Force | Out-Null
        . "$PSScriptRoot\..\Development\YT-Downloader.ps1"
    }
    AfterAll { $env:APPDATA = $script:OrigAppData }

    It 'A14a returns exactly one $false' {
        Mock Set-ItemState { $true }
        Mock Write-Log { }
        $item = [PSCustomObject]@{ Id=[guid]::NewGuid().ToString(); Url='https://youtube.com/watch?v=AbC12345678' }
        $r = @(Stop-ItemEarly -Item $item -Reason 'x' -FailureKind 'Permanent' -AttemptNumber 1 -MaxAttempts 4)
        $r.Count | Should -Be 1
        $r[0]    | Should -BeFalse
    }
    It 'A14b Set-ItemState failure logs CRITICAL, still returns $false' {
        Mock Set-ItemState { $false }
        Mock Write-Log { }
        $item = [PSCustomObject]@{ Id=[guid]::NewGuid().ToString(); Url='https://youtube.com/watch?v=AbC12345678' }
        $r = @(Stop-ItemEarly -Item $item -Reason 'x' -FailureKind 'Permanent' -AttemptNumber 1 -MaxAttempts 4)
        $r.Count | Should -Be 1
        $r[0]    | Should -BeFalse
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like 'CRITICAL*' }
    }
}


# ---------------------------------------------------------------------
# 5. F17c: CommandNotFoundException type contract
# ---------------------------------------------------------------------
Describe 'Phase 4 - Delivery 3: CommandNotFoundException type contract' {
    BeforeAll {
        $script:OrigAppData = $env:APPDATA; $env:APPDATA = $TestDrive
        $script:AppDir = Join-Path $env:APPDATA 'YT-DL-CLI'
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AppDir 'Logs') -Force | Out-Null
        . "$PSScriptRoot\..\Development\YT-Downloader.ps1"
    }
    AfterAll { $env:APPDATA = $script:OrigAppData }

    It 'F17c invoking an absent command throws CommandNotFoundException' {
        $threw = $false
        $saved = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Stop'
            & yt-dlp-no-such-command-xyz 2>$null
        } catch [System.Management.Automation.CommandNotFoundException] {
            $threw = $true
        } finally {
            $ErrorActionPreference = $saved
        }
        $threw | Should -BeTrue
    }
}


# ---------------------------------------------------------------------
# 6. F13: production EAP guard proof (PS 5.1 shim). F18-F29 folded in.
# ---------------------------------------------------------------------
Describe 'Phase 4 - Delivery 3: Production EAP capture under Stop' {

    BeforeAll {
        $script:OrigAppData = $env:APPDATA
        $env:APPDATA = $TestDrive
        $script:AppDir = Join-Path $env:APPDATA 'YT-DL-CLI'
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AppDir 'Logs') -Force | Out-Null

        . "$PSScriptRoot\..\Development\YT-Downloader.ps1"
        Mock Start-Sleep { }

        $script:shimDir    = Join-Path $TestDrive 'bin'
        New-Item -ItemType Directory -Path $script:shimDir -Force | Out-Null
        $script:counterFile = Join-Path $TestDrive 'shim-counter.txt'

        # F28: counter increments BEFORE stderr write, so mutated run reliably records 4
        $shim = @(
            '@echo off'
            'echo call>>"%~dp0..\shim-counter.txt"'
            'echo ERROR: [youtube] x: Private video 1>&2'
            'exit /b 1'
        ) -join "`r`n"
        Set-Content -LiteralPath (Join-Path $script:shimDir 'yt-dlp.cmd') -Value $shim -Encoding ASCII
    }
    AfterAll { $env:APPDATA = $script:OrigAppData }

    It 'F13 real Invoke-ItemDownload classifies Permanent/Stop via shim under EAP=Stop' -Tag F13Mutation {
        Remove-Item -LiteralPath $script:counterFile -ErrorAction SilentlyContinue   # F27

        $item = [PSCustomObject]@{
            Id=[guid]::NewGuid().ToString(); Url='https://youtube.com/watch?v=AbC12345678';
            Mode='Video'; MaxHeight=0; AudioFormat=''; Bitrate=0;
            Destination=$TestDrive; Status='Pending'; Error=''; OutputFilePath='';
            VideoId='AbC12345678'; RetryCount=0; AttemptCount=0;
            FailureKind='None'; RetryDecision='None'
        }
        $script:Manifest = @($item)
        [void](Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest)   # F23
        $script:Config.MaxRetries = 3

        $savedFn   = Get-Command yt-dlp -CommandType Function -ErrorAction SilentlyContinue
        $savedPath = $env:Path
        $savedEAP  = $ErrorActionPreference
        try {
            if ($savedFn) { Remove-Item function:\yt-dlp -Force }
            $env:Path = "$script:shimDir;$savedPath"
            (Get-Command yt-dlp).Source | Should -Be (Join-Path $script:shimDir 'yt-dlp.cmd')
            $ErrorActionPreference = 'Stop'
            Invoke-ItemDownload -Item $item | Should -BeFalse
        } finally {
            $ErrorActionPreference = $savedEAP
            $env:Path = $savedPath
            if ($savedFn) { function global:yt-dlp { } }
        }

        (Get-Content -LiteralPath $script:counterFile | Measure-Object -Line).Lines | Should -Be 1
        $item.Status        | Should -Be 'Failed'
        $item.FailureKind   | Should -Be 'Permanent'
        $item.RetryDecision | Should -Be 'Stop'
        $item.Error         | Should -Match 'retry skipped'
    }
}

# =====================================================================
# Phase 4 - Delivery 4: Retry Gate & Force Override (A1-A14, M1, M2)
# =====================================================================

# ---------------------------------------------------------------------
# A2a / A2b: Normalize-FailureClassification changes
# ---------------------------------------------------------------------
Describe 'Phase 4 - Delivery 4: Normalize-FailureClassification' {
    BeforeAll {
        $script:OrigAppData = $env:APPDATA
        $env:APPDATA = $TestDrive
        $script:AppDir = Join-Path $env:APPDATA 'YT-DL-CLI'
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AppDir 'Logs') -Force | Out-Null
        . "$PSScriptRoot\..\Development\YT-Downloader.ps1"
    }
    AfterAll { $env:APPDATA = $script:OrigAppData }

    Context 'A2a Failed + one None -> Unknown/Retry Reason=FailedNone' {
        It 'Failed+<FK>/<RD> -> Unknown/Retry Reason=FailedNone' -ForEach @(
            @{ FK = 'Transient'; RD = 'None' },
            @{ FK = 'Permanent'; RD = 'None' },
            @{ FK = 'None';      RD = 'Retry' },
            @{ FK = 'None';      RD = 'Stop' },
            @{ FK = 'None';      RD = 'None' }
        ) {
            $r = Normalize-FailureClassification -Status 'Failed' -FailureKind $FK -RetryDecision $RD
            $r.FailureKind   | Should -Be 'Unknown'
            $r.RetryDecision | Should -Be 'Retry'
            $r.Reason        | Should -Be 'FailedNone'
        }

        It 'Failed+Permanent/Stop unchanged (neither is None)' {
            $r = Normalize-FailureClassification -Status 'Failed' -FailureKind 'Permanent' -RetryDecision 'Stop'
            $r.FailureKind   | Should -Be 'Permanent'
            $r.RetryDecision | Should -Be 'Stop'
            $r.Reason        | Should -Be 'Valid'
        }
    }

    Context 'A2b Pending/Downloading always None/None' {
        It '<Status> with Permanent/Stop -> None/None Reason=Valid' -ForEach @(
            @{ Status = 'Pending'     },
            @{ Status = 'Downloading' }
        ) {
            $r = Normalize-FailureClassification -Status $Status -FailureKind 'Permanent' -RetryDecision 'Stop'
            $r.FailureKind   | Should -Be 'None'
            $r.RetryDecision | Should -Be 'None'
            $r.Reason        | Should -Be 'Valid'
        }

        It '<Status> with Transient/Retry -> None/None Reason=Valid' -ForEach @(
            @{ Status = 'Pending'     },
            @{ Status = 'Downloading' }
        ) {
            $r = Normalize-FailureClassification -Status $Status -FailureKind 'Transient' -RetryDecision 'Retry'
            $r.FailureKind   | Should -Be 'None'
            $r.RetryDecision | Should -Be 'None'
            $r.Reason        | Should -Be 'Valid'
        }

        It '<Status> with invalid values -> None/None Reason=Invalid' -ForEach @(
            @{ Status = 'Pending'     },
            @{ Status = 'Downloading' }
        ) {
            $r = Normalize-FailureClassification -Status $Status -FailureKind 'garbage' -RetryDecision 'alsobad'
            $r.FailureKind   | Should -Be 'None'
            $r.RetryDecision | Should -Be 'None'
            $r.Reason        | Should -Be 'Invalid'
        }
    }
}

# ---------------------------------------------------------------------
# A2a / A2b: Set-ItemState changes
# ---------------------------------------------------------------------
Describe 'Phase 4 - Delivery 4: Set-ItemState' {
    BeforeAll {
        $script:OrigAppData = $env:APPDATA
        $env:APPDATA = $TestDrive
        $script:AppDir = Join-Path $env:APPDATA 'YT-DL-CLI'
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AppDir 'Logs') -Force | Out-Null
        . "$PSScriptRoot\..\Development\YT-Downloader.ps1"
        Mock Test-FileValidity { $true }

        function script:D4-NewItem {
            param([string]$Status = 'Pending', [string]$FK = 'None', [string]$RD = 'None')
            [PSCustomObject]@{
                Id=[guid]::NewGuid().ToString(); Url='https://youtube.com/watch?v=AbC12345678';
                Mode='Video'; MaxHeight=720; AudioFormat=''; Bitrate=0;
                Destination=$TestDrive; Status=$Status; Error=''; OutputFilePath='';
                VideoId='AbC12345678'; RetryCount=0; AttemptCount=0;
                FailureKind=$FK; RetryDecision=$RD
            }
        }
        function script:D4-SetupItem {
            param($Item)
            $script:Manifest = @($Item)
            [void](Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest)
        }
    }
    AfterAll { $env:APPDATA = $script:OrigAppData }

    BeforeEach {
        $script:Config.MaxRetries = 3
        $script:StateInitialized = $true
        if (Test-Path $script:ManifestPath) { Remove-Item $script:ManifestPath -Force }
    }

    Context 'A2a explicit-pair with one None -> Unknown/Retry' {
        It 'Failed+<FK>/<RD> explicit pair -> Unknown/Retry' -ForEach @(
            @{ FK = 'Transient'; RD = 'None' },
            @{ FK = 'Permanent'; RD = 'None' },
            @{ FK = 'None';      RD = 'Retry' },
            @{ FK = 'None';      RD = 'Stop' },
            @{ FK = 'None';      RD = 'None' }
        ) {
            $item = D4-NewItem; D4-SetupItem $item
            $r = Set-ItemState -Item $item -Status 'Failed' -FailureKind $FK -RetryDecision $RD
            $r | Should -BeTrue
            $item.FailureKind   | Should -Be 'Unknown'
            $item.RetryDecision | Should -Be 'Retry'
        }

        It 'Failed with RetryDecision-only None -> Unknown/Retry' {
            $item = D4-NewItem; D4-SetupItem $item
            $r = Set-ItemState -Item $item -Status 'Failed' -RetryDecision 'None'
            $r | Should -BeTrue
            $item.FailureKind   | Should -Be 'Unknown'
            $item.RetryDecision | Should -Be 'Retry'
        }
    }

    Context 'A2b Pending/Downloading overrides any passed pair' {
        It '<Status> with Permanent/Stop passed -> None/None' -ForEach @(
            @{ Status = 'Pending'     },
            @{ Status = 'Downloading' }
        ) {
            $item = D4-NewItem; D4-SetupItem $item
            $r = Set-ItemState -Item $item -Status $Status -FailureKind 'Permanent' -RetryDecision 'Stop'
            $r | Should -BeTrue
            $item.FailureKind   | Should -Be 'None'
            $item.RetryDecision | Should -Be 'None'
        }

        It '<Status> overrides invalid stored values -> None/None' -ForEach @(
            @{ Status = 'Pending'     },
            @{ Status = 'Downloading' }
        ) {
            $item = D4-NewItem -FK 'garbage' -RD 'alsobad'
            D4-SetupItem $item
            $r = Set-ItemState -Item $item -Status $Status
            $r | Should -BeTrue
            $item.FailureKind   | Should -Be 'None'
            $item.RetryDecision | Should -Be 'None'
        }

        It 'Set-ItemState still rejects non-canonical FailureKind before the Pending override' {
            $item = D4-NewItem; D4-SetupItem $item
            $before = Get-Content -LiteralPath $script:ManifestPath -Raw
            $r = Set-ItemState -Item $item -Status 'Pending' -FailureKind 'permanent' -RetryDecision 'Retry'
            $r | Should -BeFalse
            (Get-Content -LiteralPath $script:ManifestPath -Raw) | Should -Be $before
            $item.FailureKind   | Should -Be 'None'
            $item.RetryDecision | Should -Be 'None'
        }

        It 'Set-ItemState still rejects non-canonical RetryDecision before the Downloading override' {
            $item = D4-NewItem; D4-SetupItem $item
            $r = Set-ItemState -Item $item -Status 'Downloading' -FailureKind 'Transient' -RetryDecision 'retry'
            $r | Should -BeFalse
            $item.FailureKind   | Should -Be 'None'
            $item.RetryDecision | Should -Be 'None'
        }
    }
}

# ---------------------------------------------------------------------
# A1, A3, A4, A4b, A5, A6, A10, A12: Get-RetryPlan changes
# ---------------------------------------------------------------------
Describe 'Phase 4 - Delivery 4: Get-RetryPlan' {
    BeforeAll {
        $script:OrigAppData = $env:APPDATA
        $env:APPDATA = $TestDrive
        $script:AppDir = Join-Path $env:APPDATA 'YT-DL-CLI'
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AppDir 'Logs') -Force | Out-Null
        . "$PSScriptRoot\..\Development\YT-Downloader.ps1"

        function script:D4-ManifestItem {
            param(
                [string]$Status = 'Failed',
                [string]$FK = 'Transient',
                [string]$RD = 'Retry',
                [int]$AttemptCount = 1,
                [int]$RetryCount = 0,
                [string]$VideoId = 'AbC12345678',
                [string]$Url = 'https://youtube.com/watch?v=AbC12345678',
                [string]$OutputFilePath = ''
            )
            [PSCustomObject]@{
                Id=[guid]::NewGuid().ToString(); Url=$Url;
                Mode='Video'; MaxHeight=720; AudioFormat=''; Bitrate=0;
                Destination=$TestDrive; Status=$Status; Error=''; OutputFilePath=$OutputFilePath;
                VideoId=$VideoId; RetryCount=$RetryCount; AttemptCount=$AttemptCount;
                FailureKind=$FK; RetryDecision=$RD
            }
        }
    }
    AfterAll { $env:APPDATA = $script:OrigAppData }

    BeforeEach { $script:Config.MaxRetries = 3 }

    Context 'A1 Default eligibility' {
        It 'A1 Failed/Retry runs' {
            $m = @(D4-ManifestItem -Status 'Failed' -FK 'Transient' -RD 'Retry')
            (Get-RetryPlan -Manifest $m).ItemsToRun.Count | Should -Be 1
        }
        It 'A1 Failed/Stop is skipped and not in ItemsToRun' {
            $m = @(D4-ManifestItem -Status 'Failed' -FK 'Permanent' -RD 'Stop' -AttemptCount 2)
            $plan = Get-RetryPlan -Manifest $m
            $plan.ItemsToRun.Count | Should -Be 0
            @($plan.Skipped | Where-Object { $_.SkipReason -eq 'Stop' }).Count | Should -Be 1
        }
        It 'A1 Pending carrying Stop runs' {
            $m = @(D4-ManifestItem -Status 'Pending' -FK 'Permanent' -RD 'Stop')
            (Get-RetryPlan -Manifest $m).ItemsToRun.Count | Should -Be 1
        }
        It 'A1 Downloading carrying Stop runs' {
            $m = @(D4-ManifestItem -Status 'Downloading' -FK 'Permanent' -RD 'Stop')
            (Get-RetryPlan -Manifest $m).ItemsToRun.Count | Should -Be 1
        }
        It 'A1 Success with invalid file runs' {
            Mock Test-FileValidity { $false }
            $item = D4-ManifestItem -Status 'Success' -FK 'None' -RD 'None' -OutputFilePath 'C:\bad.mp4'
            (Get-RetryPlan -Manifest @($item)).ItemsToRun.Count | Should -Be 1
        }
        It 'A1 Success with valid file does not run' {
            Mock Test-FileValidity { $true }
            $item = D4-ManifestItem -Status 'Success' -FK 'None' -RD 'None' -OutputFilePath 'C:\ok.mp4'
            (Get-RetryPlan -Manifest @($item)).ItemsToRun.Count | Should -Be 0
        }
    }

    Context 'A2a None/Stop is eligible in plan' {
        It 'Failed+None/Stop normalizes through Copy-Manifest and runs' {
            $m = @(D4-ManifestItem -Status 'Failed' -FK 'None' -RD 'Stop')
            (Get-RetryPlan -Manifest $m).ItemsToRun.Count | Should -Be 1
        }
    }

    Context 'A3 Skipped structure' {
        It 'A3 Stop skipped entry has exactly 7 keys' {
            $m = @(D4-ManifestItem -Status 'Failed' -FK 'Permanent' -RD 'Stop')
            $plan = Get-RetryPlan -Manifest $m
            $skip = @($plan.Skipped | Where-Object { $_.SkipReason -eq 'Stop' })
            $skip.Count | Should -Be 1
            $skip[0] | Should -BeOfType [hashtable]
            $skip[0].Keys.Count | Should -Be 7
            foreach ($k in 'Id','Url','VideoId','FailureKind','Error','AttemptCount','SkipReason') {
                $skip[0].Keys | Should -Contain $k
            }
            $skip[0].FailureKind | Should -Be 'Permanent'
        }
        It 'A3 InvalidVideoId skipped entry has exactly 7 keys, Failed/Permanent/Stop' {
            $m = @(D4-ManifestItem -Status 'Failed' -FK 'Transient' -RD 'Retry' -VideoId '' -Url 'https://example.com/x')
            $plan = Get-RetryPlan -Manifest $m
            $skip = @($plan.Skipped | Where-Object { $_.SkipReason -eq 'InvalidVideoId' })
            $skip.Count | Should -Be 1
            $skip[0] | Should -BeOfType [hashtable]
            $skip[0].Keys.Count | Should -Be 7
            $skip[0].FailureKind | Should -Be 'Permanent'
            $skip[0].Error       | Should -Be 'Invalid YouTube URL / VideoId'
            $skip[0].VideoId     | Should -BeNullOrEmpty
        }
    }

    Context 'A4 Force override' {
        It 'A4 -Force on Failed/Stop gives Pending, None/None, AttemptCount=0, RetryCount=0 (at 1)' {
            $m = @(D4-ManifestItem -Status 'Failed' -FK 'Permanent' -RD 'Stop' -AttemptCount 1 -RetryCount 0)
            $plan = Get-RetryPlan -Manifest $m -Force
            $plan.ItemsToRun.Count | Should -Be 1
            $run = $plan.ItemsToRun[0]
            $run.Status         | Should -Be 'Pending'
            $run.FailureKind    | Should -Be 'None'
            $run.RetryDecision  | Should -Be 'None'
            $run.AttemptCount   | Should -Be 0
            $run.RetryCount     | Should -Be 0
        }
        It 'A4 -Force resets at 4/4' {
            $m = @(D4-ManifestItem -Status 'Failed' -FK 'Permanent' -RD 'Stop' -AttemptCount 4 -RetryCount 3)
            $run = (Get-RetryPlan -Manifest $m -Force).ItemsToRun[0]
            $run.AttemptCount | Should -Be 0
            $run.RetryCount   | Should -Be 0
        }
    }

    Context 'A4b InvalidVideoId with and without Force' {
        It '<Case>: counters stay 4/4, Failed/Permanent/Stop, InvalidVideoId, not in ItemsToRun, not in BlockedByStop' -ForEach @(
            @{ Case = 'no Force';   Force = $false },
            @{ Case = 'with -Force'; Force = $true }
        ) {
            $m = @(D4-ManifestItem -Status 'Failed' -FK 'Permanent' -RD 'Stop' -AttemptCount 4 -RetryCount 4 -VideoId '' -Url 'https://example.com/x')
            $plan = if ($Force) { Get-RetryPlan -Manifest $m -Force } else { Get-RetryPlan -Manifest $m }
            $plan.ItemsToRun.Count | Should -Be 0
            $skip = @($plan.Skipped | Where-Object { $_.SkipReason -eq 'InvalidVideoId' })
            $skip.Count | Should -Be 1
            $skip[0].AttemptCount | Should -Be 4
            $skip[0].FailureKind  | Should -Be 'Permanent'
            $plan.BlockedByStop   | Should -Be 0
        }
    }

    Context 'A5 Invalid VideoId precedence' {
        It 'A5 invalid-VideoId item never in ItemsToRun (with/without Force)' {
            $m = @(D4-ManifestItem -Status 'Failed' -FK 'Transient' -RD 'Retry' -VideoId '' -Url 'https://example.com/x')
            (Get-RetryPlan -Manifest $m).ItemsToRun.Count         | Should -Be 0
            (Get-RetryPlan -Manifest $m -Force).ItemsToRun.Count  | Should -Be 0
        }
        It 'A5 persisted Failed/Permanent/Stop with invalid VideoId is InvalidVideoId, not Stop' {
            $m = @(D4-ManifestItem -Status 'Failed' -FK 'Permanent' -RD 'Stop' -VideoId '' -Url 'https://example.com/x')
            $plan = Get-RetryPlan -Manifest $m
            @($plan.Skipped | Where-Object { $_.SkipReason -eq 'Stop' }).Count          | Should -Be 0
            @($plan.Skipped | Where-Object { $_.SkipReason -eq 'InvalidVideoId' }).Count | Should -Be 1
            $plan.BlockedByStop | Should -Be 0
        }
    }

    Context 'A6 BlockedByStop' {
        It 'A6 n valid Stop items -> BlockedByStop=n; 0 under Force' {
            $m = 1..3 | ForEach-Object { D4-ManifestItem -Status 'Failed' -FK 'Permanent' -RD 'Stop' }
            $plan = Get-RetryPlan -Manifest $m
            $plan.BlockedByStop            | Should -Be 3
            (Get-RetryPlan -Manifest $m -Force).BlockedByStop | Should -Be 0
        }
        It 'A6 invalid items not counted in BlockedByStop' {
            $m = @(
                (D4-ManifestItem -Status 'Failed' -FK 'Permanent' -RD 'Stop'),
                (D4-ManifestItem -Status 'Failed' -FK 'Permanent' -RD 'Stop' -VideoId '' -Url 'https://example.com/x')
            )
            (Get-RetryPlan -Manifest $m).BlockedByStop | Should -Be 1
        }
    }

    Context 'A10 original manifest untouched' {
        It 'A10 $script:Manifest is identical before and after both calls' {
            $item = D4-ManifestItem -Status 'Failed' -FK 'Permanent' -RD 'Stop' -AttemptCount 2 -RetryCount 1
            $script:Manifest = @($item)
            $snapshot = (ConvertTo-Json -InputObject @($script:Manifest) -Depth 5 -Compress)
            $null = Get-RetryPlan
            (ConvertTo-Json -InputObject @($script:Manifest) -Depth 5 -Compress) | Should -Be $snapshot
            $null = Get-RetryPlan -Force
            (ConvertTo-Json -InputObject @($script:Manifest) -Depth 5 -Compress) | Should -Be $snapshot
        }
    }

    Context 'A12 Skipped and BlockedByStop on every return path' {
        It 'A12 no-candidate path' {
            $plan = Get-RetryPlan -Manifest @()
            $plan.Keys          | Should -Contain 'Skipped'
            $plan.Keys          | Should -Contain 'BlockedByStop'
            $plan.Skipped.Count | Should -Be 0
            $plan.BlockedByStop | Should -Be 0
        }
        It 'A12 all-skipped path' {
            $m = @(D4-ManifestItem -Status 'Failed' -FK 'Permanent' -RD 'Stop')
            $plan = Get-RetryPlan -Manifest $m
            $plan.Keys          | Should -Contain 'Skipped'
            $plan.Keys          | Should -Contain 'BlockedByStop'
            $plan.Skipped.Count | Should -Be 1
            $plan.BlockedByStop | Should -Be 1
        }
        It 'A12 normal path' {
            $m = @(D4-ManifestItem -Status 'Failed' -FK 'Transient' -RD 'Retry')
            $plan = Get-RetryPlan -Manifest $m
            $plan.Keys             | Should -Contain 'Skipped'
            $plan.Keys             | Should -Contain 'BlockedByStop'
            $plan.ItemsToRun.Count | Should -Be 1
            $plan.BlockedByStop    | Should -Be 0
        }
    }
}

# ---------------------------------------------------------------------
# A7: Get-RetrySkipSummary
# ---------------------------------------------------------------------
Describe 'Phase 4 - Delivery 4: Get-RetrySkipSummary' {
    BeforeAll {
        . "$PSScriptRoot\..\Development\YT-Downloader.ps1"

        function script:D4-MakeSkipFull {
            param(
                [string]$SkipReason = 'Stop',
                [string]$FailureKind = 'Permanent',
                [string]$ErrorMessage = 'err',
                [string]$VideoId = 'vid',
                [string]$Url = 'url',
                [int]$AttemptCount = 1
            )
            @{
                Id           = [guid]::NewGuid().ToString()
                Url          = $Url
                VideoId      = $VideoId
                FailureKind  = $FailureKind
                Error        = $ErrorMessage
                AttemptCount = $AttemptCount
                SkipReason   = $SkipReason
            }
        }
    }

    It 'A7 null input returns empty array' {
        $r = Get-RetrySkipSummary -Skipped $null
        @($r).Count | Should -Be 0
    }
    It 'A7 empty input returns empty array' {
        $r = Get-RetrySkipSummary -Skipped @()
        @($r).Count | Should -Be 0
    }
    It 'A7 header + per-reason counts' {
        $skip = @(
            (D4-MakeSkipFull -SkipReason 'Stop'),
            (D4-MakeSkipFull -SkipReason 'Stop'),
            (D4-MakeSkipFull -SkipReason 'InvalidVideoId')
        )
        $r = Get-RetrySkipSummary -Skipped $skip
        $r | Should -Contain 'Skipped 3 item(s):'
        @($r | Where-Object { $_ -match '^\s+Stop: 2\s*$' }).Count          | Should -Be 1
        @($r | Where-Object { $_ -match '^\s+InvalidVideoId: 1\s*$' }).Count | Should -Be 1
    }
    It 'A7 per-kind counts for Stop only, fixed order' {
        $skip = @(
            (D4-MakeSkipFull -SkipReason 'Stop' -FailureKind 'Permanent'),
            (D4-MakeSkipFull -SkipReason 'Stop' -FailureKind 'Transient'),
            (D4-MakeSkipFull -SkipReason 'Stop' -FailureKind 'Transient'),
            (D4-MakeSkipFull -SkipReason 'InvalidVideoId' -FailureKind 'Permanent')
        )
        $r = Get-RetrySkipSummary -Skipped $skip
        $iT = -1; $iP = -1
        for ($i = 0; $i -lt $r.Count; $i++) {
            if ($r[$i] -match '^\s+Transient: 2\s*$')   { $iT = $i }
            if ($r[$i] -match '^\s+Permanent: 1\s*$')   { $iP = $i }
        }
        $iT | Should -BeGreaterThan -1
        $iP | Should -BeGreaterThan -1
        $iT | Should -BeLessThan $iP
        @($r | Where-Object { $_ -match '^\s+Permanent: \d' }).Count | Should -Be 1
    }
    It 'A7 cap of 5 preview lines and ... and K more' {
        $skip = 1..7 | ForEach-Object {
            D4-MakeSkipFull -SkipReason 'InvalidVideoId' -VideoId "vid$_" -Error "err$_"
        }
        $r = Get-RetrySkipSummary -Skipped $skip
        @($r | Where-Object { $_ -match '^\s+vid\d+ - err\d+\s*$' }).Count | Should -Be 5
        @($r | Where-Object { $_ -match '\.\.\. and 2 more' }).Count       | Should -Be 1
    }
    It 'A7 falls back to Url when VideoId empty' {
        $skip = @(D4-MakeSkipFull -SkipReason 'InvalidVideoId' -VideoId '' -Url 'https://example.com/x')
        $r = Get-RetrySkipSummary -Skipped $skip
        @($r | Where-Object { $_ -match 'https://example\.com/x - err' }).Count | Should -Be 1
    }
}

# ---------------------------------------------------------------------
# A7, A8, A9, A11: Invoke-RetryPlanFlow
# ---------------------------------------------------------------------
Describe 'Phase 4 - Delivery 4: Invoke-RetryPlanFlow' {
    BeforeAll {
        $script:OrigAppData = $env:APPDATA
        $env:APPDATA = $TestDrive
        $script:AppDir = Join-Path $env:APPDATA 'YT-DL-CLI'
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AppDir 'Logs') -Force | Out-Null
        . "$PSScriptRoot\..\Development\YT-Downloader.ps1"

        function script:D4-MakeSkip {
            param([string]$SkipReason = 'Stop', [string]$FailureKind = 'Permanent')
            @{
                Id=[guid]::NewGuid().ToString(); Url='u'; VideoId='v'
                FailureKind=$FailureKind; Error='e'; AttemptCount=1; SkipReason=$SkipReason
            }
        }
        function script:D4-MakePlan {
            param($ItemsToRun = @(), $Skipped = @(), [int]$BlockedByStop = 0, $ModifiedManifest = $null)
            @{
                ModifiedManifest = $ModifiedManifest
                ItemsToRun       = @($ItemsToRun)
                Skipped          = @($Skipped)
                BlockedByStop    = $BlockedByStop
            }
        }
    }
    AfterAll { $env:APPDATA = $script:OrigAppData }

    BeforeEach {
        Mock Write-Log { }
        Mock Read-Host { '' }
    }

    It 'A7 logs summary + Items to run' {
        $script:skip = @(D4-MakeSkip -SkipReason 'Stop')
        $script:run  = @([PSCustomObject]@{ Id = 'r1' })
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun $script:run -Skipped $script:skip -BlockedByStop 0 }
        $null = Invoke-RetryPlanFlow
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -match '^Skipped 1 item' -and $Color -eq 'Yellow' }
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -match '^Items to run: 1$' }
    }

    It 'A8 FORCE calls Get-RetryPlan -Force' {
        $script:skip = @(D4-MakeSkip -SkipReason 'Stop')
        $script:run  = @([PSCustomObject]@{ Id = 'r1' })
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun @() -Skipped $script:skip -BlockedByStop 1 } -ParameterFilter { -not $Force }
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun $script:run -BlockedByStop 0 }              -ParameterFilter {  $Force }
        Mock Read-Host { 'FORCE' }
        $plan = Invoke-RetryPlanFlow
        $plan.ItemsToRun.Count | Should -Be 1
        Should -Invoke Get-RetryPlan -Times 1 -Exactly -ParameterFilter { -not $Force }
        Should -Invoke Get-RetryPlan -Times 1 -Exactly -ParameterFilter {  $Force }
    }

    It 'A8 "<Answer>" does not force' -ForEach @(
        @{ Answer = '' },
        @{ Answer = 'force' },
        @{ Answer = 'y' },
        @{ Answer = 'FORCE ' }
    ) {
        $script:Ans  = $Answer
        $script:skip = @(D4-MakeSkip -SkipReason 'Stop')
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun @() -Skipped $script:skip -BlockedByStop 1 } -ParameterFilter { -not $Force }
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun @() -Skipped $script:skip -BlockedByStop 1 } -ParameterFilter {  $Force }
        Mock Read-Host { $script:Ans }
        $null = Invoke-RetryPlanFlow
        Should -Invoke Get-RetryPlan -Times 0 -Exactly -ParameterFilter { $Force }
    }

    It 'A8 $null input does not force' {
        $script:skip = @(D4-MakeSkip -SkipReason 'Stop')
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun @() -Skipped $script:skip -BlockedByStop 1 } -ParameterFilter { -not $Force }
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun @() -Skipped $script:skip -BlockedByStop 1 } -ParameterFilter {  $Force }
        Mock Read-Host { $null }
        $null = Invoke-RetryPlanFlow
        Should -Invoke Get-RetryPlan -Times 0 -Exactly -ParameterFilter { $Force }
    }

    It 'A8 no prompt when BlockedByStop=0' {
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun @([PSCustomObject]@{ Id='r1' }) -BlockedByStop 0 }
        $null = Invoke-RetryPlanFlow
        Should -Invoke Read-Host -Times 0 -Exactly -ParameterFilter { $Prompt -match 'FORCE' }
    }

    It 'A8 prompt appears when other items are runnable' {
        $script:skip = @(D4-MakeSkip -SkipReason 'Stop')
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun @([PSCustomObject]@{ Id='r1' }) -Skipped $script:skip -BlockedByStop 1 }
        $null = Invoke-RetryPlanFlow
        Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { $Prompt -match 'FORCE' }
    }

    It 'A8 Force applies to all blocked items' {
        $script:skip = @(D4-MakeSkip -SkipReason 'Stop')
        $script:run  = @([PSCustomObject]@{ Id='a' }, [PSCustomObject]@{ Id='b' })
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun @() -Skipped $script:skip -BlockedByStop 2 } -ParameterFilter { -not $Force }
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun $script:run -BlockedByStop 0 }              -ParameterFilter {  $Force }
        Mock Read-Host { 'FORCE' }
        $plan = Invoke-RetryPlanFlow
        $plan.ItemsToRun.Count | Should -Be 2
    }

    It 'A9 message 1 (Stop blocked) when BlockedByStop>0 after Enter' {
        $script:skip = @(D4-MakeSkip -SkipReason 'Stop')
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun @() -Skipped $script:skip -BlockedByStop 1 }
        $r = Invoke-RetryPlanFlow
        $r | Should -BeNullOrEmpty
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
            $Message -like 'All eligible items are blocked (RetryDecision=Stop).*Force Retry.*'
        }
    }
    It 'A9 message 2 (Invalid only) when BlockedByStop=0 and Skipped>0' {
        $script:skip = @(D4-MakeSkip -SkipReason 'InvalidVideoId')
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun @() -Skipped $script:skip -BlockedByStop 0 }
        $r = Invoke-RetryPlanFlow
        $r | Should -BeNullOrEmpty
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
            $Message -like 'Remaining items have an invalid VideoId*'
        }
    }
    It 'A9 message 3 (Nothing found) when BlockedByStop=0 and Skipped=0' {
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun @() -Skipped @() -BlockedByStop 0 }
        $r = Invoke-RetryPlanFlow
        $r | Should -BeNullOrEmpty
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
            $Message -like 'No failed, pending or interrupted items found*'
        }
    }
    It 'A9 message 1 is unreachable after a successful Force re-call' {
        $script:skip = @(D4-MakeSkip -SkipReason 'Stop')
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun @() -Skipped $script:skip -BlockedByStop 1 } -ParameterFilter { -not $Force }
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun @([PSCustomObject]@{ Id='r1' }) -BlockedByStop 0 } -ParameterFilter {  $Force }
        Mock Read-Host { 'FORCE' }
        $null = Invoke-RetryPlanFlow
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Message -like 'All eligible items are blocked*' }
    }

    It 'A11 Force with all-invalid -> $null, message 2, no save' {
        $script:skip = @(D4-MakeSkip -SkipReason 'InvalidVideoId')
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun @() -Skipped @() -BlockedByStop 1 } -ParameterFilter { -not $Force }
        Mock Get-RetryPlan { D4-MakePlan -ItemsToRun @() -Skipped $script:skip -BlockedByStop 0 -ModifiedManifest $null } -ParameterFilter {  $Force }
        Mock Save-AtomicJson { throw 'Must not save' }
        Mock Read-Host { 'FORCE' }
        $r = Invoke-RetryPlanFlow
        $r | Should -BeNullOrEmpty
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like 'Remaining items have an invalid VideoId*' }
        Should -Invoke Save-AtomicJson -Times 0 -Exactly
    }
}

# ---------------------------------------------------------------------
# A13, A14: Static contracts
# ---------------------------------------------------------------------
Describe 'Phase 4 - Delivery 4: Static contracts' {
    BeforeAll {
        $script:ScriptPath = Join-Path $PSScriptRoot '..\Development\YT-Downloader.ps1'
        $script:Content    = Get-Content -LiteralPath $script:ScriptPath -Raw

        function script:D4-FunctionBody {
            param([string]$Name)
            $start = $script:Content.IndexOf("function $Name")
            if ($start -lt 0) { return $null }
            $next = $script:Content.IndexOf('function ', $start + 10)
            if ($next -gt 0) { return $script:Content.Substring($start, $next - $start) }
            return $script:Content.Substring($start)
        }
    }

    It 'A13 no Save-AtomicJson inside Get-RetryPlan' {
        D4-FunctionBody 'Get-RetryPlan' | Should -Not -Match 'Save-AtomicJson'
    }
    It 'A13 no Save-AtomicJson inside Invoke-RetryPlanFlow' {
        D4-FunctionBody 'Invoke-RetryPlanFlow' | Should -Not -Match 'Save-AtomicJson'
    }
    It 'A13 no Save-AtomicJson inside Get-RetrySkipSummary' {
        D4-FunctionBody 'Get-RetrySkipSummary' | Should -Not -Match 'Save-AtomicJson'
    }
    It 'A13 Main option "6" still contains Save-AtomicJson after Invoke-RetryPlanFlow' {
        $idx = $script:Content.IndexOf('$plan = Invoke-RetryPlanFlow')
        $idx | Should -BeGreaterThan 0
        $script:Content.Substring($idx) | Should -Match 'Save-AtomicJson'
    }

    It 'A14 no $script: in Get-RetryPlan body (except default param)' {
        $body = D4-FunctionBody 'Get-RetryPlan'
        $body | Should -Not -BeNullOrEmpty
        $stripped = $body -replace '\$Manifest\s*=\s*\$script:Manifest', ''
        $stripped | Should -Not -Match '\$script:'
    }
    It 'A14 no $script: in Invoke-RetryPlanFlow body' {
        D4-FunctionBody 'Invoke-RetryPlanFlow' | Should -Not -Match '\$script:'
    }
    It 'A14 no $script: in Get-RetrySkipSummary body' {
        D4-FunctionBody 'Get-RetrySkipSummary' | Should -Not -Match '\$script:'
    }
}

# ---------------------------------------------------------------------
# M1, M2: End-to-end at Invoke-RetryPlanFlow
# ---------------------------------------------------------------------
Describe 'Phase 4 - Delivery 4: End-to-end plan flow' {
    BeforeAll {
        $script:OrigAppData = $env:APPDATA
        $env:APPDATA = $TestDrive
        $script:AppDir = Join-Path $env:APPDATA 'YT-DL-CLI'
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AppDir 'Logs') -Force | Out-Null
        . "$PSScriptRoot\..\Development\YT-Downloader.ps1"
    }
    AfterAll { $env:APPDATA = $script:OrigAppData }

    BeforeEach {
        $script:Config.MaxRetries = 3
        $script:StateInitialized = $true
        if (Test-Path $script:ManifestPath) { Remove-Item $script:ManifestPath -Force }
        Mock Write-Log { }
    }

    It 'M1 one Permanent/Stop: Enter runs nothing; FORCE runs with AttemptCount reset to 0' {
        $item = [PSCustomObject]@{
            Id=[guid]::NewGuid().ToString(); Url='https://youtube.com/watch?v=AbC12345678';
            Mode='Video'; MaxHeight=720; AudioFormat=''; Bitrate=0;
            Destination=$TestDrive; Status='Failed'; Error='err'; OutputFilePath='';
            VideoId='AbC12345678'; RetryCount=3; AttemptCount=4;
            FailureKind='Permanent'; RetryDecision='Stop'
        }
        $script:Manifest = @($item)
        [void](Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest)

        Mock Read-Host { '' }
        (Invoke-RetryPlanFlow) | Should -BeNullOrEmpty

        Mock Read-Host { 'FORCE' }
        $plan = Invoke-RetryPlanFlow
        $plan | Should -Not -BeNullOrEmpty
        $plan.ItemsToRun.Count | Should -Be 1
        $plan.ItemsToRun[0].Status        | Should -Be 'Pending'
        $plan.ItemsToRun[0].FailureKind   | Should -Be 'None'
        $plan.ItemsToRun[0].RetryDecision | Should -Be 'None'
        $plan.ItemsToRun[0].AttemptCount  | Should -Be 0
        $plan.ItemsToRun[0].RetryCount    | Should -Be 0
    }

    It 'M2 one Stop + one Retry: Enter runs only Retry; FORCE runs both' {
        $stopItem = [PSCustomObject]@{
            Id=[guid]::NewGuid().ToString(); Url='https://youtube.com/watch?v=22222222222';
            Mode='Video'; MaxHeight=720; AudioFormat=''; Bitrate=0;
            Destination=$TestDrive; Status='Failed'; Error='e'; OutputFilePath='';
            VideoId='22222222222'; RetryCount=0; AttemptCount=1;
            FailureKind='Permanent'; RetryDecision='Stop'
        }
        $retryItem = [PSCustomObject]@{
            Id=[guid]::NewGuid().ToString(); Url='https://youtube.com/watch?v=11111111111';
            Mode='Video'; MaxHeight=720; AudioFormat=''; Bitrate=0;
            Destination=$TestDrive; Status='Failed'; Error='e'; OutputFilePath='';
            VideoId='11111111111'; RetryCount=0; AttemptCount=1;
            FailureKind='Transient'; RetryDecision='Retry'
        }
        $script:Manifest = @($stopItem, $retryItem)
        [void](Save-AtomicJson -Path $script:ManifestPath -Data $script:Manifest)

        Mock Read-Host { '' }
        $planEnter = Invoke-RetryPlanFlow
        $planEnter.ItemsToRun.Count | Should -Be 1
        $planEnter.ItemsToRun[0].Id | Should -Be $retryItem.Id

        Mock Read-Host { 'FORCE' }
        $planForce = Invoke-RetryPlanFlow
        $planForce.ItemsToRun.Count | Should -Be 2
        ($planForce.ItemsToRun.Id -contains $stopItem.Id)  | Should -BeTrue
        ($planForce.ItemsToRun.Id -contains $retryItem.Id) | Should -BeTrue
    }
}

# =====================================================================
# Phase 4 - Delivery 5: D5 Strict Existing-Output Validation
# =====================================================================
Describe 'D5 Strict Existing-Output Check' {

    # Discovery-time NV set (A6): six non-Valid verdict results.
    $d5NvCases = @(
        @{ Label = 'Corrupt';   Verdict = @{ Verdict = 'Corrupt';   Reason = 'bad' } }
        @{ Label = 'OtherMode'; Verdict = @{ Verdict = 'OtherMode'; Reason = 'wrong mode' } }
        @{ Label = 'Unknown';   Verdict = @{ Verdict = 'Unknown';   Reason = 'ffprobe' } }
        @{ Label = 'null';      Verdict = $null }
        @{ Label = 'empty';     Verdict = @{} }
        @{ Label = 'Bogus';     Verdict = @{ Verdict = 'Bogus' } }
    )

    BeforeAll {
        $script:OrigAppData = $env:APPDATA
        $env:APPDATA = $TestDrive
        $script:AppDir = Join-Path $env:APPDATA 'YT-DL-CLI'
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AppDir 'Logs') -Force | Out-Null
        . "$PSScriptRoot\..\Development\YT-Downloader.ps1"

        function global:yt-dlp { }

        $script:D5Dest = Join-Path $TestDrive 'D5Dest'
        New-Item -ItemType Directory -Path $script:D5Dest -Force | Out-Null
        $script:D5ExistingFile = Join-Path $script:D5Dest 'existing_AbC12345678.mp4'
        Set-Content -LiteralPath $script:D5ExistingFile -Value 'dummy video content' -Force

        function script:New-D5Item {
            param($Mode = 'Video', [string]$Status = 'Pending', [int]$AttemptCount = 0, $OutputFilePath)
            if (-not $PSBoundParameters.ContainsKey('OutputFilePath')) { $OutputFilePath = $script:D5ExistingFile }
            [PSCustomObject]@{
                Id             = [guid]::NewGuid().ToString()
                Url            = 'https://youtube.com/watch?v=AbC12345678'
                Mode           = $Mode
                MaxHeight      = 720
                AudioFormat    = ''
                Bitrate        = 0
                Destination    = $script:D5Dest
                Status         = $Status
                Error          = ''
                OutputFilePath = $OutputFilePath
                VideoId        = 'AbC12345678'
                RetryCount     = 0
                AttemptCount   = $AttemptCount
                FailureKind    = 'None'
                RetryDecision  = 'None'
            }
        }

        # 'Error' is an alias of Set-ItemState's ErrorMessage parameter.
        # Read whichever key the binding engine recorded (PS 5.1 / PS 7 safe).
        function script:Get-D5Error {
            param([hashtable]$Call)
            if ($Call.ContainsKey('ErrorMessage')) { return $Call['ErrorMessage'] }
            if ($Call.ContainsKey('Error'))        { return $Call['Error'] }
            return $null
        }

        Mock Get-MaxAttempts { return 4 }
        Mock Write-Log { }
        Mock Start-Sleep { }
        Mock Test-FileValidity { return $true }
        Mock yt-dlp { $global:LASTEXITCODE = 0 }
        Mock Move-ToInvalid { return @{ Success = $true; NewPath = 'x.invalid_123'; Error = $null } }
        Mock Get-VerdictFailureClass { return @{ FailureKind = 'Unknown'; RetryDecision = 'Retry' } }

        # The param block is required: Pester splats the bound parameters into the mock
        # body, so without it the body's own $PSBoundParameters is empty.
        # Signature mirrors Set-ItemState, including the 'Error' alias.
        Mock Set-ItemState {
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
            $copy = @{}
            foreach ($k in $PSBoundParameters.Keys) { $copy[$k] = $PSBoundParameters[$k] }
            $script:sisCalls.Add($copy)
            return $script:sisReturn
        }
        Mock Get-VideoId {
            $script:sisAtVid = $script:sisCalls.Count
            return $script:d5VideoId
        }
    }

    AfterAll {
        Remove-Item function:\yt-dlp -ErrorAction SilentlyContinue
        $env:APPDATA = $script:OrigAppData
    }

    BeforeEach {
        $script:sisCalls  = New-Object 'System.Collections.Generic.List[object]'
        $script:sisAtVid  = -1
        $script:sisReturn = $true
        $script:d5VideoId = ''          # fall-through
    }

    Context 'Runtime - mocked Get-FileVerdict' {

        BeforeAll {
            Mock Get-FileVerdict { return $script:d5Verdict }
        }

        BeforeEach {
            $script:d5Verdict = @{ Verdict = 'Valid'; Reason = 'OK' }
        }

        # ---------- A1 ----------
        It 'A1 Verdict=Valid Mode=<Mode> accepts with exactly one Success state call' -ForEach @(
            @{ Mode = 'Video' }, @{ Mode = 'Audio' }
        ) {
            $item = New-D5Item -Mode $Mode
            $script:Manifest = @($item)
            Invoke-ItemDownload -Item $item | Should -BeTrue
            $script:sisCalls.Count | Should -Be 1
            $script:sisCalls[0]['Status'] | Should -Be 'Success'
            (Get-D5Error $script:sisCalls[0]) | Should -Be 'Verified existing output'
            Should -Invoke -CommandName Get-VideoId -Times 0 -Exactly
        }

        It 'A1 NV=<Label> fall-through never produces a Success state call' -ForEach $d5NvCases {
            $script:d5Verdict = $Verdict
            $item = New-D5Item
            $script:Manifest = @($item)
            Invoke-ItemDownload -Item $item | Should -BeFalse
            @($script:sisCalls | Where-Object { $_['Status'] -eq 'Success' }).Count | Should -Be 0
        }

        # ---------- A2 ----------
        It 'A2 NV=<Label> fall-through makes no Set-ItemState call before Get-VideoId' -ForEach $d5NvCases {
            $script:d5Verdict = $Verdict
            $item = New-D5Item
            $script:Manifest = @($item)
            Invoke-ItemDownload -Item $item | Should -BeFalse
            $script:sisAtVid | Should -Be 0
        }

        # ---------- A3 ----------
        It 'A3 NV=<Label> reaches Get-VideoId once, no premature Success, expected Failed tail' -ForEach $d5NvCases {
            $script:d5Verdict = $Verdict
            $item = New-D5Item
            $script:Manifest = @($item)
            Invoke-ItemDownload -Item $item | Should -BeFalse
            Should -Invoke -CommandName Get-VideoId -Times 1 -Exactly
            $script:sisAtVid | Should -Be 0
            @($script:sisCalls | Where-Object { $_['Status'] -eq 'Success' }).Count | Should -Be 0
            $script:sisCalls.Count | Should -Be 1
            $script:sisCalls[-1]['Status']        | Should -Be 'Failed'
            $script:sisCalls[-1]['FailureKind']   | Should -Be 'Permanent'
            $script:sisCalls[-1]['RetryDecision'] | Should -Be 'Stop'
            (Get-D5Error $script:sisCalls[-1])    | Should -Be 'Cannot extract video id'
        }

        # ---------- A4 ----------
        It 'A4 Verdict=Unknown fall-through does not classify at the existing-output site' {
            $script:d5Verdict = @{ Verdict = 'Unknown'; Reason = 'ffprobe' }
            $item = New-D5Item
            $script:Manifest = @($item)
            Invoke-ItemDownload -Item $item | Should -BeFalse
            Should -Invoke -CommandName Get-VerdictFailureClass -Times 0 -Exactly
        }

        # ---------- A5 ----------
        It 'A5 Test-HibernateEligibility uses Test-FileValidity once and never Get-FileVerdict' {
            $script:RunState.ManifestSaved         = $true
            $script:RunState.SettingsSaved         = $true
            $script:RunState.LogsWritten           = $true
            $script:RunState.Interrupted           = $false
            $script:RunState.DownloadsCompleted    = $true
            $script:RunState.VerificationsPassed   = $true
            $script:RunState.PreviousInstanceCrashed = $false
            $script:StateInitialized               = $true
            $item = New-D5Item -Status 'Success'
            $script:CurrentRunItems = @($item)
            Test-HibernateEligibility -Requested $true | Should -BeTrue
            Should -Invoke -CommandName Test-FileValidity -Times 1 -Exactly
            Should -Invoke -CommandName Get-FileVerdict   -Times 0 -Exactly
        }

        It 'A5 Test-HibernateEligibility returns false when Test-FileValidity fails' {
            $script:RunState.ManifestSaved         = $true
            $script:RunState.SettingsSaved         = $true
            $script:RunState.LogsWritten           = $true
            $script:RunState.Interrupted           = $false
            $script:RunState.DownloadsCompleted    = $true
            $script:RunState.VerificationsPassed   = $true
            $script:RunState.PreviousInstanceCrashed = $false
            $script:StateInitialized               = $true
            $item = New-D5Item -Status 'Success'
            $script:CurrentRunItems = @($item)
            Mock Test-FileValidity { return $false }
            Test-HibernateEligibility -Requested $true | Should -BeFalse
        }

        # ---------- A6 ----------
        It 'A6 Valid verdict with mocked Set-ItemState never calls Test-FileValidity' {
            $item = New-D5Item
            $script:Manifest = @($item)
            Invoke-ItemDownload -Item $item | Should -BeTrue
            Should -Invoke -CommandName Test-FileValidity -Times 0 -Exactly
        }

        It 'A6 OutputFilePath=<Label> skips Get-FileVerdict and falls through' -ForEach @(
            @{ Label = 'empty';      Path = '' }
            @{ Label = 'whitespace'; Path = ' ' }
            @{ Label = 'null';       Path = $null }
        ) {
            $item = New-D5Item -OutputFilePath $Path
            $script:Manifest = @($item)
            Invoke-ItemDownload -Item $item | Should -BeFalse
            Should -Invoke -CommandName Get-FileVerdict -Times 0 -Exactly
            Should -Invoke -CommandName Get-VideoId     -Times 1 -Exactly
            $script:sisAtVid | Should -Be 0
        }

        It 'A6/R5 Valid verdict with Set-ItemState returning false returns false without Get-VideoId' {
            $script:sisReturn = $false
            $item = New-D5Item
            $script:Manifest = @($item)
            { $script:D5Result = Invoke-ItemDownload -Item $item } | Should -Not -Throw
            $script:D5Result | Should -BeFalse
            Should -Invoke -CommandName Get-VideoId -Times 0 -Exactly
        }

        # ---------- A8 ----------
        It 'A8 Mode=<Label> is never bound to Get-FileVerdict and falls through without throwing' -ForEach @(
            @{ Label = 'empty'; Mode = '' }
            @{ Label = 'null';  Mode = $null }
            @{ Label = 'Other'; Mode = 'Other' }
        ) {
            $item = New-D5Item -Mode $Mode
            $script:Manifest = @($item)
            { $script:D5Result = Invoke-ItemDownload -Item $item } | Should -Not -Throw
            $script:D5Result | Should -BeFalse
            Should -Invoke -CommandName Get-FileVerdict -Times 0 -Exactly
            Should -Invoke -CommandName Get-VideoId     -Times 1 -Exactly
            $script:sisAtVid | Should -Be 0
            @($script:sisCalls | Where-Object { $_['Status'] -eq 'Success' }).Count | Should -Be 0
        }

        # ---------- R2 (owner-accepted) ----------
        It 'R2-primary Status=<Status> AttemptCount=4 skips the loop and ends Failed/Unknown/Retry' -ForEach @(
            @{ Status = 'Failed' }, @{ Status = 'Pending' }
        ) {
            $script:d5Verdict = @{ Verdict = 'Corrupt'; Reason = 'bad' }
            $script:d5VideoId = 'abc'
            $item = New-D5Item -Status $Status -AttemptCount 4
            $script:Manifest = @($item)
            Invoke-ItemDownload -Item $item | Should -BeFalse
            $script:sisCalls[-1]['Status']        | Should -Be 'Failed'
            $script:sisCalls[-1]['FailureKind']   | Should -Be 'Unknown'
            $script:sisCalls[-1]['RetryDecision'] | Should -Be 'Retry'
            @($script:sisCalls | Where-Object { $_['Status'] -eq 'Downloading' }).Count | Should -Be 0
            @($script:sisCalls | Where-Object { $_.ContainsKey('AttemptCount') }).Count | Should -Be 0
            @($script:sisCalls | Where-Object { $_.ContainsKey('RetryCount') }).Count   | Should -Be 0
            Should -Invoke -CommandName yt-dlp -Times 0 -Exactly
        }

        It 'R2-secondary owner-accepted R2: Success AttemptCount=4 ends Failed/Unknown/Retry' {
            $script:d5Verdict = @{ Verdict = 'Corrupt'; Reason = 'bad' }
            $script:d5VideoId = 'abc'
            $item = New-D5Item -Status 'Success' -AttemptCount 4
            $script:Manifest = @($item)
            Invoke-ItemDownload -Item $item | Should -BeFalse
            $script:sisCalls[-1]['Status']        | Should -Be 'Failed'
            $script:sisCalls[-1]['FailureKind']   | Should -Be 'Unknown'
            $script:sisCalls[-1]['RetryDecision'] | Should -Be 'Retry'
            @($script:sisCalls | Where-Object { $_['Status'] -eq 'Downloading' }).Count | Should -Be 0
            @($script:sisCalls | Where-Object { $_.ContainsKey('AttemptCount') }).Count | Should -Be 0
            @($script:sisCalls | Where-Object { $_.ContainsKey('RetryCount') }).Count   | Should -Be 0
            Should -Invoke -CommandName yt-dlp -Times 0 -Exactly
        }

        # ---------- R6 ----------
        It 'R6 Pending with empty OutputFilePath never calls Get-FileVerdict and falls through' {
            $item = New-D5Item -Status 'Pending' -Mode 'Video' -OutputFilePath ''
            $script:Manifest = @($item)
            Invoke-ItemDownload -Item $item | Should -BeFalse
            Should -Invoke -CommandName Get-FileVerdict -Times 0 -Exactly
            Should -Invoke -CommandName Get-VideoId     -Times 1 -Exactly
        }
    }

    Context 'Runtime - real Get-FileVerdict (A8 case-insensitive Mode)' {

        BeforeEach {
            Mock Get-MediaInfo {
                return @{ Success = $true; HasVideo = $true; HasAudio = $false
                          VideoPackets = 100; AudioPackets = 0; Duration = 10.0
                          Error = $null; IsCommandFailure = $false }
            }
        }

        It 'A8 Mode=video (lowercase) binds case-insensitively and accepts the existing output' {
            $item = New-D5Item -Mode 'video'
            $script:Manifest = @($item)
            { $script:D5Result = Invoke-ItemDownload -Item $item } | Should -Not -Throw
            $script:D5Result | Should -BeTrue
            $script:sisCalls.Count | Should -Be 1
            $script:sisCalls[0]['Status'] | Should -Be 'Success'
            (Get-D5Error $script:sisCalls[0]) | Should -Be 'Verified existing output'
        }
    }

    Context 'AST and source contracts' {

        BeforeAll {
            $script:D5ScriptPath = Join-Path $PSScriptRoot '..\Development\YT-Downloader.ps1'
            $d5Tokens = $null; $d5Errors = $null
            $script:D5Ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:D5ScriptPath, [ref]$d5Tokens, [ref]$d5Errors)
            $script:D5Funcs = @($script:D5Ast.FindAll(
                { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))

            function script:Get-D5FunctionAst {
                param([string]$Name)
                return @($script:D5Funcs | Where-Object { $_.Name -eq $Name })[0]
            }
            function script:Get-D5Commands {
                param($Root, [string]$Name)
                if ($null -eq $Root) { return @() }
                $all = @($Root.FindAll(
                    { param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true))
                if ([string]::IsNullOrEmpty($Name)) { return $all }
                return @($all | Where-Object { $_.GetCommandName() -eq $Name })
            }

            $script:D5InvokeAst = Get-D5FunctionAst 'Invoke-ItemDownload'
            $d5Stmts = @($script:D5InvokeAst.Body.EndBlock.Statements)
            $d5Idx = -1
            for ($i = 0; $i -lt $d5Stmts.Count; $i++) {
                if ($d5Stmts[$i] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $d5Stmts[$i].Left.Extent.Text -eq '$expectedId') { $d5Idx = $i; break }
            }
            $script:D5ExpectedIdIndex = $d5Idx
            $script:D5PreStmt  = if ($d5Idx -ge 2) { $d5Stmts[$d5Idx - 2] } else { $null }
            $script:D5Site     = if ($d5Idx -ge 1) { $d5Stmts[$d5Idx - 1] } else { $null }
        }

        It 'A2 the site is the IfStatementAst between the $dest try/catch and $expectedId, with one Get-FileVerdict and one Set-ItemState in the Valid branch' {
            $script:D5ExpectedIdIndex | Should -BeGreaterThan 1
            $script:D5PreStmt | Should -BeOfType ([System.Management.Automation.Language.TryStatementAst])
            $script:D5Site    | Should -BeOfType ([System.Management.Automation.Language.IfStatementAst])
            (Get-D5Commands -Root $script:D5Site -Name 'Get-FileVerdict').Count | Should -Be 1
            (Get-D5Commands -Root $script:D5Site -Name 'Set-ItemState').Count   | Should -Be 1
            $d5Ifs = @($script:D5Site.FindAll(
                { param($a) $a -is [System.Management.Automation.Language.IfStatementAst] }, $true))
            $d5ValidIf = @($d5Ifs | Where-Object {
                $_.Clauses[0].Item1.Extent.Text -match "Verdict\s*-eq\s*'Valid'" })
            $d5ValidIf.Count | Should -Be 1
            (Get-D5Commands -Root $d5ValidIf[0] -Name 'Set-ItemState').Count | Should -Be 1
        }

        It 'A2 the site contains zero Write-Log, Move-ToInvalid, Get-VerdictFailureClass and Test-FileValidity calls' {
            $script:D5Site | Should -Not -BeNullOrEmpty
            foreach ($n in 'Write-Log', 'Move-ToInvalid', 'Get-VerdictFailureClass', 'Test-FileValidity') {
                (Get-D5Commands -Root $script:D5Site -Name $n).Count | Should -Be 0
            }
        }

        It 'A5 Test-FileValidity is absent from Invoke-ItemDownload and present in the four protected functions' {
            (Get-D5Commands -Root $script:D5InvokeAst -Name 'Test-FileValidity').Count | Should -Be 0
            foreach ($n in 'Test-HibernateEligibility', 'Get-RetryPlan', 'Start-DownloadRun', 'Set-ItemState') {
                $f = Get-D5FunctionAst $n
                $f | Should -Not -BeNullOrEmpty
                (Get-D5Commands -Root $f -Name 'Test-FileValidity').Count | Should -BeGreaterThan 0
            }
        }

        It 'A7 the Invoke-ItemDownload param block is preserved' {
            # FunctionDefinitionAst exposes Parameters/Body; ParamBlock lives on Body.
            $pb = $script:D5InvokeAst.Body.ParamBlock
            $pb | Should -Not -BeNullOrEmpty
            ($pb.Extent.Text -replace '\s+', ' ').Trim() | Should -Be 'param([PSCustomObject]$Item)'
        }

        It 'A7 the only $script: tokens in Invoke-ItemDownload are AudioArchive and VideoArchive' {
            $rx = [regex]::Matches($script:D5InvokeAst.Extent.Text, '\$script:([A-Za-z_][A-Za-z0-9_]*)')
            $names = @($rx | ForEach-Object { $_.Groups[1].Value })
            $names.Count | Should -Be 2
            (@($names | Sort-Object -Unique) -join ',') | Should -Be 'AudioArchive,VideoArchive'
        }

        It 'A7 Get-MaxAttempts is called exactly once in Invoke-ItemDownload' {
            (Get-D5Commands -Root $script:D5InvokeAst -Name 'Get-MaxAttempts').Count | Should -Be 1
        }
    }

    # A4/A5/A7 - Source equality against the pre-D5 baseline.
    # DELIVERY-SCOPED CONTRACT: pinned to the immediate pre-D5 commit. If a later
    # delivery legitimately changes any of these eight functions, this Context
    # must be re-baselined or retired. Requires git + full history at test time.
    Context 'Pre-D5 baseline preservation (A4/A5/A7)' {

        BeforeAll {
            $script:D5BaselineCommit = '9618d3a1b3c5acafd2a21e47570074bc8f034f3d'
            $script:D5RepoRoot       = Split-Path -Path $PSScriptRoot -Parent
            $script:D5BaselineError  = $null
            $script:D5BaselineMap    = @{}
            $script:D5CurrentMap     = @{}

            function script:Get-D5FuncMap {
                param([string]$Text)
                $t = $null; $e = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$t, [ref]$e)
                $map = @{}
                $funcs = @($ast.FindAll(
                    { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
                foreach ($f in $funcs) {
                    if (-not $map.ContainsKey($f.Name)) { $map[$f.Name] = $f.Extent.Text }
                }
                return $map
            }

            if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
                $script:D5BaselineError = 'git is not on PATH; the pre-D5 baseline cannot be read.'
            }
            else {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = 'git'
                $psi.Arguments = "-C `"$($script:D5RepoRoot)`" show $($script:D5BaselineCommit):Development/YT-Downloader.ps1"
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $psi.UseShellExecute        = $false
                $proc    = [System.Diagnostics.Process]::Start($psi)
                $errTask = $proc.StandardError.ReadToEndAsync()
                $ms      = New-Object System.IO.MemoryStream
                $proc.StandardOutput.BaseStream.CopyTo($ms)
                $proc.WaitForExit()
                if ($proc.ExitCode -ne 0) {
                    $script:D5BaselineError = "git show failed (exit $($proc.ExitCode)): $($errTask.Result)"
                }
                else {
                    $utf8     = New-Object System.Text.UTF8Encoding($false)
                    $baseText = $utf8.GetString($ms.ToArray()).TrimStart([char]0xFEFF) -replace "`r`n", "`n"
                    $curPath  = Join-Path $script:D5RepoRoot 'Development\YT-Downloader.ps1'
                    $curText  = $utf8.GetString([System.IO.File]::ReadAllBytes($curPath)).TrimStart([char]0xFEFF) -replace "`r`n", "`n"
                    $script:D5BaselineMap = Get-D5FuncMap -Text $baseText
                    $script:D5CurrentMap  = Get-D5FuncMap -Text $curText
                }
            }
        }

        It 'A4/A5/A7 <Name> Extent.Text is identical to the pre-D5 baseline' -ForEach @(
            @{ Name = 'Get-VerdictFailureClass' }
            @{ Name = 'Get-FileVerdict' }
            @{ Name = 'Test-FileValidity' }
            @{ Name = 'Test-HibernateEligibility' }
            @{ Name = 'Set-ItemState' }
            @{ Name = 'Get-RetryPlan' }
            @{ Name = 'Start-DownloadRun' }
            @{ Name = 'Main' }
        ) {
            $script:D5BaselineError | Should -BeNullOrEmpty -Because 'the pre-D5 baseline must be readable via git'
            $script:D5BaselineMap.ContainsKey($Name) | Should -BeTrue -Because "the baseline must define $Name"
            $script:D5CurrentMap.ContainsKey($Name)  | Should -BeTrue -Because "the current file must define $Name"
            $script:D5CurrentMap[$Name] | Should -BeExactly $script:D5BaselineMap[$Name]
        }
    }
}
