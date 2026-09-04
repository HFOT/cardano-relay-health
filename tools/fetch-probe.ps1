<#
  Appends today's own observation of the pools upstream reports as unreachable
  to <HistDir>/probe.csv.

  Why a second observation exists at all
  --------------------------------------
  Reachability on this page is one connection attempt from one place at one
  moment, and upstream's own prober says as much in its source: a firewall that
  drops its prefix, a connection limit, a rate limiter or a restart all produce
  the same "unreachable" while the relay serves its real peers perfectly well.

  Probing by hand made that concrete. Of the pools upstream reports as totally
  unreachable, 16 completed a real node-to-node handshake from here - including
  one producing 237 blocks in 30 epochs, sitting near the bottom of the ranking.
  A vantage point in Japan and one on the build runner in the United States each
  saw pools the other could not, so a silent endpoint is describing the path
  rather than the pool.

  This records that disagreement daily. It changes no score and no page. The
  question it is meant to answer is whether the disagreement is stable enough
  to act on, and that cannot be answered from one day.

  Same tool, same test
  --------------------
  It runs cardano-cli ping, which is what upstream runs, so the two results are
  the same measurement rather than two different ones. Two things to know about
  it, both learned the hard way:

    * -q buffers output until exit, and the process does not exit on its own.
      With -q you get nothing, ever. Without it, each address prints a line as
      it completes and killing the process keeps what was written.
    * --mode tip does not return against real relays. So a handshake and its
      protocol RTT are observable here; chain tip is not. Nothing downstream
      may treat a pool measured here as at-tip or as behind tip - it is simply
      unobserved.

  Display only, and never fatal: a bad run writes nothing and the page carries
  on with upstream's numbers alone.
