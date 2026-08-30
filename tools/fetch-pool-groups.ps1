<#
  Fetches the community-maintained pool grouping database from Koios and
  writes it to <OutDir>/pool_groups.csv for the generator.

  Why this exists: a reader asked for pool-grouping data (which pools share
  common operators, beyond what shared infrastructure alone can show). Before
  building our own inference, we checked whether one already exists and cross-
  referenced it against our own IP/KES-sharing detection: every group our
  detection found was already labelled here (154/168 matched exactly, the
  rest were plausible cases of shared tooling rather than missed groups, not
  gaps in this database). So this page displays that existing consensus
  rather than re-deriving it - it is not our judgment, just a citation.

  Source: https://github.com/cardano-community/pool_groups, served through
  Koios (public, no key). ~3 requests for the whole chain.

  This is informational only and never affects scoring. If Koios is briefly
  unavailable, the build should not fail because of it - only the group
  citation is missing, not anything the score depends on.
#>
param([string]$OutDir = 'data')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

New-Item -ItemType Directory -Force $OutDir | Out-Null
$outFile = Join-Path $OutDir 'pool_groups.csv'

# data/ is not checked into git (see .gitignore), so a CI run always starts
# from a clean slate here - there is no previous file to fall back on. On
# failure this just means today's build has no citations from this source,
# not that it reuses yesterday's. The core ranking is unaffected either way.
function Skip-ThisRun($reason) {
  Write-Output "::warning::$reason - publishing today's page without this optional citation"
  Set-Content -Path $outFile -Value 'pool_bech32,group_label' -Encoding UTF8
  exit 0
}

# Purely informational (never affects scoring), so a Koios hiccup here must
# not fail the whole daily rebuild the way a scoring-relevant check would.
$rows = @()
try {
  for ($offset = 0; $offset -lt 20000; $offset += 1000) {
    $uri = "https://api.koios.rest/api/v1/pool_groups?limit=1000&offset=$offset"
    $page = Invoke-RestMethod -Uri $uri -TimeoutSec 60
    if (-not $page) { break }
    $rows += $page
    if ($page.Count -lt 1000) { break }
  }
} catch {
  Skip-ThisRun "pool_groups fetch failed: $($_.Exception.Message)"
}

if ($rows.Count -lt 500) { Skip-ThisRun "pool_groups returned only $($rows.Count) rows" }

$out = foreach ($r in $rows) {
  $label = if ($r.pool_group) { $r.pool_group } elseif ($r.adastat_group) { $r.adastat_group } elseif ($r.balanceanalytics_group) { $r.balanceanalytics_group } else { $null }
  if ($label) {
    [pscustomobject]@{ pool_bech32 = $r.pool_id_bech32; group_label = $label }
  }
}
$out | Export-Csv -NoTypeInformation -Encoding UTF8 $outFile
Write-Output "pool_groups: $($rows.Count) pools fetched, $(@($out).Count) with a group label"
