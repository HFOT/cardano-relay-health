<#
  Fails the build when the upstream ABCDE CSVs no longer carry the columns the
  generator reads.

  Why this exists: PowerShell's Import-Csv returns $null for a column that is not
  there, and the generator's N() turns $null into 0. A renamed or dropped column
  therefore does not crash anything — it silently shifts every pool's score while
  the page still looks completely normal and passes any file-size check.

  Required : absence corrupts the ranking -> hard fail, publish nothing.
  Optional : absence only disables one signal -> warn loudly and keep going,
             because upstream has already added and removed such a column once.
#>
param([string]$SrcDir = 'data')
$ErrorActionPreference = 'Stop'

$required = [ordered]@{
  'relay_pool_health.csv' = @(
    'pool_bech32','ticker','stake_ada','delegators','blocks_last_30_epochs',
    'minted_last_30_epochs','relay_entries','ever_removed_all_relays',
    'endpoints_probed','reachable_hosts','at_tip_hosts','best_rtt_ms',
    'shares_endpoint_with_other_pool','last_checked'
  )
  'relay_shared_hosts.csv' = @('resolved_ip','target_port','pools','pool_bech32s')
  'pool_operator_kes_members.csv' = @('cluster_id','pool_bech32')
}
# registers_foreign_infrastructure: present 2026-08-27 23:01 UTC, gone again by
# the 03:38 sweep the next morning.
# relay_additions / removed_all_relays_on: only add detail to the "cannot be
# measured" section. Without them that section still lists the same pools, it
# just stops saying whether a pool ever had relays registered before.
$optional = [ordered]@{
  'relay_pool_health.csv' = @('registers_foreign_infrastructure','relay_additions','removed_all_relays_on')
}

$missingRequired = @()
$missingOptional = @()

foreach ($file in $required.Keys) {
  $path = Join-Path $SrcDir $file
  if (-not (Test-Path $path)) { throw "SCHEMA: $file not found in $SrcDir" }

  $header = (Get-Content $path -TotalCount 1) -split ',' | ForEach-Object { $_.Trim().Trim('"') }
  Write-Output "$file  ($($header.Count) columns)"

  foreach ($col in $required[$file]) {
    if ($header -notcontains $col) { $missingRequired += "$file :: $col" }
  }
  if ($optional.Contains($file)) {
    foreach ($col in $optional[$file]) {
      if ($header -notcontains $col) { $missingOptional += "$file :: $col" }
    }
  }
}

foreach ($m in $missingOptional) {
  Write-Output "::warning::Optional column absent upstream, its signal is inert this run -> $m"
}

if ($missingRequired.Count -gt 0) {
  foreach ($m in $missingRequired) { Write-Output "::error::Required column missing -> $m" }
  throw "SCHEMA: $($missingRequired.Count) required column(s) missing. Refusing to publish a silently wrong ranking."
}

Write-Output "Schema OK ($($missingOptional.Count) optional column(s) absent)."