#>
param(
  [string]$SrcDir   = 'data',
  [string]$HistDir  = 'history',
  [string]$CliVersion = '11.2.3.0',
  [int]$Parallel    = 24,          # sweep
  [int]$ConfirmParallel = 12,       # confirm - fewer at once, because concurrency
                                   # itself changes the result: the same set run
                                   # 24-at-a-time missed a pool that 12 found
  [int]$FirstMs     = 20000,
  [int]$ConfirmMs   = 40000,
  [int]$Max         = 0            # 0 = every candidate; small values for local testing
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$healthPath = Join-Path $SrcDir 'relay_pool_health.csv'
if (-not (Test-Path $healthPath)) { throw "relay_pool_health.csv not found in $SrcDir" }
$N = { param($v) if ([string]::IsNullOrWhiteSpace($v)) { 0.0 } else { [double]$v } }

# Only the pools upstream could not reach. The rest it already answered for, and
# re-asking a question that has an answer is spending CI minutes on nothing.
$rows = @(Import-Csv $healthPath | Where-Object {
  $_.minted_last_30_epochs -eq 't' -and (& $N $_.blocks_last_30_epochs) -gt 0 `
    -and (& $N $_.endpoints_probed) -gt 0 -and (& $N $_.reachable_hosts) -eq 0
})
if ($Max -gt 0 -and $rows.Count -gt $Max) { $rows = @($rows | Select-Object -First $Max) }
Write-Output "  candidates (upstream reached none of their endpoints): $($rows.Count)"
if ($rows.Count -eq 0) { Write-Output '  nothing to probe'; return }

# --- the same binary upstream uses ------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) "cardano-cli-$CliVersion"
$exe = Join-Path $tmp 'cardano-cli-win64\cardano-cli.exe'
if (-not (Test-Path $exe)) {
  $zip = Join-Path ([IO.Path]::GetTempPath()) "cardano-cli-$CliVersion.zip"
  $url = "https://github.com/IntersectMBO/cardano-cli/releases/download/cardano-cli-$CliVersion/cardano-cli-$CliVersion-win64.zip"
  Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
  Expand-Archive $zip -DestinationPath $tmp -Force
}
if (-not (Test-Path $exe)) { throw "cardano-cli not found after unpacking to $tmp" }
Write-Output ("  " + (& $exe --version | Select-Object -First 1))

# --- registered addresses, straight from the chain --------------------------
$all = @()
for ($o = 0; $o -lt 20000; $o += 1000) {
  $page = Invoke-RestMethod -Uri "https://api.koios.rest/api/v1/pool_relays?limit=1000&offset=$o" -TimeoutSec 120
  if (-not $page) { break }
  $all += $page
  if ($page.Count -lt 1000) { break }
}
if ($all.Count -lt 3000) { throw "pool_relays returned only $($all.Count) pools" }
$rel = @{}; foreach ($x in $all) { $rel[$x.pool_id_bech32] = $x.relays }

$targets = @()
foreach ($r in $rows) {
  foreach ($e in @($rel[$r.pool_bech32])) {
    if ($e.srv) { continue }   # expanding SRV is the prober's job, not ours
    $h = if ($e.dns) { [string]$e.dns } elseif ($e.ipv4) { [string]$e.ipv4 } elseif ($e.ipv6) { "[$($e.ipv6)]" } else { $null }
    if ($h) { $targets += [pscustomobject]@{ pool = $r.pool_bech32; ticker = $r.ticker; addr = "$($h):$($e.port)" } }
  }
}
Write-Output "  endpoints to try: $($targets.Count)"

$work = Join-Path ([IO.Path]::GetTempPath()) ("probe-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $work | Out-Null

# One pass over a set of endpoints. Returns pool -> best protocol RTT in ms.
function Invoke-Pass($set, $killMs, $width) {
  $best = @{}
  for ($i = 0; $i -lt $set.Count; $i += $width) {
    $slice = $set[$i..([Math]::Min($i + $width - 1, $set.Count - 1))]
    $procs = @()
    foreach ($t in $slice) {
      $out = Join-Path $work ([guid]::NewGuid().ToString('N') + '.txt')
      try {
        $p = Start-Process -FilePath $exe `
             -ArgumentList 'ping','-c','1','-m','764824073','-j','--mode','ping',$t.addr `
             -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err"
        $procs += [pscustomobject]@{ t = $t; p = $p; out = $out }
      } catch {}
    }
    # The process never exits by itself, so the wait is the measurement window.
    $deadline = (Get-Date).AddMilliseconds($killMs)
    while ((Get-Date) -lt $deadline -and @($procs | Where-Object { -not $_.p.HasExited }).Count -gt 0) {
      Start-Sleep -Milliseconds 250
    }
    foreach ($q in $procs) { if (-not $q.p.HasExited) { try { $q.p.Kill() } catch {} } }
    Start-Sleep -Milliseconds 600
    foreach ($q in $procs) {
      $txt = Get-Content $q.out -Raw -ErrorAction SilentlyContinue
      if ($txt -and $txt -match 'network_rtt') {
        $ms = @([regex]::Matches($txt, '"network_rtt":([0-9.]+)') | ForEach-Object { [double]$_.Groups[1].Value * 1000 })
        $m = ($ms | Measure-Object -Minimum).Minimum
        if (-not $best.ContainsKey($q.t.pool) -or $m -lt $best[$q.t.pool]) { $best[$q.t.pool] = $m }
      }
      Remove-Item $q.out, "$($q.out).err" -ErrorAction SilentlyContinue
    }
  }
  return $best
}

try {
  Write-Output "  pass 1: $($targets.Count) endpoints, $([int]($FirstMs/1000))s window"
  $best = Invoke-Pass $targets $FirstMs $Parallel
  # Upstream re-tries every non-DNS failure at a longer window and records a
  # failure only when both passes fail. Matching that keeps the two comparable;
  # a shorter window here would report pools as silent that upstream would not.
  $retry = @($targets | Where-Object { -not $best.ContainsKey($_.pool) })
  if ($retry.Count -gt 0) {
    Write-Output "  pass 2: $($retry.Count) endpoints, $([int]($ConfirmMs/1000))s window, $ConfirmParallel at a time"
    foreach ($kv in (Invoke-Pass $retry $ConfirmMs $ConfirmParallel).GetEnumerator()) { $best[$kv.Key] = $kv.Value }
  }
} finally {
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

# --- append one row per candidate -------------------------------------------
New-Item -ItemType Directory -Force $HistDir | Out-Null
$outFile = Join-Path $HistDir 'probe.csv'
$today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
$existing = @()
if (Test-Path $outFile) { $existing = @(Import-Csv $outFile | Where-Object { $_.date -ne $today }) }

$new = foreach ($r in $rows) {
  [pscustomobject]@{
    date        = $today
    pool_bech32 = $r.pool_bech32
    ticker      = $r.ticker
    handshake   = $(if ($best.ContainsKey($r.pool_bech32)) { 't' } else { 'f' })
    rtt_ms      = $(if ($best.ContainsKey($r.pool_bech32)) { [Math]::Round($best[$r.pool_bech32], 2) } else { $null })
    blocks      = $r.blocks_last_30_epochs
  }
}
$new = @($new)
(@($existing) + $new) | Export-Csv -NoTypeInformation -Encoding UTF8 $outFile

$hit = @($new | Where-Object { $_.handshake -eq 't' }).Count
Write-Output ("  answered here though upstream reached none: {0} of {1} ({2:N1}%)" -f $hit, $new.Count, (100 * $hit / [Math]::Max(1, $new.Count)))
foreach ($h in ($new | Where-Object { $_.handshake -eq 't' } | Sort-Object { -[double]$_.blocks } | Select-Object -First 10)) {
  Write-Output ("    {0,-8} rtt {1,6} ms  blocks={2}" -f $h.ticker, $h.rtt_ms, $h.blocks)
}

# Killing the probe processes leaves $LASTEXITCODE set, which would read as a
# failed step. The run succeeded if it got this far.
$global:LASTEXITCODE = 0
exit 0
