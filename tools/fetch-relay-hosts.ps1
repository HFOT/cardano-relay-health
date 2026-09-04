<#
  Writes <OutDir>/relay_hosts.csv: for every pool in relay_pool_health.csv, how
  many distinct hosts its registered relays stand on, and which other pools
  registered one of the same endpoint strings.

  Two things are read off the chain here, both about the same registrations.

  1. Hosts, not entries.
     The upstream probe counts in two units: endpoints_probed counts the entries
     written into the registration certificate, while reachable_hosts and
     at_tip_hosts count the machines that answered. One name can expand to
     several machines, which the page already said - but the mismatch runs the
     other way too. An operator who registers one machine twice, on two ports,
     has two entries and one host, so the numerator can never reach the
     denominator however well that machine runs. The generator uses the host
     count only to lower a denominator that was counting entries, never to
     raise one.

  2. Who the sharing is with.
     Upstream reports endpoint sharing as a yes or no, without saying who the
     other pool is. Anyone can write any address into their own certificate,
     including an address belonging to somebody else, and the pool named that
     way has no way to remove it. Reporting who is on the other side is what
     lets the generator leave a pool alone when nobody in the ranking is there.

  Pools whose relays are registered by SRV record are left out of the file
  entirely - expanding SRV is what the upstream probe does, and guessing at it
  here would be worse than saying nothing. Anything absent falls back to the
  behaviour that was in place before this file existed.

  Seven requests to Koios plus one DNS lookup per name, no key needed. Scoring
  depends on it, so a bad fetch fails rather than writing a short file.
#>
param([string]$OutDir = 'data', [int]$Parallel = 64, [int]$DnsTimeoutMs = 5000)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$healthPath = Join-Path $OutDir 'relay_pool_health.csv'
if (-not (Test-Path $healthPath)) { throw "relay_pool_health.csv not found in $OutDir" }
$ids = @(Import-Csv $healthPath | ForEach-Object { $_.pool_bech32 } | Where-Object { $_ })
if ($ids.Count -lt 500) { throw "only $($ids.Count) pools in relay_pool_health.csv - refusing to run on a short list" }
$wanted = @{}; foreach ($id in $ids) { $wanted[$id] = $true }

# --- every pool's registered relays, in one paged read ----------------------
# The whole chain, not just the ranked pools: a pool that shares an endpoint may
# be one we never rank, and that is exactly the case worth being able to see.
$all = @()
for ($offset = 0; $offset -lt 20000; $offset += 1000) {
  $page = Invoke-RestMethod -Uri "https://api.koios.rest/api/v1/pool_relays?limit=1000&offset=$offset" -TimeoutSec 120
  if (-not $page) { break }
  $all += $page
  if ($page.Count -lt 1000) { break }
}
if ($all.Count -lt 3000) { throw "pool_relays returned only $($all.Count) pools - refusing to write a partial file" }

# --- who else registered the same endpoint string ---------------------------
$byEndpoint = @{}
foreach ($p in $all) {
  foreach ($r in $p.relays) {
    $name = if ($r.dns) { $r.dns } elseif ($r.ipv4) { $r.ipv4 } elseif ($r.ipv6) { $r.ipv6 } else { $null }
    if (-not $name) { continue }
    $key = "$($name.ToLower()):$($r.port)"
    if (-not $byEndpoint.ContainsKey($key)) { $byEndpoint[$key] = New-Object 'System.Collections.Generic.HashSet[string]' }
    [void]$byEndpoint[$key].Add($p.pool_id_bech32)
  }
}
$partners = @{}
foreach ($kv in $byEndpoint.GetEnumerator()) {
  if ($kv.Value.Count -lt 2) { continue }
  foreach ($a in $kv.Value) {
    if (-not $wanted.ContainsKey($a)) { continue }
    if (-not $partners.ContainsKey($a)) { $partners[$a] = New-Object 'System.Collections.Generic.HashSet[string]' }
    foreach ($b in $kv.Value) { if ($b -ne $a) { [void]$partners[$a].Add($b) } }
  }
}

