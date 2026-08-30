<#
  Reads registered relay addresses directly from Koios and writes
  <OutDir>/relay_notes.csv - pools whose registration includes a formatting
  detail worth surfacing, alongside the value itself.

  Currently checks for one thing: an address written with a URL scheme
  (http://, https://) instead of a bare hostname or IP, as node.
  Cardano-cli, cardano-node, and the relay-discovery tooling all expect a
  bare hostname/IP/port - a scheme prefix is not part of that format.

  This is a formatting detail, not a judgment. The far more likely explanation
  is a copy-paste from a config template or a browser address bar, carried
  over without editing - not something worth reading as suspicious. It is
  recorded here as a fact about the registration, nothing more, and it does
  not affect scoring.

  Reuses the same pool_relays fetch as fetch-foreign-infra.ps1 (Koios,
  public, no key, ~7 requests for the whole chain), so run that one first if
  both are needed in the same session - or just accept the modest duplicate
  fetch, it is cheap either way.
#>
param([string]$OutDir = 'data')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$outFile = Join-Path $OutDir 'relay_notes.csv'
New-Item -ItemType Directory -Force $OutDir | Out-Null

# data/ is not checked into git (see .gitignore), so a CI run always starts
# from a clean slate here - there is no previous file to fall back on. On
# failure this just means today's build has no citations from this source,
# not that it reuses yesterday's. The core ranking is unaffected either way.
function Skip-ThisRun($reason) {
  Write-Output "::warning::$reason - publishing today's page without this optional citation"
  Set-Content -Path $outFile -Value 'pool_bech32,note_code,value' -Encoding UTF8
  exit 0
}

# Purely informational (never affects scoring), so a Koios hiccup here must
# not fail the whole daily rebuild the way a scoring-relevant check would.
$pools = @()
try {
  for ($offset = 0; $offset -lt 50000; $offset += 1000) {
    $uri = "https://api.koios.rest/api/v1/pool_relays?select=pool_id_bech32,relays&limit=1000&offset=$offset"
    $page = Invoke-RestMethod -Uri $uri -TimeoutSec 90
    if (-not $page) { break }
    $pools += $page
    if ($page.Count -lt 1000) { break }
  }
} catch {
  Skip-ThisRun "pool_relays fetch failed: $($_.Exception.Message)"
}

if ($pools.Count -lt 1000) { Skip-ThisRun "pool_relays returned only $($pools.Count) pools" }

$rows = foreach ($p in $pools) {
  foreach ($r in $p.relays) {
    $v = if ($r.dns) { $r.dns } elseif ($r.srv) { $r.srv } else { $null }
    if ($v -and ($v -match '^https?://')) {
      [pscustomobject]@{ pool_bech32 = $p.pool_id_bech32; note_code = 'SCHEME_PREFIX'; value = $v.Trim() }
    }
  }
}
$rows = @($rows)
if ($rows.Count -gt 0) { $rows | Export-Csv -NoTypeInformation -Encoding UTF8 $outFile }
else { Set-Content -Path $outFile -Value 'pool_bech32,note_code,value' -Encoding UTF8 }

Write-Output "relay_notes: checked $($pools.Count) pools, $($rows.Count) relay addresses include a scheme prefix"
foreach ($r in $rows) { Write-Output "  $($r.pool_bech32)  $($r.value)" }
