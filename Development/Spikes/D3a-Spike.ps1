function Invoke-D3aSpike {
    [CmdletBinding()]
    param([switch]$NoGuard)

    $results = @()
    $prefs = @('Stop', 'Continue')
    
    foreach ($pref in $prefs) {
        $oldPref = $ErrorActionPreference
        $ErrorActionPreference = $pref
        try {
            foreach ($testName in @('Fake ERROR', 'yt-dlp bogus')) {
                $q = New-Object 'System.Collections.Generic.Queue[string]'
                $displayed = [System.Collections.Generic.List[string]]::new()
                $exceptionThrown = $false
                
try {
    $pipelineEAP = $ErrorActionPreference
    if (-not $NoGuard) { $ErrorActionPreference = 'Continue' }
    try {
        $global:LASTEXITCODE = $null
        if ($testName -eq 'Fake ERROR') {
            & cmd /c "echo ERROR: Fake error >&2 & exit /b 1" 2>&1 | ForEach-Object {
                $s = "$_"
                Write-Host $s
                [void]$displayed.Add($s)
                Add-CapturedLine -Queue $q -Line $s
            } | Out-Null
        } else {
            & yt-dlp --bogus-flag 2>&1 | ForEach-Object {
                $s = "$_"
                Write-Host $s
                [void]$displayed.Add($s)
                Add-CapturedLine -Queue $q -Line $s
            } | Out-Null
        }
    } finally {
        $ErrorActionPreference = $pipelineEAP
    }
} catch {
    $exceptionThrown = $true
}
                
                $ec = if ($null -eq $LASTEXITCODE) { -1 } else { $LASTEXITCODE }
                $captured = @($q.ToArray())
                
                $orderPreserved = $true
                $dIdx = 0
                foreach ($cLine in $captured) {
                    $found = $false
                    while ($dIdx -lt $displayed.Count) {
                        if ($displayed[$dIdx] -eq $cLine) {
                            $found = $true
                            $dIdx++
                            break
                        }
                        $dIdx++
                    }
                    if (-not $found) { $orderPreserved = $false; break }
                }
                
                $results += [PSCustomObject]@{
                    EAP             = $pref
                    Test            = $testName
                    ExceptionThrown = $exceptionThrown
                    LASTEXITCODE    = $ec
                    DisplayedLines  = $displayed.Count
                    CapturedLines   = $captured.Count
                    OrderPreserved  = $orderPreserved
                }
            }
        } finally {
            $ErrorActionPreference = $oldPref
        }
    }
    
    $results | Format-Table -AutoSize
}
