<#
  Writes the current saturation point to <OutDir>/network_params.csv.

  A pool is saturated once its stake passes circulating supply / k, where k is
  the protocol's optimal_pool_count. Past that point further delegation earns
  proportionally less, so it is worth showing next to the stake - but it says
  nothing about how the pool is run, so it is display only and never scored.
  Stake concentration is already in the "reference only, never deducted" list.

  Two requests, no key needed. Display only, so the caller may carry on
  without this file: the page then shows stake without the saturation marker.
#>
param([string]$OutDir = 'data')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$totals = Invoke-RestMethod -Uri 'https://api.koios.rest/api/v1/totals?limit=1' -TimeoutSec 60
$params = Invoke-RestMethod -Uri 'https://api.koios.rest/api/v1/epoch_params?limit=1' -TimeoutSec 60

$circulationAda = [double]$totals[0].circulation / 1000000
$k              = [int]$params[0].optimal_pool_count
if ($circulationAda -lt 1e9) { throw "circulation looks wrong ($circulationAda ADA)" }
if ($k -lt 1) { throw "optimal_pool_count looks wrong ($k)" }

$point = $circulationAda / $k

New-Item -ItemType Directory -Force $OutDir | Out-Null
[pscustomobject]@{
  epoch            = $totals[0].epoch_no
  circulation_ada  = [long]$circulationAda
  optimal_pools    = $k
  saturation_ada   = [long]$point
} | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $OutDir 'network_params.csv')

Write-Output ("Epoch {0}: circulation {1:N0} ADA / k={2} -> saturation {3:N0} ADA" -f `
  $totals[0].epoch_no, $circulationAda, $k, $point)
