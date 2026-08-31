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
  $labelSource = @{}
  foreach ($g in (Import-Csv $groupsPath)) {
    if ($g.pool_bech32 -and $g.group_label) {
      $rawLabels[$g.pool_bech32] = $g.group_label
      if ($g.PSObject.Properties.Name -contains 'source') { $labelSource[$g.pool_bech32] = $g.source }
    }
  }
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
# エポック単位のステーク推移（3か月分）。スパークライン表示のみで採点には使わない。
# ステークはエポック境界でしか動かないので、単位は日ではなくエポック。
$histMap = @{}
$histPath = Join-Path $SrcDir 'pool_history.csv'
if (Test-Path $histPath) {
  foreach ($hh in (Import-Csv $histPath)) {
    if ($hh.pool_bech32 -and $hh.series) {
      $histMap[$hh.pool_bech32] = @($hh.series -split ',' | ForEach-Object { [double]$_ })
    }
  }
  Write-Output "  pool_history.csv: $($histMap.Count) pools"
}

# 運営者が登録している手数料。委任者の取り分に直結するが、料率の高低は
# 事業上の選択であって欠陥ではない。表示のみで採点には使わない。
$feeMap = @{}
$feesPath = Join-Path $SrcDir 'pool_fees.csv'
if (Test-Path $feesPath) {
  foreach ($f in (Import-Csv $feesPath)) {
    if ($f.pool_bech32) { $feeMap[$f.pool_bech32] = [pscustomobject]@{ m=[double]$f.margin; f=[int]$f.fixed_ada } }
  }
  Write-Output "  pool_fees.csv: $($feeMap.Count) pools"
}

# 飽和点。表示のみで採点には使わない。無ければ飽和の目盛りが出ないだけ。
$satPoint = 0
$paramsPath = Join-Path $SrcDir 'network_params.csv'
if (Test-Path $paramsPath) {
  $np = @(Import-Csv $paramsPath)
  if ($np.Count -gt 0) { $satPoint = [double]$np[0].saturation_ada }
  Write-Output ("  network_params.csv: saturation {0:N0} ADA (k={1})" -f $satPoint, $np[0].optimal_pools)
}

$notesPath = Join-Path $SrcDir 'relay_notes.csv'
if (Test-Path $notesPath) {
  foreach ($n in (Import-Csv $notesPath)) {
    if (-not $n.pool_bech32) { continue }
    if (-not $relayNoteMap.ContainsKey($n.pool_bech32)) { $relayNoteMap[$n.pool_bech32] = @() }
    $relayNoteMap[$n.pool_bech32] += [pscustomobject]@{ code = $n.note_code; value = $n.value }
  }
  Write-Output "  relay_notes.csv: $($relayNoteMap.Count) pools noted"
}

