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
  $ipKey = "$($h.resolved_ip):$($h.target_port)"
  $ipPools = [int]$h.pools
  foreach ($poolId in ($h.pool_bech32s -split '\s+')) {
    if (-not $poolId) { continue }
    if (-not $ipMap.ContainsKey($poolId)) { $ipMap[$poolId] = [pscustomobject]@{ ips=@(); maxPools=0; key=$null } }
    $ipMap[$poolId].ips += $ipKey
    # 表示する x N と、クリックで開くグループを一致させるため、最大グループのキーを覚えておく
    if ($ipPools -gt $ipMap[$poolId].maxPools) {
      $ipMap[$poolId].maxPools = $ipPools
      $ipMap[$poolId].key = $ipKey
    }
  }
}
$clusterSizes = @{}; foreach ($g in ($kesMembers | Group-Object cluster_id)) { $clusterSizes[$g.Name] = $g.Count }
$kesMap = @{}; foreach ($k in $kesMembers) { if ($clusterSizes[$k.cluster_id] -gt 1) { $kesMap[$k.pool_bech32] = [pscustomobject]@{ id=$k.cluster_id; size=$clusterSizes[$k.cluster_id] } } }

# 創業団体の共有bootstrapを自プールのrelayとして登録しているプール。
# 上流の registers_foreign_infrastructure 列は出たり消えたりするので、
# tools/fetch-foreign-infra.ps1 がチェーンから直接調べた結果も併用する。
$foreignSet = @{}
$foreignPath = Join-Path $SrcDir 'foreign_infra.csv'
if (Test-Path $foreignPath) {
  foreach ($f in (Import-Csv $foreignPath)) { if ($f.pool_bech32) { $foreignSet[$f.pool_bech32] = $true } }
  Write-Output "  foreign_infra.csv: $($foreignSet.Count) pools"
} else {
  Write-Output "::warning::foreign_infra.csv not found - the no-borrowing axis relies on upstream only"
}

function N($v) { if ([string]::IsNullOrWhiteSpace($v)) { return 0.0 }; return [double]$v }

# コミュニティが運営する pool_groups DB のラベル。表示のみ・採点には使わない。
# 我々のIP/KES検出は既にこのDBが把握している構造の後追いに過ぎないことを確認済み
# なので、独自の名寄せロジックは作らずここを引用する。
# ただし「SINGLEPOOL」（独立運営の明示ラベル）や、ランキング内に同じラベルの
# 相手がいない場合は、引用しても比較のしようがなく情報量がないので表示しない。
$willRank = @{}
foreach ($r in $rows) {
  if ($r.minted_last_30_epochs -eq 't' -and (N $r.blocks_last_30_epochs) -gt 0 -and (N $r.endpoints_probed) -gt 0) { $willRank[$r.pool_bech32] = $true }
}
$groupLabelMap = @{}
$rawLabels = @{}
$groupsPath = Join-Path $SrcDir 'pool_groups.csv'
if (Test-Path $groupsPath) {
  foreach ($g in (Import-Csv $groupsPath)) { if ($g.pool_bech32 -and $g.group_label) { $rawLabels[$g.pool_bech32] = $g.group_label } }
  $labelCounts = @{}
  foreach ($kv in $rawLabels.GetEnumerator()) {
    if ($kv.Value -eq 'SINGLEPOOL') { continue }
    if (-not $willRank.ContainsKey($kv.Key)) { continue }
    $labelCounts[$kv.Value] = ($labelCounts[$kv.Value] + 1)
  }
  foreach ($kv in $rawLabels.GetEnumerator()) {
    if (-not $willRank.ContainsKey($kv.Key)) { continue }
    if ($labelCounts.ContainsKey($kv.Value) -and $labelCounts[$kv.Value] -ge 2) { $groupLabelMap[$kv.Key] = $kv.Value }
  }
  Write-Output "  pool_groups.csv: $($rawLabels.Count) pools labelled, $($groupLabelMap.Count) shown (2+ ranked pools sharing a non-SINGLEPOOL label)"
}

