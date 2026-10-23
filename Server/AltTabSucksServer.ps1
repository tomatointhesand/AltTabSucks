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

# profile display names pushed by AHK at startup: ["Default", "Work", ...]
$profileList = @()

# Hotkeys UI (shared with the Linux port). lib/app-hotkeys.ahk is its single source of truth: the
# page shows every recognizable hotkey line in it, and Save rewrites just those lines (see
# AppHotkeys.ps1). AltTabSucks.ahk (lib/hotkeys-ui.ahk) reloads itself when the file changes.
$repoRoot          = Split-Path $PSScriptRoot -Parent
$hotkeysUiPath     = Join-Path $repoRoot "shared\hotkeys-ui.html"
$appHotkeysPath    = Join-Path $repoRoot "lib\app-hotkeys.ahk"
$starterHotkeys    = Join-Path $repoRoot "lib\hotkeys.template.json"
# Left over from the earlier JSON-based Hotkeys UI; folded back into app-hotkeys.ahk once (POST /init-hotkeys)
$legacyHotkeysJson = Join-Path $repoRoot "lib\hotkeys.json"
$legacyGenerated   = Join-Path $repoRoot "lib\hotkeys-ui.generated.ahk"
. (Join-Path $PSScriptRoot "AppHotkeys.ps1")

function Read-AppHotkeysText {
    if (Test-Path $appHotkeysPath) { [IO.File]::ReadAllText($appHotkeysPath) } else { "" }
}
# Identifies the exact file contents the page loaded, so a save can't silently overwrite a hand
# edit made in between.
function Get-AppHotkeysHash([string]$text) {
    # Create().ComputeHash, not SHA256.HashData/Convert.ToHexString: the server runs under Windows
    # PowerShell 5.1 (Server/launch-hidden.vbs), whose .NET Framework has neither.
    $sha = [Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString("X2") }) }
    finally { $sha.Dispose() }
}
# Writes app-hotkeys.ahk, keeping the previous version as app-hotkeys.ahk.bak and the file's
# existing BOM (or lack of one). Writing it is what triggers the AHK reload.
function Save-AppHotkeysText([string]$text) {
    $hadBom = $false
    if (Test-Path $appHotkeysPath) {
        $bytes = [IO.File]::ReadAllBytes($appHotkeysPath)
        $hadBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        Copy-Item $appHotkeysPath "$appHotkeysPath.bak" -Force
    }
    [IO.File]::WriteAllText($appHotkeysPath, $text, (New-Object Text.UTF8Encoding($hadBom)))
}

function Send-Body($res, [string]$out, [string]$contentType, [int]$status = 200) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($out)
    $res.StatusCode      = $status
    $res.ContentType     = $contentType
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}
function Send-Json($res, $obj, [int]$status = 200) {
    Send-Body $res (ConvertTo-Json -InputObject $obj -Depth 10 -Compress) "application/json; charset=utf-8" $status
}

