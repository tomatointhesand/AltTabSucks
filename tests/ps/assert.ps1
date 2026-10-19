# assert.ps1 - minimal assertion helpers for the PowerShell tests (dot-source it).
# A test script ends with Complete-Asserts, which exits 0 if everything passed and 1 otherwise.

$script:AssertPassed = 0
$script:AssertFailed = 0
$ErrorActionPreference = 'Stop'

function Assert-Equal($Actual, $Expected, [string]$Name) {
    $a = ConvertTo-Json -InputObject $Actual -Depth 10 -Compress
    $e = ConvertTo-Json -InputObject $Expected -Depth 10 -Compress
    if ($a -ceq $e) {
        $script:AssertPassed++
        Write-Host "PASS  $Name"
    } else {
        $script:AssertFailed++
        Write-Host "FAIL  $Name`n        expected: $e`n        actual:   $a"
    }
}

function Complete-Asserts {
    Write-Host "`n$script:AssertPassed passed, $script:AssertFailed failed"
    exit $(if ($script:AssertFailed -gt 0) { 1 } else { 0 })
}