# 登録リレーの表記に関する注記（例: httpスキーム付き）。判定ではなく事実の記録で、採点には使わない。
$relayNoteMap = @{}
$notesPath = Join-Path $SrcDir 'relay_notes.csv'
if (Test-Path $notesPath) {
  foreach ($n in (Import-Csv $notesPath)) {
    if (-not $n.pool_bech32) { continue }
    if (-not $relayNoteMap.ContainsKey($n.pool_bech32)) { $relayNoteMap[$n.pool_bech32] = @() }
    $relayNoteMap[$n.pool_bech32] += [pscustomobject]@{ code = $n.note_code; value = $n.value }
  }
  Write-Output "  relay_notes.csv: $($relayNoteMap.Count) pools noted"
}

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
  $isForeign = ($r.registers_foreign_infrastructure -eq 't') -or $foreignSet.ContainsKey($r.pool_bech32)
  $ownership = if ($isForeign) {0} else {10}
  $continuity = if ($r.ever_removed_all_relays -eq 't') {0} else {10}
  $rtt = if ([string]::IsNullOrWhiteSpace($r.best_rtt_ms)) {$null} else {[double]$r.best_rtt_ms}
  $latency = if ($null -eq $rtt) {0} elseif ($rtt -le 150) {5} elseif ($rtt -le 300) {4} elseif ($rtt -le 600) {3} elseif ($rtt -le 1000) {2} else {1}
  # 表示文言は持たせず、言語非依存のコード + パラメータだけを出す（表示側で en/ja に展開）
  $issues = @()
  if ($isForeign) { $issues += [pscustomobject]@{ code='FOREIGN' } }
  if ($atTip -eq 0) { $issues += [pscustomobject]@{ code='TIP_ZERO' } }
  elseif ($atTip -lt $reachable) { $issues += [pscustomobject]@{ code='TIP_PARTIAL' } }
  if ($reachable -lt $probed) { $issues += [pscustomobject]@{ code='REACH_PARTIAL'; a=[int]$reachable; b=[int]$probed } }
  if ($reachable -eq 1) { $issues += [pscustomobject]@{ code='SINGLE_HOST' } }
  if ($r.shares_endpoint_with_other_pool -eq 't') { $issues += [pscustomobject]@{ code='EP_SHARED' } }
  if ($sharedIp) { $issues += [pscustomobject]@{ code='IP_SHARED'; a=$ipMap[$r.pool_bech32].maxPools } }
  if ($kesLinked) { $issues += [pscustomobject]@{ code='KES_CLUSTER'; a=$kesMap[$r.pool_bech32].id; b=$kesMap[$r.pool_bech32].size } }
  if ($r.ever_removed_all_relays -eq 't') { $issues += [pscustomobject]@{ code='REMOVED_ALL' } }
  if ($null -ne $rtt -and $rtt -gt 1000) { $issues += [pscustomobject]@{ code='RTT_HIGH'; a=[Math]::Round($rtt,1) } }
  $severity = if ($isForeign -or $atTip -eq 0 -or ($sharedIp -and $ipMap[$r.pool_bech32].maxPools -ge 10)) {'high'} elseif ($issues.Count -ge 2 -or $kesLinked -or $sharedIp) {'mid'} elseif ($issues.Count -eq 1) {'low'} else {'none'}
  [pscustomobject]@{ ticker=$r.ticker; pool=$r.pool_bech32; score=[Math]::Round($reachScore+$redundancy+$independence+$ownership+$continuity+$latency,2); stake=[double]$r.stake_ada; delegators=[int]$r.delegators; blocks=[int]$blocks; entries=[int]$r.relay_entries; probed=[int]$probed; reachable=[int]$reachable; atTip=[int]$atTip; rtt=$rtt; shared=($r.shares_endpoint_with_other_pool -eq 't'); sharedIp=$sharedIp; sharedIpPools=$(if($sharedIp){$ipMap[$r.pool_bech32].maxPools}else{0}); ipKey=$(if($sharedIp){$ipMap[$r.pool_bech32].key}else{$null}); kesLinked=$kesLinked; kesCluster=$(if($kesLinked){$kesMap[$r.pool_bech32].id}else{$null}); kesClusterSize=$(if($kesLinked){$kesMap[$r.pool_bech32].size}else{0}); foreign=$isForeign; removedAll=($r.ever_removed_all_relays -eq 't'); issues=$issues; severity=$severity; checked=$r.last_checked; groupLabel=$(if($groupLabelMap.ContainsKey($r.pool_bech32)){$groupLabelMap[$r.pool_bech32]}else{$null}); relayNotes=$(if($relayNoteMap.ContainsKey($r.pool_bech32)){$relayNoteMap[$r.pool_bech32]}else{@()}); parts=[pscustomobject]@{reach=[Math]::Round($reachScore,2); redundancy=$redundancy; independence=$independence; ownership=$ownership; continuity=$continuity; latency=$latency} }
}
$ranked = @($ranked | Sort-Object @{e='score';Descending=$true}, @{e='reachable';Descending=$true}, @{e='rtt';Ascending=$true}, @{e='stake';Descending=$true})
for ($i=0; $i -lt $ranked.Count; $i++) { $ranked[$i] | Add-Member rank ($i+1) }
$json = $ranked | ConvertTo-Json -Depth 6 -Compress