# 同時に止まる規模。1つの障害点が落ちたとき、一緒に止まるブロック生成の割合。
# ドメインの候補は「名寄せラベル > KESクラスター > 共有IP」で、そのプールが属する
# もののうち最も大きいものを採る。プール数は上流の全メンバーで数える（ランキング
# 対象外のプールも運営の一部なので、規模を過小に見せないため）。
# 表示のみ。集中していること自体は運営の欠陥ではないので採点には使わない。
$blkOf = @{}
foreach ($r in $rows) {
  if ($r.minted_last_30_epochs -eq 't') { $blkOf[$r.pool_bech32] = N $r.blocks_last_30_epochs }
}
$totalBlocks = 0.0
foreach ($r in $rows) {
  if ($r.minted_last_30_epochs -eq 't' -and (N $r.blocks_last_30_epochs) -gt 0 -and (N $r.endpoints_probed) -gt 0) {
    $totalBlocks += N $r.blocks_last_30_epochs
  }
}
$domains = @{}
$domMembers = @{}
function Add-Domain($key, $members) {
  $blk = 0.0
  foreach ($m in $members) { if ($blkOf.ContainsKey($m)) { $blk += $blkOf[$m] } }
  foreach ($m in $members) {
    $cur = $domains[$m]
    # 規模が同じなら、メンバー数の多い方を採る。ブロックを生成していないプールも
    # 運営の一部なので、YUTA のように名寄せラベル25 / KESクラスター29 と割れる場合に
    # 実態に近い方（29）を残すため。サイトの x N バッジとも一致する。
    if (-not $cur -or $blk -gt $cur.blk -or ($blk -eq $cur.blk -and $members.Count -gt $cur.n)) {
      $domains[$m] = [pscustomobject]@{ key=$key; n=$members.Count; blk=$blk }
    }
  }
  if (-not $domMembers.ContainsKey($key)) { $domMembers[$key] = @($members) }
}
$byLabel = @{}
foreach ($kv in $rawLabels.GetEnumerator()) {
  if ($kv.Value -eq 'SINGLEPOOL') { continue }
  if (-not $byLabel.ContainsKey($kv.Value)) { $byLabel[$kv.Value] = New-Object System.Collections.ArrayList }
  [void]$byLabel[$kv.Value].Add($kv.Key)
}
foreach ($kv in $byLabel.GetEnumerator()) { if ($kv.Value.Count -ge 2) { Add-Domain $kv.Key @($kv.Value) } }
$byCluster = @{}
foreach ($k in $kesMembers) {
  if (-not $byCluster.ContainsKey($k.cluster_id)) { $byCluster[$k.cluster_id] = New-Object System.Collections.ArrayList }
  [void]$byCluster[$k.cluster_id].Add($k.pool_bech32)
}
foreach ($kv in $byCluster.GetEnumerator()) { if ($kv.Value.Count -ge 2) { Add-Domain "kes:$($kv.Key)" @($kv.Value) } }
$byIp = @{}
foreach ($h in $sharedHosts) {
  $key = "$($h.resolved_ip):$($h.target_port)"
  $ids = @($h.pool_bech32s -split '\s+' | Where-Object { $_ })
  if ($ids.Count -ge 2) { $byIp[$key] = $ids }
}
foreach ($kv in $byIp.GetEnumerator()) { Add-Domain $kv.Key $kv.Value }
Write-Output "  failure domains: $($domains.Count) pools sit in a shared domain"

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
  [pscustomobject]@{ ticker=$r.ticker; pool=$r.pool_bech32; score=[Math]::Round($reachScore+$redundancy+$independence+$ownership+$continuity+$latency,2); stake=[double]$r.stake_ada; sat=$(if($satPoint -gt 0){[Math]::Round([double]$r.stake_ada/$satPoint,4)}else{$null}); delegators=[int]$r.delegators; blocks=[int]$blocks; hist=$(if($histMap.ContainsKey($r.pool_bech32)){,$histMap[$r.pool_bech32]}else{$null}); margin=$(if($feeMap.ContainsKey($r.pool_bech32)){$feeMap[$r.pool_bech32].m}else{$null}); fixedAda=$(if($feeMap.ContainsKey($r.pool_bech32)){$feeMap[$r.pool_bech32].f}else{$null}); entries=[int]$r.relay_entries; probed=[int]$probed; reachable=[int]$reachable; atTip=[int]$atTip; rtt=$rtt; shared=($r.shares_endpoint_with_other_pool -eq 't'); sharedIp=$sharedIp; sharedIpPools=$(if($sharedIp){$ipMap[$r.pool_bech32].maxPools}else{0}); ipKey=$(if($sharedIp){$ipMap[$r.pool_bech32].key}else{$null}); kesLinked=$kesLinked; kesCluster=$(if($kesLinked){$kesMap[$r.pool_bech32].id}else{$null}); kesClusterSize=$(if($kesLinked){$kesMap[$r.pool_bech32].size}else{0}); foreign=$isForeign; removedAll=($r.ever_removed_all_relays -eq 't'); issues=$issues; severity=$severity; checked=$r.last_checked; groupLabel=$(if($groupLabelMap.ContainsKey($r.pool_bech32)){$groupLabelMap[$r.pool_bech32]}else{$null}); groupSrc=$(if($labelSource -and $labelSource.ContainsKey($r.pool_bech32) -and $groupLabelMap.ContainsKey($r.pool_bech32)){$labelSource[$r.pool_bech32]}else{$null}); domN=$(if($domains.ContainsKey($r.pool_bech32)){$domains[$r.pool_bech32].n}else{0}); domBlk=$(if($domains.ContainsKey($r.pool_bech32) -and $totalBlocks -gt 0){[Math]::Round($domains[$r.pool_bech32].blk/$totalBlocks*100,3)}else{$null}); relayNotes=$(if($relayNoteMap.ContainsKey($r.pool_bech32)){$relayNoteMap[$r.pool_bech32]}else{@()}); parts=[pscustomobject]@{reach=[Math]::Round($reachScore,2); redundancy=$redundancy; independence=$independence; ownership=$ownership; continuity=$continuity; latency=$latency} }
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
# 障害ドメインの一覧。プール単位ではなく「一緒に止まる単位」で並べるための表。
# ランキングに出るプールを1件以上含むものだけ載せる（開けないものは出さない）。
$impairedSet = @{}
foreach ($x in $ranked) { if ($x.reachable -eq 0 -or $x.atTip -eq 0) { $impairedSet[$x.pool] = $true } }

