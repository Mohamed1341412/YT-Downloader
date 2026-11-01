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

        It "Fails if target invalid file already exists (prevents overwrite)" {
            $mockTargetPath = Join-Path $script:TestDir "valid_video.mp4.invalid_20231010_120000_12345678"
            Set-Content -Path $mockTargetPath -Value "existing" -Force
            
            Mock Get-InvalidTargetPath { return $mockTargetPath }
            
            $moveResult = Move-ToInvalid -FilePath $script:ValidVideoPath -Directory $script:TestDir
            $moveResult.Success | Should -BeFalse
            $moveResult.Error | Should -Match "already exists"
            Test-Path -LiteralPath $script:ValidVideoPath | Should -BeTrue
        }
    }
}
