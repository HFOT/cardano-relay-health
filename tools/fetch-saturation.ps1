<#
  Writes the current saturation point to <OutDir>/network_params.csv.

  THE PROTOCOL RULE, implemented literally:

      z0              = 1 / k                       (relative saturation size)
      total stake     = maxLovelaceSupply - reserves
      saturation      = total stake * z0
                      = (maxLovelaceSupply - reserves) / k

  maxLovelaceSupply is a mainnet genesis constant, 45,000,000,000 ADA.
  reserves is read from the chain (/totals). k is optimal_pool_count (nOpt)
  from the current protocol parameters (/epoch_params).

  Sources for the rule:
    - Cardano docs, Pledging and rewards: z0 is the relative pool saturation
      size, and "z0, sigma and s are all relative, so they are fractions of
      the total supply".
    - The saturation cap is the maximum supply of ada (45bn) less whatever
      remains in the reserve, divided by k.

  This script computes the rule from its own terms rather than reading a
  field named "supply" from an API, so that a change in what an API calls
  things cannot silently change the figure. The API's own numbers are then
  used to check the result, twice:

    1. maxLovelaceSupply - reserves must equal the /totals `supply` field.
    2. The computed point must agree with Koios's own live_saturation,
       back-calculated from live_stake, across a sample of real pools.

  Either check failing stops the run. A wrong saturation point draws a
  visibly wrong line on every row, so this hard-fails rather than degrading.
  The caller may still carry on without the file - the page then shows stake
  with no saturation marker.

  Do NOT use the /totals `circulation` field. That is the total supply less
  the treasury, rewards and deposits - about 5.5% smaller - and it is not the
  ledger quantity the rule refers to.

  A pool past 100% earns no additional rewards, so further delegation to it is
  diluted. That is a fact about rewards and says nothing about how the pool is
  run, so this figure is display only and is never scored.
#>
param([string]$OutDir = 'data')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$api = 'https://api.koios.rest/api/v1'

$totals = Invoke-RestMethod -Uri "$api/totals?limit=1" -TimeoutSec 60
$params = Invoke-RestMethod -Uri "$api/epoch_params?limit=1" -TimeoutSec 60

# The rule, from its own terms.
$MAX_LOVELACE_SUPPLY_ADA = 45000000000        # mainnet genesis constant
$reservesAda = [double]$totals[0].reserves / 1000000
$k           = [int]$params[0].optimal_pool_count
if ($reservesAda -le 0)  { throw "reserves looks wrong ($reservesAda ADA)" }
if ($k -lt 1)            { throw "optimal_pool_count (nOpt) looks wrong ($k)" }

$totalStake = $MAX_LOVELACE_SUPPLY_ADA - $reservesAda
$z0         = 1.0 / $k
$point      = $totalStake * $z0

# Check 1: the quantity we just built must be what the chain reports as supply.
$reportedSupply = [double]$totals[0].supply / 1000000
if ([Math]::Abs($totalStake - $reportedSupply) / $reportedSupply -gt 0.0001) {
  throw ("maxLovelaceSupply - reserves ({0:N0}) does not match the reported supply ({1:N0}). The basis for saturation may have changed." -f $totalStake, $reportedSupply)
}

# Check 2: agree with Koios's own live_saturation on real pools.
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
  total_stake_ada = [long]$totalStake
  reserves_ada   = [long]$reservesAda
  optimal_pools  = $k
  saturation_ada = [long]$point
} | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $OutDir 'network_params.csv')

Write-Output ("Epoch {0}: (45,000,000,000 - {1:N0} reserves) / k={2} -> saturation {3:N0} ADA" -f `
  $totals[0].epoch_no, $reservesAda, $k, $point)
