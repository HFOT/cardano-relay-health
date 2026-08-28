<#
  Builds the Cardano Relay Health Ranking page from the three public ABCDE CSVs.

    -SrcDir    folder holding relay_pool_health.csv, relay_shared_hosts.csv,
               pool_operator_kes_members.csv   (default: this script's folder)
    -Template  presentation layer, single source for markup/CSS/i18n
    -OutFile   destination .html

  Presentation strings live in the template; this script emits data plus
  language-neutral issue codes only.
#>
param(
  [string]$SrcDir,
  [string]$Template,
  [string]$OutFile
)
$ErrorActionPreference = 'Stop'
if (-not $SrcDir)   { $SrcDir   = $PSScriptRoot }
if (-not $Template) { $Template = Join-Path $PSScriptRoot 'template.html' }
if (-not $OutFile)  { $OutFile  = Join-Path (Split-Path $PSScriptRoot -Parent) 'index.html' }
$src = Join-Path $SrcDir 'relay_pool_health.csv'
$tpl = $Template
$out = $OutFile
$rows = Import-Csv $src
$sharedHosts = Import-Csv (Join-Path $SrcDir 'relay_shared_hosts.csv')
$kesMembers = Import-Csv (Join-Path $SrcDir 'pool_operator_kes_members.csv')
$ipMap = @{}
foreach ($h in $sharedHosts) {
  foreach ($poolId in ($h.pool_bech32s -split '\s+')) {
    if (-not $poolId) { continue }
    if (-not $ipMap.ContainsKey($poolId)) { $ipMap[$poolId] = [pscustomobject]@{ ips=@(); maxPools=0 } }
    $ipMap[$poolId].ips += "$($h.resolved_ip):$($h.target_port)"
    $ipMap[$poolId].maxPools = [Math]::Max($ipMap[$poolId].maxPools,[int]$h.pools)
  }
}
$clusterSizes = @{}; foreach ($g in ($kesMembers | Group-Object cluster_id)) { $clusterSizes[$g.Name] = $g.Count }
$kesMap = @{}; foreach ($k in $kesMembers) { if ($clusterSizes[$k.cluster_id] -gt 1) { $kesMap[$k.pool_bech32] = [pscustomobject]@{ id=$k.cluster_id; size=$clusterSizes[$k.cluster_id] } } }
function N($v) { if ([string]::IsNullOrWhiteSpace($v)) { return 0.0 }; return [double]$v }
$ranked = foreach ($r in $rows) {
  $blocks = N $r.blocks_last_30_epochs
  $probed = N $r.endpoints_probed
  if ($r.minted_last_30_epochs -ne 't' -or $blocks -le 0 -or $probed -le 0) { continue }
  $reachable = N $r.reachable_hosts; $atTip = N $r.at_tip_hosts
  $reachRatio = [Math]::Min(1.0, $reachable / $probed); $tipRatio = [Math]::Min(1.0, $atTip / $probed)
  $reachScore = 17.5*$reachRatio + 17.5*$tipRatio
  $redundancy = if ($reachable -ge 3) {15} elseif ($reachable -eq 2) {11} elseif ($reachable -eq 1) {5} else {0}
  $sharedIp = $ipMap.ContainsKey($r.pool_bech32)
  $kesLinked = $kesMap.ContainsKey($r.pool_bech32)
  $endpointIndependence = if ($r.shares_endpoint_with_other_pool -eq 't') {0} else {10}
  $ipIndependence = if ($sharedIp) {0} else {10}
  $operatorIndependence = if ($kesLinked) {0} else {5}
  $independence = $endpointIndependence + $ipIndependence + $operatorIndependence
  $ownership = if ($r.registers_foreign_infrastructure -eq 't') {0} else {10}
  $continuity = if ($r.ever_removed_all_relays -eq 't') {0} else {10}
  $rtt = if ([string]::IsNullOrWhiteSpace($r.best_rtt_ms)) {$null} else {[double]$r.best_rtt_ms}
  $latency = if ($null -eq $rtt) {0} elseif ($rtt -le 150) {5} elseif ($rtt -le 300) {4} elseif ($rtt -le 600) {3} elseif ($rtt -le 1000) {2} else {1}
  # 表示文言は持たせず、言語非依存のコード + パラメータだけを出す（表示側で en/ja に展開）
  $issues = @()
  if ($r.registers_foreign_infrastructure -eq 't') { $issues += [pscustomobject]@{ code='FOREIGN' } }
  if ($atTip -eq 0) { $issues += [pscustomobject]@{ code='TIP_ZERO' } }
  elseif ($atTip -lt $reachable) { $issues += [pscustomobject]@{ code='TIP_PARTIAL' } }
  if ($reachable -lt $probed) { $issues += [pscustomobject]@{ code='REACH_PARTIAL'; a=[int]$reachable; b=[int]$probed } }
  if ($reachable -eq 1) { $issues += [pscustomobject]@{ code='SINGLE_HOST' } }
  if ($r.shares_endpoint_with_other_pool -eq 't') { $issues += [pscustomobject]@{ code='EP_SHARED' } }
  if ($sharedIp) { $issues += [pscustomobject]@{ code='IP_SHARED'; a=$ipMap[$r.pool_bech32].maxPools } }
  if ($kesLinked) { $issues += [pscustomobject]@{ code='KES_CLUSTER'; a=$kesMap[$r.pool_bech32].id; b=$kesMap[$r.pool_bech32].size } }
  if ($r.ever_removed_all_relays -eq 't') { $issues += [pscustomobject]@{ code='REMOVED_ALL' } }
  if ($null -ne $rtt -and $rtt -gt 1000) { $issues += [pscustomobject]@{ code='RTT_HIGH'; a=[Math]::Round($rtt,1) } }
  $severity = if (($r.registers_foreign_infrastructure -eq 't') -or $atTip -eq 0 -or ($sharedIp -and $ipMap[$r.pool_bech32].maxPools -ge 10)) {'high'} elseif ($issues.Count -ge 2 -or $kesLinked -or $sharedIp) {'mid'} elseif ($issues.Count -eq 1) {'low'} else {'none'}
  [pscustomobject]@{ ticker=$r.ticker; pool=$r.pool_bech32; score=[Math]::Round($reachScore+$redundancy+$independence+$ownership+$continuity+$latency,2); stake=[double]$r.stake_ada; delegators=[int]$r.delegators; blocks=[int]$blocks; entries=[int]$r.relay_entries; probed=[int]$probed; reachable=[int]$reachable; atTip=[int]$atTip; rtt=$rtt; shared=($r.shares_endpoint_with_other_pool -eq 't'); sharedIp=$sharedIp; sharedIpPools=$(if($sharedIp){$ipMap[$r.pool_bech32].maxPools}else{0}); kesLinked=$kesLinked; kesCluster=$(if($kesLinked){$kesMap[$r.pool_bech32].id}else{$null}); kesClusterSize=$(if($kesLinked){$kesMap[$r.pool_bech32].size}else{0}); foreign=($r.registers_foreign_infrastructure -eq 't'); removedAll=($r.ever_removed_all_relays -eq 't'); issues=$issues; severity=$severity; checked=$r.last_checked; parts=[pscustomobject]@{reach=[Math]::Round($reachScore,2); redundancy=$redundancy; independence=$independence; ownership=$ownership; continuity=$continuity; latency=$latency} }
}
$ranked = @($ranked | Sort-Object @{e='score';Descending=$true}, @{e='reachable';Descending=$true}, @{e='rtt';Ascending=$true}, @{e='stake';Descending=$true})
for ($i=0; $i -lt $ranked.Count; $i++) { $ranked[$i] | Add-Member rank ($i+1) }
$json = $ranked | ConvertTo-Json -Depth 6 -Compress
$checked = ($ranked | Where-Object checked | Select-Object -First 1).checked

# 表示部は work\template.html が単一ソース。__DATA__ と __CHECKED__ だけ差し込む。
$html = [IO.File]::ReadAllText($tpl, [Text.UTF8Encoding]::new($false))
$html = $html.Replace('__DATA__',$json).Replace('__CHECKED__',$checked)
# -OutFile may be a bare filename, in which case Split-Path yields ''.
$out = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $out))
$outDir = Split-Path $out -Parent
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force $outDir | Out-Null }
[IO.File]::WriteAllText($out,$html,[Text.UTF8Encoding]::new($false))
Write-Output "Created $out with $($ranked.Count) ranked pools"
