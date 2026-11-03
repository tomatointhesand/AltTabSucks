# RequestAuth.ps1 - who may call the server without the X-AltTabSucks-Token header. Dot-sourced by
# AltTabSucksServer.ps1; the Linux server has the same rules (alttabsucks_server.py). Tested by
# tests/ps/test-request-auth.ps1.

# The Hotkeys page's own requests. The browser marks them same-origin (Sec-Fetch-Site, a header
# page scripts can't set; a request from any other site says cross-site or same-site), and the Host
# is this server's own name: a DNS-rebinding attacker's domain pointed at 127.0.0.1 arrives with
# its own name. Nothing else is served from this origin, so same-origin means our page. A local
# program could fake these headers, but it could read token.txt just as well.
function Test-OwnPageRequest([string]$SecFetchSite, [string]$HostHeader, [string]$Origin, [int]$Port) {
    $hosts = @("localhost:$Port", "127.0.0.1:$Port")
    $SecFetchSite -eq "same-origin" -and $HostHeader -in $hosts -and
        (-not $Origin -or $Origin -in ($hosts | ForEach-Object { "http://$_" }))
}

function Test-ExtensionOrigin([string]$Origin) {
    $Origin -like "chrome-extension://*" -or $Origin -like "moz-extension://*"
}

# How long POST /extension-token hands out the token after the server generates it or someone
# asks for pairing (installer, tray menu): long enough to load the extension.
$PairingWindow = [TimeSpan]::FromMinutes(10)

# POST /extension-token: the token, for a browser extension (its Origin, which web pages can't
# fake) while pairing is open; $null otherwise.
function Get-PairingToken([string]$Origin, [DateTime]$PairingUntil, [DateTime]$Now, [string]$Secret) {
    if ((Test-ExtensionOrigin $Origin) -and $Now -lt $PairingUntil) { $Secret } else { $null }
}
