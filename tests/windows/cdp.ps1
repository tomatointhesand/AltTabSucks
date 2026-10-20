# cdp.ps1 - minimal Chrome DevTools Protocol client (dot-source it), for driving a page in Edge from
# tests/windows/e2e.ps1. Windows PowerShell 5.1 compatible: System.Net.WebSockets.ClientWebSocket.
#
# Edge has to be started with --remote-debugging-port and its own --user-data-dir: current
# Chromium ignores remote debugging on the default profile.

# Connects to the first page target whose URL matches $urlLike (waits up to $seconds for it).
function Connect-Cdp([int]$port, [string]$urlLike, [int]$seconds = 30) {
    $deadline = (Get-Date).AddSeconds($seconds)
    $target = $null
    while (-not $target -and (Get-Date) -lt $deadline) {
        try {
            # Into a variable first: 5.1's Invoke-RestMethod emits a JSON array as one object, which a
            # pipeline would hand to Where-Object whole instead of item by item.
            $list = Invoke-RestMethod "http://127.0.0.1:$port/json" -TimeoutSec 2
            $target = $list | Where-Object { $_.type -eq "page" -and $_.url -like $urlLike } | Select-Object -First 1
        } catch {}
        if (-not $target) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $target) { throw "no page matching $urlLike on port $port" }
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
    $script:CdpSocket = $ws
    $script:CdpNextId = 0
}

function Receive-CdpMessage {
    $buffer = New-Object byte[] 65536
    $text = New-Object Text.StringBuilder
    do {
        $seg = New-Object ArraySegment[byte] -ArgumentList (, $buffer)
        $task = $script:CdpSocket.ReceiveAsync($seg, [Threading.CancellationToken]::None)
        if (-not $task.Wait(30000)) { throw "CDP: no message within 30s" }
        [void]$text.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $task.Result.Count))
    } while (-not $task.Result.EndOfMessage)
    $text.ToString() | ConvertFrom-Json
}

# Evaluates JavaScript in the page (promises awaited) and returns its JSON-able value. Throws on
# a JavaScript exception.
function Invoke-Js([string]$expression) {
    $id = ++$script:CdpNextId
    $msg = ConvertTo-Json -Compress -Depth 5 -InputObject @{
        id = $id; method = "Runtime.evaluate"
        params = @{ expression = $expression; awaitPromise = $true; returnByValue = $true }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
    $seg = New-Object ArraySegment[byte] -ArgumentList (, $bytes)
    $script:CdpSocket.SendAsync($seg, [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
    while ($true) {
        $reply = Receive-CdpMessage
        if ($reply.id -ne $id) { continue }  # an event, or a reply to something else
        if ($reply.error) { throw "CDP: $($reply.error.message)" }
        if ($reply.result.exceptionDetails) { throw "JS: $($reply.result.exceptionDetails.exception.description)" }
        return $reply.result.result.value
    }
}

function Disconnect-Cdp {
    if ($script:CdpSocket) {
        try { $script:CdpSocket.CloseAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", [Threading.CancellationToken]::None).Wait(2000) | Out-Null } catch {}
        $script:CdpSocket = $null
    }
}
