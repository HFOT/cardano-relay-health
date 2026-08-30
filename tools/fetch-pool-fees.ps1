<#
  Writes each pool's declared fees to <OutDir>/pool_fees.csv.

  Two numbers decide what a delegator actually receives, after saturation:

    margin      the operator's percentage of the pool's rewards
    fixed cost  a flat amount taken each epoch before the margin, with a
                protocol minimum (minPoolCost) that many pools sit exactly on

  The fixed cost matters most to a delegator in a small pool: a flat charge is
  a large share of a small epoch reward and a negligible share of a large one.

  Both are the operator's own declaration, registered on chain, and both are
  ordinary business choices - a higher fee is not a fault. So this is display
  only and never scored, like the other citations.

  Roughly 7 requests for the whole chain, no key needed. Display only, so the
  caller may carry on without the file: the page then omits the fee line.
#>
param([string]$OutDir = 'data')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$pools = @()
for ($offset = 0; $offset -lt 50000; $offset += 1000) {
  $uri = "https://api.koios.rest/api/v1/pool_list?select=pool_id_bech32,margin,fixed_cost&limit=1000&offset=$offset"
  $page = Invoke-RestMethod -Uri $uri -TimeoutSec 90
  if (-not $page) { break }
  $pools += $page
  if ($page.Count -lt 1000) { break }
}
if ($pools.Count -lt 1000) { throw "pool_list returned only $($pools.Count) pools - refusing to write a suspiciously short list" }

$rows = foreach ($p in $pools) {
  if ($null -eq $p.margin -and $null -eq $p.fixed_cost) { continue }
  [pscustomobject]@{
    pool_bech32 = $p.pool_id_bech32
    margin      = $p.margin
    fixed_ada   = [long]([double]$p.fixed_cost / 1000000)
  }
}
$rows = @($rows)

New-Item -ItemType Directory -Force $OutDir | Out-Null
$outFile = Join-Path $OutDir 'pool_fees.csv'
if ($rows.Count -gt 0) { $rows | Export-Csv -NoTypeInformation -Encoding UTF8 $outFile }
else { Set-Content -Path $outFile -Value 'pool_bech32,margin,fixed_ada' -Encoding UTF8 }

$minFixed = ($rows | Measure-Object -Property fixed_ada -Minimum).Minimum
Write-Output ("Fetched fees for {0} of {1} pools; lowest fixed cost seen {2:N0} ADA" -f $rows.Count, $pools.Count, $minFixed)