# Configured browser exe name from lib/config.ahk, shown in the UI header.
function Get-ConfiguredBrowser {
    $cfg = Join-Path $repoRoot "lib\config.ahk"
    if (-not (Test-Path $cfg)) { return "" }
    $text = Get-Content $cfg -Raw
    foreach ($var in "CHROMIUM_EXE", "FIREFOX_EXE") {
        if ($text -match "(?m)^\s*(?:global\s+)?$var\s*:=\s*`"([^`"]+)`"") { return Split-Path $Matches[1] -Leaf }
    }
    ""
}

try { while ($listener.IsListening) {
    $res = $null
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
        if ($origin -like "chrome-extension://*" -or $origin -like "moz-extension://*") {
            $res.Headers.Add("Access-Control-Allow-Origin",  $origin)
            $res.Headers.Add("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
            $res.Headers.Add("Access-Control-Allow-Headers", "Content-Type, X-AltTabSucks-Token")
            $res.Headers.Add("Access-Control-Max-Age",       "86400")
            $res.Headers.Add("Vary", "Origin")
        }

        $path   = $req.Url.AbsolutePath
        $method = $req.HttpMethod

        # The hotkeys UI page itself is public (a browser navigation can't send the token header);
        # it contains no secrets, and every API call it makes sends the token the user pastes in.
        if ($method -eq "GET" -and $path -eq "/hotkeys-ui") {
            if (Test-Path $hotkeysUiPath) {
                Send-Body $res (Get-Content $hotkeysUiPath -Raw -Encoding UTF8) "text/html; charset=utf-8"
            } else {
                $res.StatusCode = 404
            }
            $res.OutputStream.Close()
            continue
        }
        # The page's favicon (the extension's icon): no token either, the browser fetches it itself.
        # Only these names, so the path can't reach anything else on disk.
        if ($method -eq "GET" -and $path -in "/icons/icon-16.png", "/icons/icon-48.png", "/icons/icon-128.png") {
            $iconFile = Join-Path $repoRoot ("BrowserExtension\icons\" + $path.Substring(7))
            if (Test-Path $iconFile) {
                $bytes = [IO.File]::ReadAllBytes($iconFile)
                $res.ContentType = "image/png"
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            } else {
                $res.StatusCode = 404
            }
            $res.OutputStream.Close()
            continue
        }

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

        } elseif ($method -eq "POST" -and $path -eq "/profiles") {
            # AHK pushes the browser's profile display-name list at startup
            if ($req.ContentLength64 -lt 0 -or $req.ContentLength64 -gt 4KB) {
                $res.StatusCode = 413
            } else {
                $reader  = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $script:profileList = $body | ConvertFrom-Json
                $res.StatusCode = 204
            }

        } elseif ($method -eq "POST" -and $path -eq "/open-extension-page") {
            # The Hotkeys page's "Manage extension" link: a web page can't open edge://extensions
            # itself, the extension can. Asks the one in the browser you're using (the profile with
            # a focused window), else the first that has reported tabs.
            $target = $null
            foreach ($p in @($store.Keys)) { if (@($store[$p]) | Where-Object { $_.focused }) { $target = $p; break } }
            if (-not $target) { $target = @($store.Keys) | Select-Object -First 1 }
            if (-not $target) {
                Send-Json $res @{ error = "no browser with the AltTabSucks extension is connected" } 409
            } else {
                $switchQueue[$target] = @{ openExtensionsPage = $true }
                Send-Json $res @{ profile = $target }
            }

        } elseif ($method -eq "GET" -and $path -eq "/profiles") {
            # Extension Options page fetches this to populate the profile dropdown
            $out   = ConvertTo-Json -InputObject @($profileList) -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($out)
            $res.ContentType     = "application/json; charset=utf-8"
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)

        } elseif ($method -eq "POST" -and $path -eq "/tabs") {
            if ($req.ContentLength64 -lt 0 -or $req.ContentLength64 -gt 1MB) {
                $res.StatusCode = 413
            } else {
                $reader  = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $payload = $body | ConvertFrom-Json
                $store[$payload.profile] = $payload.windows
                $res.StatusCode = 204
            }

        } elseif ($method -eq "DELETE" -and $path -eq "/tabs") {
            $profile = $req.QueryString["profile"]
            if ($profile -and $store.ContainsKey($profile)) {
                $store.Remove($profile)
            }
            $res.StatusCode = 204

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
            if ($req.ContentLength64 -lt 0 -or $req.ContentLength64 -gt 4KB) {
                $res.StatusCode = 413
            } else {
                $reader  = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $payload = $body | ConvertFrom-Json
                if ($payload.splitTab) {
                    $switchQueue[$payload.profile] = @{ splitTab = $true }
                } elseif ($payload.mergeTabs) {
                    $switchQueue[$payload.profile] = @{ mergeTabs = $true }
                } elseif ($payload.openUrl) {
                    $switchQueue[$payload.profile] = @{ openUrl = $payload.openUrl }
                } else {
                    $switchQueue[$payload.profile] = @{ windowId = $payload.windowId; tabId = $payload.tabId }
                }
                $res.StatusCode = 204
            }

        } elseif ($method -eq "GET" -and $path -eq "/switchtab") {
            # extension polls this to dequeue a pending switch command.
            # Reject simple-request GETs from browser page origins — they send no preflight
            # so CORS alone doesn't block them from consuming queued switch commands.
            $profile = $req.QueryString["profile"]
            if ($origin -and $origin -notlike "chrome-extension://*" -and $origin -notlike "moz-extension://*") {
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

        } elseif ($method -eq "GET" -and $path -eq "/hotkeys-config") {
            $text = Read-AppHotkeysText
            $parsed = Read-AppHotkeys $text
            Send-Json $res @{
                bindings             = @($parsed.Bindings)
                invalid              = @($parsed.Invalid)   # shown as a warning; the next save removes them
                fileHash             = Get-AppHotkeysHash $text
                platform             = "windows"
                browserResourceClass = Get-ConfiguredBrowser
                sourceFile           = "lib/app-hotkeys.ahk"
            }

        } elseif ($method -eq "POST" -and $path -eq "/hotkeys-config") {
            if ($req.ContentLength64 -lt 0 -or $req.ContentLength64 -gt 256KB) {
                $res.StatusCode = 413
            } else {
                $reader = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                $body   = $reader.ReadToEnd()
                $reader.Close()
                try {
                    $config = $body | ConvertFrom-Json
                    $text = Read-AppHotkeysText
                    if ("$($config.fileHash)" -ne (Get-AppHotkeysHash $text)) {
                        Send-Json $res @{ error = "app-hotkeys.ahk changed since this page loaded it. Reload the page and redo your change." } 409
                    } else {
                        $w = Write-AppHotkeys $text @($config.bindings)
                        if ($w.Text -cne $text) { Save-AppHotkeysText $w.Text }
                        Send-Json $res @{
                            ok           = $true
                            bindingCount = $w.Saved
                            dropped      = @($w.Dropped)
                            note         = $(if ($w.Text -cne $text) { "AltTabSucks reloads itself within a second to apply them." } else { "Nothing changed." })
                        }
                    }
                } catch {
                    Send-Json $res @{ error = $_.Exception.Message } 400
                }
            }

        } elseif ($method -eq "POST" -and $path -eq "/init-hotkeys") {
            # AltTabSucks.ahk calls this on every startup with {profile}. Either folds a leftover
            # lib/hotkeys.json from the earlier JSON-based Hotkeys UI back into app-hotkeys.ahk
            # (once - the JSON file is then renamed out of the way), or adds the starter set from
            # lib/hotkeys.template.json to a file with no hotkeys yet (once - see Add-StarterHotkeys).
            try {
                $reader = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                $body   = $reader.ReadToEnd()
                $reader.Close()
                $profile = "$(($body | ConvertFrom-Json).profile)"
                $text = Read-AppHotkeysText
                $result = @{ folded = 0; seeded = 0; dropped = @() }
                if (Test-Path $legacyHotkeysJson) {
                    $legacy = Get-Content $legacyHotkeysJson -Raw -Encoding UTF8 | ConvertFrom-Json
                    $f = Merge-LegacyHotkeysJson $text @($legacy.bindings)
                    if ($f.Text -cne $text) { Save-AppHotkeysText $f.Text }
                    Move-Item $legacyHotkeysJson "$legacyHotkeysJson.folded-$(Get-Date -Format yyyyMMdd-HHmmss)"
                    if (Test-Path $legacyGenerated) { Remove-Item $legacyGenerated }
                    $result.folded = $f.Count; $result.dropped = @($f.Dropped)
                } elseif ($profile -and (Test-Path $starterHotkeys)) {
                    $s = Add-StarterHotkeys $text (Get-Content $starterHotkeys -Raw -Encoding UTF8) $profile
                    if ($s.Count) { Save-AppHotkeysText $s.Text }
                    $result.seeded = $s.Count; $result.dropped = @($s.Dropped)
                }
                Send-Json $res $result
            } catch {
                Send-Json $res @{ error = $_.Exception.Message } 400
            }

        } elseif ($method -eq "GET" -and $path -eq "/running-resource-classes") {
            # Feeds the page's process-name typeahead: every process with a visible main window.
            $procs = Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } | Sort-Object ProcessName -Unique
            Send-Json $res @($procs | ForEach-Object { @{ resourceClass = "$($_.ProcessName.ToLower()).exe"; resourceName = $_.MainWindowTitle } })

        } elseif ($method -eq "GET" -and $path -eq "/suggest-launch-command") {
            # Best-effort: the exe path of a running instance. Store-app paths under WindowsApps
            # can't be launched directly, so those are left for the user to fill in.
            $name = [IO.Path]::GetFileNameWithoutExtension("$($req.QueryString["resourceClass"])")
            $exe  = Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1 -ExpandProperty Path
            Send-Json $res @{ argv = @(if ($exe -and $exe -notlike "*\WindowsApps\*") { $exe }) }

        } else {
            $res.StatusCode = 404
        }

        $res.OutputStream.Close()
    } catch {
        # Swallow errors from dropped connections - but a handler that threw must still answer,
        # or the client waits forever for a response that never comes.
        if ($res) {
            try { $res.StatusCode = 500 } catch {}
            try { $res.OutputStream.Close() } catch {}
        }
    }
} } finally {
    $listener.Stop()
    Write-Host "Server stopped."
}