$domGroups = @{}
$domainList = New-Object System.Collections.ArrayList
foreach ($kv in $domMembers.GetEnumerator()) {
  $key = $kv.Key
  $g = Build-Group $kv.Value
  if (-not $g) { continue }
  $domGroups[$key] = $g
  $blk = 0.0; $rankedCount = 0; $imp = 0
  $ipKeys = @{}; $ownIp = 0
  foreach ($m in $kv.Value) {
    if ($blkOf.ContainsKey($m)) { $blk += $blkOf[$m] }
    if (-not $rankedSet.ContainsKey($m)) { continue }
    $rankedCount++
    if ($impairedSet.ContainsKey($m)) { $imp++ }
    # 独立したエンドポイント数。共有と判定されなかったプールは各自1つとして数えるので
    # これは上限値であって、独立が確認できた数ではない。
    if ($ipMap.ContainsKey($m)) { $ipKeys[$ipMap[$m].key] = $true } else { $ownIp++ }
  }
  if ($rankedCount -lt 1) { continue }
  $kind = 'ip'; $src = $null
  if ($key -like 'kes:*') { $kind = 'kes' }
  elseif ($key -notmatch ':') {
    $kind = 'label'
    foreach ($m in $kv.Value) { if ($labelSource -and $labelSource.ContainsKey($m)) { $src = $labelSource[$m]; break } }
  }
  [void]$domainList.Add([pscustomobject]@{
    key = $key; kind = $kind; src = $src
    n = $kv.Value.Count; ranked = $rankedCount
    blk = $(if ($totalBlocks -gt 0) { [Math]::Round($blk / $totalBlocks * 100, 3) } else { 0 })
    ips = ($ipKeys.Count + $ownIp)
    imp = [Math]::Round($imp / $rankedCount * 100, 1)
  })
}
# 同じ集団が「ラベル」「KESクラスター」「共有IP」で何度も現れるので、
# 規模の大きい順に見て、既に採ったものに含まれる集団は落とす。
# 例: FIGMENT の38プールは、ラベル1件とIP6件で同じ集団を指していた。
$domainList = @($domainList | Sort-Object @{e='blk';Descending=$true}, @{e='n';Descending=$true})
# 落とすときに、その集団が「なぜ一つとみなされたか」の根拠(kind)は拾っておく。
# 同じ38プールがラベルでもIPでも一致するなら、根拠が2つあるということなので。
$keptSets = New-Object System.Collections.ArrayList
$keptDm   = New-Object System.Collections.ArrayList
$deduped  = New-Object System.Collections.ArrayList
foreach ($dm in $domainList) {
  $set = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($m in $domMembers[$dm.key]) { [void]$set.Add($m) }
  $coverIdx = -1
  for ($i = 0; $i -lt $keptSets.Count; $i++) {
    if ($set.IsSubsetOf($keptSets[$i])) { $coverIdx = $i; break }
  }
  if ($coverIdx -ge 0) {
    $owner = $keptDm[$coverIdx]
    if ($owner.bases -notcontains $dm.kind) { $owner.bases += $dm.kind }
    continue
  }
  $dm | Add-Member -NotePropertyName bases -NotePropertyValue @($dm.kind) -Force
  [void]$keptSets.Add($set)
  [void]$keptDm.Add($dm)
  [void]$deduped.Add($dm)
}
$dropped = $domainList.Count - $deduped.Count
$domainList = @($deduped)
Write-Output "  cluster list: dropped $dropped duplicate views of the same group"
$domainsJson = ConvertTo-Json -InputObject $domainList -Depth 4 -Compress
if (-not $domainsJson) { $domainsJson = '[]' }
if ($domainsJson -notmatch '^\[') { $domainsJson = "[$domainsJson]" }
Write-Output "  cluster list: $($domainList.Count) failure domains"

$groupsJson = ([pscustomobject]@{ kes = $kesGroups; ip = $ipGroups; dom = $domGroups } | ConvertTo-Json -Depth 6 -Compress)
Write-Output "  groups: kes=$($kesGroups.Count) ip=$($ipGroups.Count)"
$checked = ($ranked | Where-Object checked | Select-Object -First 1).checked

# 表示部は work\template.html が単一ソース。__DATA__ と __CHECKED__ だけ差し込む。
$html = [IO.File]::ReadAllText($tpl, [Text.UTF8Encoding]::new($false))
$html = $html.Replace('__DATA__',$json).Replace('__GROUPS__',$groupsJson).Replace('__UNMEASURED__',$unmeasuredJson).Replace('__DOMAINS__',$domainsJson).Replace('__SATPOINT__',$(if($satPoint -gt 0){[long]$satPoint}else{0})).Replace('__CHECKED__',$checked)
# -OutFile may be a bare filename, in which case Split-Path yields ''.
$out = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $out))
$outDir = Split-Path $out -Parent
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force $outDir | Out-Null }
[IO.File]::WriteAllText($out,$html,[Text.UTF8Encoding]::new($false))
Write-Output "Created $out with $($ranked.Count) ranked pools"
