<#
  Writes the current saturation point to <OutDir>/network_params.csv.

  A pool is saturated once its stake passes the saturation point. Past it,
  further delegation earns proportionally less, so it is worth showing next to
  the stake - but it says nothing about how the pool is run, so it is display
  only and never scored. Stake concentration is already in the "reference only,
  never deducted" list.

  The point is (maxLovelaceSupply - reserves) / k:

    z0, the relative saturation size, is 1/k, and the ledger's sigma is a
    fraction of the total supply. Koios reports that total as `supply` in
    /totals, and it equals 45,000,000,000 ADA minus reserves exactly.
    k is optimal_pool_count from /epoch_params, currently 500.

  Do NOT use `circulation` for this. It is `supply` minus the treasury and
  deposits, which is ~5.5% smaller and produces a saturation point that is too
  low - an error this script was written with and corrected after checking
  against Koios's own live_saturation.

  That check is now part of the script: the computed point is verified against
  live_stake / live_saturation for a sample of real pools, and the script fails
  rather than writing a figure that disagrees. Getting this wrong would put a
  visibly wrong line on every row, so it hard-fails instead of degrading.
  The caller may still carry on without the file - the page then shows stake
  with no saturation marker.
#>
param([string]$OutDir = 'data')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$api = 'https://api.koios.rest/api/v1'

$totals = Invoke-RestMethod -Uri "$api/totals?limit=1" -TimeoutSec 60
$params = Invoke-RestMethod -Uri "$api/epoch_params?limit=1" -TimeoutSec 60

$supplyAda   = [double]$totals[0].supply / 1000000
$reservesAda = [double]$totals[0].reserves / 1000000
$k           = [int]$params[0].optimal_pool_count
if ($supplyAda -lt 1e9) { throw "supply looks wrong ($supplyAda ADA)" }
if ($k -lt 1)           { throw "optimal_pool_count looks wrong ($k)" }

# supply should be maxLovelaceSupply (45B) minus reserves. If it is not, the basis has moved.
$expected = 45000000000 - $reservesAda
if ([Math]::Abs($supplyAda - $expected) / $expected -gt 0.0001) {
  throw "supply ($supplyAda) is not 45B - reserves ($expected). The basis for saturation may have changed."
}

$point = $supplyAda / $k

# --- cross-check the figure against Koios's own live_saturation ---
$ids = (Invoke-RestMethod -Uri "$api/pool_list?select=pool_id_bech32&limit=40" -TimeoutSec 60).pool_id_bech32
$body = @{ _pool_bech32_ids = @($ids) } | ConvertTo-Json -Compress
$info = Invoke-RestMethod -Uri "$api/pool_info" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 90

# live_saturation is a percentage. Small values round too coarsely, so only use >= 5%.
$implied = @()
foreach ($p in $info) {
  $sat = [double]$p.live_saturation
  $live = [double]$p.live_stake / 1000000
  if ($sat -ge 5 -and $live -gt 0) { $implied += ($live / ($sat / 100)) }
}
if ($implied.Count -lt 3) {
  Write-Output "::warning::Only $($implied.Count) pools were usable for the saturation cross-check; skipping it this run."
} else {
  $sorted = @($implied | Sort-Object)
  $median = $sorted[[int]($sorted.Count / 2)]
  $drift = [Math]::Abs($point - $median) / $median
  if ($drift -gt 0.01) {
    throw ("Saturation point {0:N0} disagrees with Koios live_saturation ({1:N0}, {2:P2} off) across {3} pools. Refusing to publish." -f $point, $median, $drift, $implied.Count)
  }
  Write-Output ("  cross-check: {0} pools imply {1:N0} ADA ({2:P4} from ours)" -f $implied.Count, $median, $drift)
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
[pscustomobject]@{
  epoch          = $totals[0].epoch_no
  supply_ada     = [long]$supplyAda
  reserves_ada   = [long]$reservesAda
  optimal_pools  = $k
  saturation_ada = [long]$point
} | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $OutDir 'network_params.csv')

Write-Output ("Epoch {0}: supply {1:N0} ADA / k={2} -> saturation {3:N0} ADA" -f `
  $totals[0].epoch_no, $supplyAda, $k, $point)