# --- resolve every registered name once -------------------------------------
$relays = @{}
foreach ($p in $all) { if ($wanted.ContainsKey($p.pool_id_bech32)) { $relays[$p.pool_id_bech32] = $p.relays } }
$nameSet = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($rs in $relays.Values) {
  foreach ($r in $rs) { if ($r.dns -and -not $r.srv) { [void]$nameSet.Add([string]$r.dns) } }
}
$names = @($nameSet)
$resolved = @{}
for ($i = 0; $i -lt $names.Count; $i += $Parallel) {
  $slice = $names[$i..([Math]::Min($i + $Parallel - 1, $names.Count - 1))]
  $tasks = @{}
  foreach ($n in $slice) {
    try { $tasks[$n] = [System.Net.Dns]::GetHostAddressesAsync($n) } catch { $resolved[$n] = @() }
  }
  foreach ($n in @($tasks.Keys)) {
    $t = $tasks[$n]
    try {
      if ($t.Wait($DnsTimeoutMs)) { $resolved[$n] = @($t.Result | ForEach-Object { $_.ToString() }) }
      else { $resolved[$n] = @() }
    } catch { $resolved[$n] = @() }
  }
}
$unresolved = @($resolved.Values | Where-Object { $_.Count -eq 0 }).Count
if ($names.Count -gt 0 -and $unresolved -gt ($names.Count * 0.5)) {
  throw "$unresolved of $($names.Count) names failed to resolve - this looks like a DNS problem here, not a network-wide one"
}

# --- one row per pool -------------------------------------------------------
$rows = foreach ($id in $ids) {
  if (-not $relays.ContainsKey($id)) { continue }
  $rs = @($relays[$id])
  if ($rs.Count -eq 0) { continue }
  if (@($rs | Where-Object { $_.srv }).Count -gt 0) { continue }   # SRV: say nothing
  # One machine answering on both IPv4 and IPv6 is one machine, so a name with
  # an A record is counted by that and its AAAA is left alone; a name with only
  # a AAAA is counted by that. Otherwise a dual-stack host would count twice and
  # undo the very thing this file is for.
  $addrs = New-Object 'System.Collections.Generic.HashSet[string]'
  $missing = $false
  foreach ($r in $rs) {
    if ($r.ipv4) { [void]$addrs.Add([string]$r.ipv4) }
    elseif ($r.ipv6) { [void]$addrs.Add([string]$r.ipv6) }
    elseif ($r.dns) {
      $a = @($resolved[[string]$r.dns])
      if ($a.Count -eq 0) { $missing = $true; continue }
      $v4 = @($a | Where-Object { $_ -notlike '*:*' })
      foreach ($x in $(if ($v4.Count -gt 0) { $v4 } else { $a })) { [void]$addrs.Add($x) }
    }
  }
  # A name that would not resolve from here may still have answered the probe,
  # so a partial count would understate the pool. Leave it out and fall back.
  if ($missing -or $addrs.Count -eq 0) { continue }
  [pscustomobject]@{
    pool_bech32       = $id
    entries           = $rs.Count
    hosts             = $addrs.Count
    endpoint_partners = if ($partners.ContainsKey($id)) { (@($partners[$id]) -join ' ') } else { '' }
  }
}
$rows = @($rows)
if ($rows.Count -lt ($ids.Count * 0.5)) {
  throw "only $($rows.Count) of $($ids.Count) pools could be counted - refusing to write a partial file"
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$rows | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $OutDir 'relay_hosts.csv')

$capped = @($rows | Where-Object { $_.hosts -lt $_.entries }).Count
$shared = @($rows | Where-Object { $_.endpoint_partners }).Count
Write-Output ("Counted hosts for {0} of {1} pools; {2} register more entries than they have distinct hosts; {3} share an endpoint string with another pool" -f $rows.Count, $ids.Count, $capped, $shared)
