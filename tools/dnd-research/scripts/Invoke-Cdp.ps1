param(
  [Parameter(Mandatory = $true)]
  [string]$Expression,
  [int]$Port = 9222
)

$ErrorActionPreference = 'Stop'
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list"
$target = @($targets) | Where-Object type -eq 'page' | Select-Object -First 1
if (-not $target) { throw "No page target found on port $Port." }

$socket = [Net.WebSockets.ClientWebSocket]::new()
try {
  $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
  $request = @{
    id = 1
    method = 'Runtime.evaluate'
    params = @{
      expression = $Expression
      returnByValue = $true
      awaitPromise = $true
    }
  } | ConvertTo-Json -Compress -Depth 8
  $bytes = [Text.Encoding]::UTF8.GetBytes($request)
  $segment = [ArraySegment[byte]]::new($bytes)
  $socket.SendAsync($segment, [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

  do {
    $stream = [IO.MemoryStream]::new()
    do {
      $buffer = [byte[]]::new(65536)
      $part = [ArraySegment[byte]]::new($buffer)
      $received = $socket.ReceiveAsync($part, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
      $stream.Write($buffer, 0, $received.Count)
    } while (-not $received.EndOfMessage)
    $message = [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
  } while ($message.id -ne 1)

  if ($message.error) { throw ($message.error | ConvertTo-Json -Compress) }
  if ($message.result.exceptionDetails) {
    throw ($message.result.exceptionDetails | ConvertTo-Json -Compress -Depth 8)
  }
  $message.result.result.value
} finally {
  if ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
    $socket.CloseAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', [Threading.CancellationToken]::None).GetAwaiter().GetResult()
  }
  $socket.Dispose()
}
