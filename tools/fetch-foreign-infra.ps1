<#
  Detects pools that register a founding-entity public bootstrap relay as their
  own, and writes them to <OutDir>/foreign_infra.csv for the generator.

  Why this exists: the upstream ABCDE dataset briefly carried a
  registers_foreign_infrastructure column, then dropped it again, which left the
  "no borrowing" axis awarding full marks to every pool including the one it was
  meant to catch. Registered relays are on chain, so this can be checked
  directly instead of waiting for the column to come back.

  Koios is public and needs no key. Roughly 7 requests for the whole chain.

  Only the shared bootstrap hostnames count. A founding entity running its own
  pool on its own dedicated relays (iog1-relays..., cfNrN.mainnet.pool...) is
  not borrowing anything, and must not be flagged.
#>
param([string]$OutDir = 'data')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$backbone = @(
  'backbone.cardano.iog.io'
  'backbone.mainnet.emurgornd.com'
  'backbone.mainnet.cardanofoundation.org'
  'relays-new.cardano-mainnet.iohk.io'
)

$pools = @()
for ($offset = 0; $offset -lt 50000; $offset += 1000) {
  $uri = "https://api.koios.rest/api/v1/pool_relays?select=pool_id_bech32,relays&limit=1000&offset=$offset"
  $page = Invoke-RestMethod -Uri $uri -TimeoutSec 90
  if (-not $page) { break }
  $pools += $page
  if ($page.Count -lt 1000) { break }
}
if ($pools.Count -lt 1000) { throw "pool_relays returned only $($pools.Count) pools - refusing to write a suspiciously short list" }

$hits = foreach ($p in $pools) {
  $names = @($p.relays | ForEach-Object { if ($_.dns) { $_.dns } elseif ($_.srv) { $_.srv } } | Where-Object { $_ })
  $borrowed = @($names | Where-Object { $backbone -contains $_.ToLower().TrimEnd('.') })
  if ($borrowed.Count -gt 0) {
    [pscustomobject]@{
      pool_bech32   = $p.pool_id_bech32
      relays_total  = @($p.relays).Count
      relays_shared = $borrowed.Count
    }
  }
}
$hits = @($hits)

New-Item -ItemType Directory -Force $OutDir | Out-Null
$outFile = Join-Path $OutDir 'foreign_infra.csv'
if ($hits.Count -gt 0) { $hits | Export-Csv -NoTypeInformation -Encoding UTF8 $outFile }
else { Set-Content -Path $outFile -Value 'pool_bech32,relays_total,relays_shared' -Encoding UTF8 }

Write-Output "Checked $($pools.Count) pools; $($hits.Count) register a shared bootstrap relay."
foreach ($h in $hits) { Write-Output "  $($h.pool_bech32)  $($h.relays_shared)/$($h.relays_total) relays" }
