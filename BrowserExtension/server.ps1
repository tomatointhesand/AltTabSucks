$port = 9876
$url  = "http://localhost:$port/"

# Generate token.txt on first run; read it on subsequent runs.
$tokenPath = Join-Path $PSScriptRoot "token.txt"
if (-not (Test-Path $tokenPath)) {
    $rng   = [Security.Cryptography.RNGCryptoServiceProvider]::new()
    $bytes = [byte[]]::new(32)
    $rng.GetBytes($bytes)
    $rng.Dispose()
    $newToken = [Convert]::ToBase64String($bytes)
    Set-Content -Path $tokenPath -Value $newToken -Encoding UTF8 -NoNewline
    Write-Host "Generated new auth token: $newToken"
    Write-Host "Paste this token into the extension Options page."
}
$secret = (Get-Content $tokenPath -Raw -Encoding UTF8).Trim()

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($url)

try {
    $listener.Start()
} catch {
    Write-Error "Could not start listener on $url - already running?"
    exit 1
}

Write-Host "AltTabSucks server listening on $url (Ctrl+C to stop)"

# keyed by profile name: { "Default" => [...], "Work" => [...] }
$store = @{}

# pending tab-switch commands keyed by profile name
$switchQueue = @{}

try { while ($listener.IsListening) {
    try {
        $async = $listener.BeginGetContext($null, $null)
        while (-not $async.AsyncWaitHandle.WaitOne(500)) {
            if (-not $listener.IsListening) { break }
        }
        if (-not $listener.IsListening) { break }
        $ctx = $listener.EndGetContext($async)
        $req = $ctx.Request
        $res = $ctx.Response

        # Only grant CORS to browser extension origins.
        # Webpage origins (https://evil.com) are denied: browser blocks their response reads
        # and rejects their preflights, preventing tab enumeration and forced tab switches.
        # AHK uses WinHttp which sends no Origin header and ignores CORS entirely.
        $origin = $req.Headers["Origin"]
        if ($origin -like "chrome-extension://*") {
            $res.Headers.Add("Access-Control-Allow-Origin",  $origin)
            $res.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            $res.Headers.Add("Access-Control-Allow-Headers", "Content-Type, X-AltTabSucks-Token")
            $res.Headers.Add("Access-Control-Max-Age",       "86400")
            $res.Headers.Add("Vary", "Origin")
        }

        $path   = $req.Url.AbsolutePath
        $method = $req.HttpMethod

        # Validate shared secret on every non-preflight request.
        # AHK (WinHttp) sends no Origin header and is unaffected by CORS but still sends the token.
        if ($method -ne "OPTIONS") {
            $reqToken = $req.Headers["X-AltTabSucks-Token"]
            if ($reqToken -ne $secret) {
                $res.StatusCode = 403
                $res.OutputStream.Close()
                continue
            }
        }

        if ($method -eq "OPTIONS") {
            $res.StatusCode = 204

        } elseif ($method -eq "POST" -and $path -eq "/tabs") {
            if ($req.ContentLength64 -gt 1MB) {
                $res.StatusCode = 413
            } else {
                $reader  = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $payload = $body | ConvertFrom-Json
                $store[$payload.profile] = $payload.windows
                $res.StatusCode = 204
            }

        } elseif ($method -eq "GET" -and $path -eq "/tabs") {
            # return all profiles merged: { "Default": [...], "Work": [...] }
            $out   = $store | ConvertTo-Json -Depth 10
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($out)
            $res.ContentType     = "application/json; charset=utf-8"
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)

        } elseif ($method -eq "GET" -and $path -eq "/activetitles") {
            $profile = $req.QueryString["profile"]
            $windows = $store[$profile]
            $titles = @()
            if ($windows) {
                foreach ($w in $windows) {
                    $active = $w.tabs | Where-Object { $_.active } | Select-Object -First 1
                    if ($active) { $titles += $active.title }
                }
            }
            $out   = $titles -join "`n"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($out)
            $res.ContentType     = "text/plain; charset=utf-8"
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)

        } elseif ($method -eq "GET" -and $path -eq "/findtab") {
            # returns one line per matching tab: "windowId|tabId"
            $profile    = $req.QueryString["profile"]
            $urlPattern = $req.QueryString["url"]
            $safePattern = [WildcardPattern]::Escape($urlPattern)
            $found = [System.Collections.Generic.List[PSCustomObject]]::new()
            $windows = $store[$profile]
            if ($windows) {
                foreach ($w in $windows) {
                    foreach ($tab in $w.tabs) {
                        if ($tab.url -like "*$safePattern*") {
                            $found.Add([PSCustomObject]@{
                                line      = "$($w.id)|$($tab.id)"
                                micActive = [bool]$tab.micActive
                                audible   = [bool]$tab.audible
                                index     = [int]$tab.index
                            })
                        }
                    }
                }
            }
            # micActive first (getUserMedia audio stream active = in a call),
            # then audible (audio output as fallback), then leftmost by tab index
            $results = ($found | Sort-Object @{Expression='micActive';Descending=$true}, @{Expression='audible';Descending=$true}, @{Expression='index';Descending=$false}).line
            $out   = $results -join "`n"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($out)
            $res.ContentType     = "text/plain; charset=utf-8"
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)

        } elseif ($method -eq "POST" -and $path -eq "/switchtab") {
            # queue a tab-switch command for the extension to pick up
            if ($req.ContentLength64 -gt 4KB) {
                $res.StatusCode = 413
            } else {
                $reader  = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $payload = $body | ConvertFrom-Json
                $switchQueue[$payload.profile] = @{ windowId = $payload.windowId; tabId = $payload.tabId }
                $res.StatusCode = 204
            }

        } elseif ($method -eq "GET" -and $path -eq "/switchtab") {
            # extension polls this to dequeue a pending switch command.
            # Reject simple-request GETs from browser page origins — they send no preflight
            # so CORS alone doesn't block them from consuming queued switch commands.
            $profile = $req.QueryString["profile"]
            if ($origin -and $origin -notlike "chrome-extension://*") {
                $res.StatusCode = 204
            } elseif ($switchQueue.ContainsKey($profile) -and $null -ne $switchQueue[$profile]) {
                $cmd = $switchQueue[$profile]
                $switchQueue[$profile] = $null
                $out   = $cmd | ConvertTo-Json -Compress
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($out)
                $res.ContentType     = "application/json; charset=utf-8"
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            } else {
                $res.StatusCode = 204
            }

        } elseif ($method -eq "GET" -and $path -eq "/debugtabs") {
            $lines = [System.Collections.Generic.List[string]]::new()
            foreach ($profile in $store.Keys) {
                $lines.Add("=== $profile ===")
                foreach ($w in $store[$profile]) {
                    $wLabel = "  Window $($w.id)" + $(if ($w.focused) { " (focused)" } else { "" })
                    $lines.Add($wLabel)
                    foreach ($tab in $w.tabs) {
                        $flags = ""
                        if ($tab.micActive) { $flags += " [MIC]"     }
                        if ($tab.audible)   { $flags += " [audible]" }
                        if ($tab.active)    { $flags += " [active]"  }
                        $lines.Add("    [$($tab.index)] $($tab.title)$flags")
                    }
                }
                $lines.Add("")
            }
            $out   = $lines -join "`n"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($out)
            $res.ContentType     = "text/plain; charset=utf-8"
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)

        } else {
            $res.StatusCode = 404
        }

        $res.OutputStream.Close()
    } catch {
        # swallow errors from dropped connections
    }
} } finally {
    $listener.Stop()
    Write-Host "Server stopped."
}