# --- このページでは測定できないプール ---------------------------------------
# ブロックは作っているのに endpoints_probed が 0 のプール。ほぼすべては
# チェーン上にリレーが1件も登録されていない状態で、プローブする宛先が存在
# しないため6軸のどれも測れない。測れないことと問題があることは別なので、
# 採点も順位付けもせず、測れないという事実だけを別枠に出す。
# 登録しない理由（DoS露出を抑える、プライバシー、第三者のリレーサービス、
# 設定上の理由）はチェーンの外側からは区別できない。表示側の文章もその前提で書く。
$unmeasured = foreach ($r in $rows) {
  if ($r.minted_last_30_epochs -ne 't' -or (N $r.blocks_last_30_epochs) -le 0) { continue }
  if ((N $r.endpoints_probed) -gt 0) { continue }
  $entries = [int](N $r.relay_entries)
  # 登録はあるのにプローブされていない場合は理由が違うので、コードを分けて表示側に委ねる
  $reason = if ($entries -eq 0) { 'NO_RELAY' } else { 'NOT_PROBED' }
  $removedOn = if ([string]::IsNullOrWhiteSpace($r.removed_all_relays_on)) { $null } else { ($r.removed_all_relays_on -split ' ')[0] }
  [pscustomobject]@{
    ticker = $r.ticker; pool = $r.pool_bech32; reason = $reason; entries = $entries
    stake = [double]$r.stake_ada; delegators = [int]$r.delegators; blocks = [int](N $r.blocks_last_30_epochs)
    # 「一度も登録していない」と「登録していたが今はない」は観測できる違い。優劣ではなく履歴の差として出す。
    removedOn = $removedOn
    everRegistered = ($null -ne $removedOn) -or ((N $r.relay_additions) -gt 0)
    groupLabel = $null
  }
}
$unmeasured = @($unmeasured | Sort-Object @{e='stake';Descending=$true})

# pool_groups の引用はランキング側と同じ条件で行う。この枠のなかに同じラベルの
# 相手が2件以上いるときだけ出す。1件だけ出しても比較のしようがなく情報量がない。
$umLabelCounts = @{}
foreach ($u in $unmeasured) {
  $lab = $rawLabels[$u.pool]
  if (-not $lab -or $lab -eq 'SINGLEPOOL') { continue }
  $umLabelCounts[$lab] = ($umLabelCounts[$lab] + 1)
}
foreach ($u in $unmeasured) {
  $lab = $rawLabels[$u.pool]
  if ($lab -and $umLabelCounts.ContainsKey($lab) -and $umLabelCounts[$lab] -ge 2) { $u.groupLabel = $lab }
}
$unmeasuredJson = ConvertTo-Json -InputObject $unmeasured -Depth 4 -Compress
if (-not $unmeasuredJson) { $unmeasuredJson = '[]' }
if ($unmeasuredJson -notmatch '^\[') { $unmeasuredJson = "[$unmeasuredJson]" }
Write-Output "  unmeasured: $($unmeasured.Count) pools minted blocks but could not be probed"

# --- グループ実体 ---------------------------------------------------------
# プールの pill は「x N」と元データ上の全メンバー数を出す。押したときに N 件
# そのまま並ぶよう、ランキング対象外のプールも含めた実メンバーを持たせる。
$tickerMap = @{}
foreach ($r in $rows) { $tickerMap[$r.pool_bech32] = $r.ticker }
$rankedSet = @{}
foreach ($x in $ranked) { $rankedSet[$x.pool] = $true }

function Build-Group($members) {
  $members = @($members | Where-Object { $_ } | Select-Object -Unique)
  if ($members.Count -lt 2) { return $null }
  # ランキングに1件も出てこないグループは、どこからも開けないので載せない
  if (-not ($members | Where-Object { $rankedSet.ContainsKey($_) })) { return $null }
  return @($members | ForEach-Object {
    [pscustomobject]@{ p = $_; t = $(if ($tickerMap.ContainsKey($_)) { $tickerMap[$_] } else { $null }) }
  })
}

$ipGroups = @{}
foreach ($h in $sharedHosts) {
  $g = Build-Group ($h.pool_bech32s -split '\s+')
  if ($g) { $ipGroups["$($h.resolved_ip):$($h.target_port)"] = $g }
}
$kesGroups = @{}
foreach ($grp in ($kesMembers | Group-Object cluster_id)) {
  $g = Build-Group ($grp.Group | ForEach-Object { $_.pool_bech32 })
  if ($g) { $kesGroups[$grp.Name] = $g }
}
$groupsJson = ([pscustomobject]@{ kes = $kesGroups; ip = $ipGroups } | ConvertTo-Json -Depth 6 -Compress)
Write-Output "  groups: kes=$($kesGroups.Count) ip=$($ipGroups.Count)"
$checked = ($ranked | Where-Object checked | Select-Object -First 1).checked

# 表示部は work\template.html が単一ソース。__DATA__ と __CHECKED__ だけ差し込む。
$html = [IO.File]::ReadAllText($tpl, [Text.UTF8Encoding]::new($false))
$html = $html.Replace('__DATA__',$json).Replace('__GROUPS__',$groupsJson).Replace('__UNMEASURED__',$unmeasuredJson).Replace('__CHECKED__',$checked)
# -OutFile may be a bare filename, in which case Split-Path yields ''.
$out = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $out))
$outDir = Split-Path $out -Parent
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force $outDir | Out-Null }
[IO.File]::WriteAllText($out,$html,[Text.UTF8Encoding]::new($false))
Write-Output "Created $out with $($ranked.Count) ranked pools"
