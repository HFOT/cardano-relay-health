<#
  Writes a short stake history per pool to <OutDir>/pool_history.csv, for the
  sparkline next to each stake figure.

  Stake only moves at epoch boundaries, and an epoch is five days, so the unit
  here is the epoch and not the day. Eighteen of them is about three months,
  which is as far back as the page plots.

  Koios has no bulk form of pool_history - it is one request per pool - so this
  is the only fetch here that needs to run in parallel to finish in reasonable
  time. Sequentially it takes about 95 minutes; at eight at a time, about
  thirteen. Eight is deliberate restraint on a free public API rather than the
  fastest the endpoint will go.

  Written for Windows PowerShell 5.1 like the rest of tools/, so it uses a
  runspace pool rather than ForEach-Object -Parallel, which is 7-only.

  Display only, never scored - how much stake a pool has gained or lost says
  nothing about how it is run. Failures degrade quietly: a pool that could not
  be fetched simply has no sparkline, and if the whole run fails the page is
  built without any.
#>
param(
  [string]$OutDir = 'data',
  [int]$Epochs = 18,
  [int]$Parallel = 8
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::DefaultConnectionLimit = 64

$srcPath = Join-Path $OutDir 'relay_pool_health.csv'
if (-not (Test-Path $srcPath)) { throw "relay_pool_health.csv not found in $OutDir" }

# Only the pools the page actually ranks - the same filter the generator uses.
$ids = @()
foreach ($r in (Import-Csv $srcPath)) {
  if ($r.minted_last_30_epochs -ne 't') { continue }
  if ([double]($r.blocks_last_30_epochs -as [double]) -le 0) { continue }
  if ([double]($r.endpoints_probed -as [double]) -le 0) { continue }
  $ids += $r.pool_bech32
}
Write-Output "  fetching $Epochs epochs for $($ids.Count) pools, $Parallel at a time"

$work = {
  param($poolId, $epochs)
  $uri = "https://api.koios.rest/api/v1/pool_history?_pool_bech32=$poolId&limit=$epochs&select=epoch_no,active_stake"
  for ($try = 1; $try -le 3; $try++) {
    try {
      $r = Invoke-RestMethod -Uri $uri -TimeoutSec 45
      # newest first from the API; the page wants oldest first
      $vals = @($r | Sort-Object epoch_no | ForEach-Object {
        [Math]::Round([double]$_.active_stake / 1000000000000, 2)
      })
      if ($vals.Count -lt 2) { return $null }
      return [pscustomobject]@{ pool_bech32 = $poolId; series = ($vals -join ',') }
    } catch {
      if ($try -eq 3) { return $null }
      Start-Sleep -Seconds (2 * $try)
    }
  }
}

$rsPool = [runspacefactory]::CreateRunspacePool(1, $Parallel)
$rsPool.Open()
$rows = New-Object System.Collections.ArrayList
$done = 0
# Chunked so we are not holding 1,300 PowerShell instances open at once.
for ($i = 0; $i -lt $ids.Count; $i += 200) {
  $chunk = $ids[$i..([Math]::Min($i + 199, $ids.Count - 1))]
  $running = @()
  foreach ($id in $chunk) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $rsPool
    [void]$ps.AddScript($work).AddArgument($id).AddArgument($Epochs)
    $running += [pscustomobject]@{ ps = $ps; handle = $ps.BeginInvoke() }
  }
  foreach ($j in $running) {
    $res = $null
    try { $res = $j.ps.EndInvoke($j.handle) } catch { }
    $j.ps.Dispose()
    if ($res) { foreach ($x in $res) { if ($x) { [void]$rows.Add($x) } } }
  }
  $done += $chunk.Count
  Write-Output ("    {0}/{1} pools, {2} with history" -f $done, $ids.Count, $rows.Count)
}
$rsPool.Close(); $rsPool.Dispose()

if ($rows.Count -lt ($ids.Count * 0.5)) {
  throw "Only $($rows.Count) of $($ids.Count) pools returned history - refusing to write a half-empty file."
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$rows | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $OutDir 'pool_history.csv')
Write-Output "Wrote history for $($rows.Count) pools."
