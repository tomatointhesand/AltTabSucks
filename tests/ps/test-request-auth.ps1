# test-request-auth.ps1 - tests for Server/RequestAuth.ps1: the Hotkeys page's own requests, and
# the extension pairing window.
# Run with: bash dev-scripts/run-ps-tests.sh

. "$PSScriptRoot/assert.ps1"
. "$PSScriptRoot/../../Server/RequestAuth.ps1"

# ---- the Hotkeys page's own requests ----------------------------------------------------------
Assert-Equal (Test-OwnPageRequest "same-origin" "localhost:9876" "" 9876) $true "the page's GET (no Origin)"
Assert-Equal (Test-OwnPageRequest "same-origin" "localhost:9876" "http://localhost:9876" 9876) $true "the page's POST"
Assert-Equal (Test-OwnPageRequest "same-origin" "127.0.0.1:9876" "http://127.0.0.1:9876" 9876) $true "opened as 127.0.0.1"
Assert-Equal (Test-OwnPageRequest "cross-site" "localhost:9876" "https://evil.example.com" 9876) $false "another site"
Assert-Equal (Test-OwnPageRequest "same-site" "localhost:9876" "http://localhost:3000" 9876) $false "another localhost port"
Assert-Equal (Test-OwnPageRequest "none" "localhost:9876" "" 9876) $false "typed into the address bar"
Assert-Equal (Test-OwnPageRequest "" "localhost:9876" "" 9876) $false "no Sec-Fetch-Site (not a browser page)"
Assert-Equal (Test-OwnPageRequest "same-origin" "evil.example.com:9876" "http://evil.example.com:9876" 9876) $false "DNS rebinding"
Assert-Equal (Test-OwnPageRequest "same-origin" "localhost:9876" "http://evil.example.com" 9876) $false "a mismatched Origin"
Assert-Equal (Test-OwnPageRequest "same-origin" "localhost:9999" "" 9876) $false "a different port"

# ---- the pairing window -----------------------------------------------------------------------
$now = [DateTime]::new(2026, 11, 2, 12, 0, 0)
$open = $now.AddMinutes(5)
Assert-Equal (Get-PairingToken "chrome-extension://abc" $open $now "s3cret") "s3cret" "Chromium extension, pairing open"
Assert-Equal (Get-PairingToken "moz-extension://1234-5678" $open $now "s3cret") "s3cret" "Firefox extension, pairing open"
Assert-Equal (Get-PairingToken "chrome-extension://abc" $now.AddSeconds(-1) $now "s3cret") $null "pairing closed"
Assert-Equal (Get-PairingToken "chrome-extension://abc" ([DateTime]::MinValue) $now "s3cret") $null "never opened"
Assert-Equal (Get-PairingToken "http://localhost:9876" $open $now "s3cret") $null "the Hotkeys page"
Assert-Equal (Get-PairingToken "https://evil.example.com" $open $now "s3cret") $null "a web page"
Assert-Equal (Get-PairingToken "" $open $now "s3cret") $null "no Origin (not a browser extension)"

Complete-Asserts
