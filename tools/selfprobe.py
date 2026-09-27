#!/usr/bin/env python3
"""selfprobe.py - collect, ourselves, the two upstream files this page scores from.

Why this exists
---------------
The ranking is built from BEACNpool's ABCDE relay dataset. That dataset stopped
updating on 2026-09-14. Until then this page had no measurement of its own for
reachability, tip sync or RTT, so from that day the page kept rebuilding on the
same frozen numbers.

This script produces the same two files - relay_pool_health.csv and
relay_shared_hosts.csv - in the same shape, from public sources only:

  * pools, tickers, stake, delegators, registered relays   Koios pool_list / pool_info
  * blocks minted in the last 30 epochs                    Koios blocks, paged per epoch
  * registration history (relays added / all removed)      Koios pool_updates
  * reachability, chain tip, RTT                           cardano-cli ping, run here

The workflow uses these files only when upstream's own last_checked is stale,
so while upstream publishes, upstream is what the page shows.

Same tool, same test as upstream
--------------------------------
Upstream's prober runs `cardano-cli ping -c 1 -q -j -t` on Linux and records a
failure only when a second, longer pass also fails. This does the same. The tip
request only works on Linux: the Windows build fails it with SDUWriteTimeout,
which is why earlier attempts to collect tip here concluded it was impossible.

"At tip" follows upstream's definition - within 180 slots of the chain tip.
The chain tip is taken from the wall clock (mainnet slot = unix time -
1591566291, one slot per second since Shelley), checked against Koios' tip
before the run. That avoids trusting any single relay's view of the chain.

Only pools that minted in the last 30 epochs are probed - the ranking uses no
others - but every registered pool's addresses are resolved, so shared-address
groups still include pools that are not ranked.

No IPv6 on GitHub's runners: an endpoint reachable only over IPv6 is recorded
as untested, never as unreachable, exactly as upstream does.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

KOIOS = 'https://api.koios.rest/api/v1'
MAGIC = '764824073'
SHELLEY_OFFSET = 1591566291      # mainnet: slot = unix seconds - this
AT_TIP_SLOTS = 180               # upstream's tolerance
SRV_PREFIX = '_cardano._tcp.'


def log(*a):
    print(*a, flush=True)


def now_utc():
    return dt.datetime.now(dt.UTC)


def fmt_ts(t: dt.datetime) -> str:
    return t.strftime('%Y-%m-%d %H:%M:%S+00')


# --- Koios ------------------------------------------------------------------
def http_json(url, body=None, headers=None, tries=6):
    h = {'accept': 'application/json'}
    if body is not None:
        h['content-type'] = 'application/json'
    h.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, data=data, headers=h)
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.loads(r.read())
        except Exception as e:  # rate limit, transient 5xx, network
            if i == tries - 1:
                raise
            time.sleep(2 * (i + 1))


def paged(path, limit=1000):
    out, off = [], 0
    sep = '&' if '?' in path else '?'
    while True:
        page = http_json(f'{KOIOS}/{path}{sep}limit={limit}&offset={off}')
        out += page
        if len(page) < limit:
            return out
        off += limit


# --- registry -----------------------------------------------------------------
def load_registry():
    pools = [p for p in paged('pool_list?select=pool_id_bech32,ticker,pool_status')
             if p.get('pool_status') == 'registered']
    ids = [p['pool_id_bech32'] for p in pools]
    tick = {p['pool_id_bech32']: (p.get('ticker') or '') for p in pools}
    log(f'  registered pools: {len(ids)}')

    def batch(i):
        return http_json(f'{KOIOS}/pool_info', {'_pool_bech32_ids': ids[i:i + 50]})
    info = {}
    with ThreadPoolExecutor(4) as ex:
        for res in ex.map(batch, range(0, len(ids), 50)):
            for p in res:
                info[p['pool_id_bech32']] = p
    log(f'  pool_info: {len(info)}')
    return ids, tick, info


def blocks_last_30(tip_epoch):
    epochs = list(range(tip_epoch - 29, tip_epoch + 1))

    def one(ep):
        c = defaultdict(int)
        for b in paged(f'blocks?select=pool&epoch_no=eq.{ep}'):
            if b.get('pool'):
                c[b['pool']] += 1
        return c
    total = defaultdict(int)
    with ThreadPoolExecutor(6) as ex:
        for c in ex.map(one, epochs):
            for k, v in c.items():
                total[k] += v
    log(f'  blocks counted over epochs {epochs[0]}-{epochs[-1]}: {sum(total.values())}')
    return total


def relay_key(r):
    if r.get('srv'): return 'srv:' + r['srv'].lower()
    if r.get('dns'): return f"dns:{r['dns'].lower()}:{r.get('port')}"
    if r.get('ipv4'): return f"ipv4:{r['ipv4']}:{r.get('port')}"
    if r.get('ipv6'): return f"ipv6:{r['ipv6']}:{r.get('port')}"
    return None


def registration_history():
    """Relays added / all relays removed, as upstream counts them.

    Checked against upstream's last published file: this reproduces
    ever_removed_all_relays and its date for all 2,896 pools, and
    relay_additions for 2,886. Two certificates can land in the same block;
    they must stay in chain order (a stable sort on time alone), because
    breaking the tie by relay count invents removals that never happened.
    """
    rows = paged('pool_updates?select=pool_id_bech32,block_time,update_type,relays')
    by = defaultdict(list)
    for r in rows:
        if r.get('update_type') == 'registration':
            by[r['pool_id_bech32']].append((r['block_time'] or 0, {k for k in map(relay_key, r.get('relays') or []) if k}))
    hist = {}
    for p, ev in by.items():
        ev.sort(key=lambda x: x[0])
        adds = reds = 0
        removed_on = None
        for (_, a), (t, b) in zip(ev, ev[1:]):
            if len(b) > len(a):
                adds += 1
            elif len(b) < len(a):
                reds += 1
            if a and not b:
                removed_on = dt.datetime.fromtimestamp(t, dt.UTC).strftime('%Y-%m-%d')
        hist[p] = (adds, reds, removed_on)
    log(f'  registration history: {len(rows)} updates across {len(hist)} pools')
    return hist


# --- endpoints and resolution ---------------------------------------------------
def endpoints_of(relays):
    """Registered relays -> endpoint records, keyed the way upstream keys them."""
    out = []
    for r in relays or []:
        port = r.get('port')
        if r.get('srv'):
            out.append({'key': 'srv:' + r['srv'], 'kind': 'srv', 'host': r['srv'], 'port': port})
        elif r.get('dns'):
            out.append({'key': 'dns:' + r['dns'].lower(), 'kind': 'dns', 'host': r['dns'], 'port': port})
        elif r.get('ipv4'):
            out.append({'key': f"ipv4:{r['ipv4']}:{port}", 'kind': 'ipv4', 'host': r['ipv4'], 'port': port})
        elif r.get('ipv6'):
            out.append({'key': f"ipv6:{r['ipv6']}:{port}", 'kind': 'ipv6', 'host': r['ipv6'], 'port': port})
    # one registration can list the same endpoint twice
    seen, uniq = set(), []
    for e in out:
        k = (e['key'], e['port'])
        if k not in seen:
            seen.add(k)
            uniq.append(e)
    return uniq


def resolve(host):
    v4, v6 = set(), set()
    try:
        for fam, *_rest, sa in socket.getaddrinfo(host, None):
            (v4 if fam == socket.AF_INET else v6).add(sa[0])
    except Exception:
        pass
    return sorted(v4), sorted(v6)


def resolve_srv(name):
    try:
        import dns.resolver  # dnspython, installed by the workflow
    except Exception:
        return None
    for q in ([name] if name.startswith('_') else [SRV_PREFIX + name, name]):
        try:
            ans = dns.resolver.resolve(q, 'SRV', lifetime=10)
            return [(str(a.target).rstrip('.'), int(a.port)) for a in ans]
        except Exception:
            continue
    return []


# --- the probe ------------------------------------------------------------------
def ping(cli, host, port, timeout):
    """One run of upstream's exact invocation. Returns (tips, failure)."""
    try:
        p = subprocess.run([cli, 'ping', '-h', host, '-p', str(port), '-m', MAGIC,
                            '-c', '1', '-q', '-j', '-t'],
                           capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return [], 'timeout'
    try:
        tips = json.loads(p.stdout or '{}').get('tip', [])
    except json.JSONDecodeError:
        tips = []
    if tips:
        return tips, None
    err = (p.stderr or '')
    if 'refused' in err.lower():
        return [], 'refused'
    if 'does not exist' in err or 'getAddrInfo' in err:
        return [], 'dns_fail'
    return [], 'timeout' if 'Timeout' in err else 'error'


def probe_all(cli, targets, first_s, confirm_s, width, confirm_width):
    """targets: list of (tid, host, port). Returns tid -> (tips, failure, observed_unix)."""
    res = {}

    def run(t, timeout):
        tid, host, port = t
        tips, fail = ping(cli, host, port, timeout)
        return tid, tips, fail, time.time()

    with ThreadPoolExecutor(width) as ex:
        for tid, tips, fail, at in ex.map(lambda t: run(t, first_s), targets):
            res[tid] = (tips, fail, at)
    retry = [t for t in targets if not res[t[0]][0] and res[t[0]][1] not in ('dns_fail',)]
    log(f'  pass 1: {len(targets)} targets, {first_s}s -> {len(targets) - len(retry)} answered or DNS-dead; '
        f'pass 2: {len(retry)} at {confirm_s}s')
    with ThreadPoolExecutor(confirm_width) as ex:
        for tid, tips, fail, at in ex.map(lambda t: run(t, confirm_s), retry):
            if tips:
                res[tid] = (tips, None, at)
    return res


# --- main ------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cli', required=True)
    ap.add_argument('--out', default='data')
    ap.add_argument('--first', type=int, default=20)
    ap.add_argument('--confirm', type=int, default=35)
    ap.add_argument('--workers', type=int, default=48)
    ap.add_argument('--confirm-workers', type=int, default=24)
    ap.add_argument('--max-pools', type=int, default=0, help='probe only this many minting pools (testing)')
    ap.add_argument('--upstream-last', default='', help="upstream's newest last_checked, for the page notice")
    a = ap.parse_args()

    started = now_utc()
    tip = http_json(f'{KOIOS}/tip')[0]
    wall_slot = int(time.time()) - SHELLEY_OFFSET
    drift = wall_slot - int(tip['abs_slot'])
    log(f'chain tip epoch {tip["epoch_no"]} slot {tip["abs_slot"]}; wall-clock slot {wall_slot} (drift {drift})')
    if abs(drift) > 600:
        raise SystemExit(f'wall clock and chain tip disagree by {drift} slots - refusing to judge tip sync')

    ids, tick, info = load_registry()
    blocks = blocks_last_30(int(tip['epoch_no']))
    hist = registration_history()

    eps = {p: endpoints_of((info.get(p) or {}).get('relays')) for p in ids}
    minted = [p for p in ids if blocks.get(p, 0) > 0]
    if a.max_pools:
        minted = minted[:a.max_pools]
    minted_set = set(minted)
    log(f'  pools minting in the last 30 epochs: {len(minted)}')

    # which pools registered each endpoint string (upstream's shares_endpoint)
    by_key = defaultdict(set)
    for p, es in eps.items():
        for e in es:
            by_key[(e['key'], e['port'])].add(p)

    # resolve every registered name once (all pools: shared-address groups need them)
    names = {e['host'] for es in eps.values() for e in es if e['kind'] == 'dns'}
    with ThreadPoolExecutor(64) as ex:
        rz = dict(zip(names, ex.map(resolve, names)))
    log(f'  resolved {len(names)} names')

    # build probe targets for minting pools only
    targets, tmeta = [], {}
    ep_state = {}      # (pool, key, port) -> 'untested' | 'dns_fail' | tid list
    for p in minted:
        for e in eps[p]:
            k = (p, e['key'], e['port'])
            if e['kind'] == 'ipv6':
                ep_state[k] = 'untested'
                continue
            if e['kind'] == 'dns':
                v4, v6 = rz.get(e['host'], ([], []))
                if not v4 and v6:
                    ep_state[k] = 'untested'
                    continue
                if not v4 and not v6:
                    ep_state[k] = 'dns_fail'
                    continue
                hosts = [(e['host'], e['port'])]
            elif e['kind'] == 'srv':
                srv = resolve_srv(e['host'])
                if not srv:
                    ep_state[k] = 'dns_fail'
                    continue
                hosts = srv
            else:
                hosts = [(e['host'], e['port'])]
            tids = []
            for h, port in hosts:
                tid = len(targets)
                targets.append((tid, h, port))
                tids.append(tid)
            ep_state[k] = tids

    res = probe_all(a.cli, targets, a.first, a.confirm, a.workers, a.confirm_workers)

    # ---- relay_pool_health.csv ----
    now_s = fmt_ts(now_utc())
    health = []
    ok_total = tip_total = 0
    for p in ids:
        es = eps[p]
        adds, reds, removed_on = hist.get(p, (0, 0, None))
        n_blocks = blocks.get(p, 0)
        row = {
            'pool_bech32': p, 'ticker': tick.get(p, ''),
            'stake_ada': int(int((info.get(p) or {}).get('live_stake') or 0) / 1_000_000),
            'delegators': (info.get(p) or {}).get('live_delegators') or 0,
            'blocks_last_30_epochs': n_blocks, 'minted_last_30_epochs': 't' if n_blocks > 0 else 'f',
            'relay_entries': len((info.get(p) or {}).get('relays') or []),
            'distinct_endpoints': len(es),
            'registration_class': 'NO_RELAYS' if not es else ('SINGLE_ENDPOINT' if len(es) == 1 else 'MULTIPLE_ENDPOINTS'),
            'relay_additions': adds, 'relay_reductions': reds,
            'ever_removed_all_relays': 't' if removed_on else 'f', 'removed_all_relays_on': removed_on or '',
            'endpoints_probed': 0, 'reachable_hosts': 0, 'at_tip_hosts': 0, 'endpoints_untested': 0,
            'best_rtt_ms': '',
            'shares_endpoint_with_other_pool': 't' if any(len(by_key[(e['key'], e['port'])]) > 1 for e in es) else 'f',
            'reachability_class': 'NOT_PROBED', 'last_checked': '',
        }
        if p in minted_set and es:
            reach, attip, rtts, last = set(), set(), [], None
            untested = 0
            for e in es:
                st = ep_state.get((p, e['key'], e['port']))
                if st == 'untested':
                    untested += 1
                    continue
                if not isinstance(st, list):
                    continue
                for tid in st:
                    tips, fail, at = res.get(tid, ([], 'error', None))
                    last = max(last or at, at) if at else last
                    for t in tips:
                        addr = t.get('addr')
                        reach.add(addr)
                        rtts.append(float(t.get('rtt', 0)) * 1000)
                        wall = int(at) - SHELLEY_OFFSET
                        if wall - int(t.get('slotNo', 0)) <= AT_TIP_SLOTS:
                            attip.add(addr)
            row.update({
                'endpoints_probed': len(es), 'endpoints_untested': untested,
                'reachable_hosts': len(reach), 'at_tip_hosts': len(attip),
                'best_rtt_ms': round(min(rtts), 2) if rtts else '',
                'reachability_class': ('NOT_TESTED_FROM_THIS_PROBE' if untested >= len(es) else
                                       'NONE_REACHABLE' if not reach else
                                       'ONE_REACHABLE_HOST' if len(reach) == 1 else 'MULTI_REACHABLE_HOSTS'),
                'last_checked': fmt_ts(dt.datetime.fromtimestamp(last, dt.UTC)) if last else now_s,
            })
            ok_total += bool(reach)
            tip_total += bool(attip)
        health.append(row)

    os.makedirs(a.out, exist_ok=True)
    cols = list(health[0].keys())
    with open(os.path.join(a.out, 'relay_pool_health.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(health)

    # ---- relay_shared_hosts.csv ----
    # Upstream groups by the address that actually answered the probe, not by
    # what a name resolves to from wherever the resolver sits. Names served by
    # geographic DNS return different addresses to different places, so grouping
    # on DNS answers would put pools on the same host that never met there.
    groups = defaultdict(lambda: {'pools': set(), 'names': set()})
    for p in minted:
        for e in eps[p]:
            st = ep_state.get((p, e['key'], e['port']))
            if not isinstance(st, list):
                continue
            for tid in st:
                for t in res.get(tid, ([], None, None))[0]:
                    g = groups[(t.get('addr'), t.get('port') or e['port'])]
                    g['pools'].add(p)
                    g['names'].add(e['key'])
    shared = []
    for (ip, port), g in groups.items():
        if len(g['pools']) < 2:
            continue
        ps = sorted(g['pools'])
        shared.append({
            'resolved_ip': ip, 'target_port': port, 'pools': len(ps),
            'stake_ada': sum(int(int((info.get(x) or {}).get('live_stake') or 0) / 1_000_000) for x in ps),
            'delegators': sum(int((info.get(x) or {}).get('live_delegators') or 0) for x in ps),
            'distinct_registered_names': len(g['names']),
            'tickers': ' '.join(sorted({tick.get(x) or '' for x in ps} - {''})),
            'pool_bech32s': ' '.join(ps),
        })
    with open(os.path.join(a.out, 'relay_shared_hosts.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=['resolved_ip', 'target_port', 'pools', 'stake_ada', 'delegators',
                                          'distinct_registered_names', 'tickers', 'pool_bech32s'])
        w.writeheader()
        w.writerows(shared)

    # A broken run must not replace stale-but-real numbers with wrong ones. Of the
    # pools minting blocks, upstream reached roughly 85%; a run far below that says
    # more about this runner's network than about the pools.
    if len(minted) >= 500 and ok_total < 0.6 * len(minted):
        raise SystemExit(f'only {ok_total} of {len(minted)} minting pools answered - refusing to publish this run')

    with open(os.path.join(a.out, 'source.json'), 'w', encoding='utf-8') as f:
        json.dump({'source': 'self', 'upstream_last': a.upstream_last, 'started': fmt_ts(started), 'finished': now_s,
                   'probed_pools': len(minted), 'targets': len(targets),
                   'reachable_pools': ok_total, 'at_tip_pools': tip_total,
                   'tip_slot_drift': drift}, f)
    log(f'done: {len(health)} pools, {len(minted)} probed, {ok_total} reachable, {tip_total} with a host at tip, '
        f'{len(shared)} shared addresses; {int((now_utc() - started).total_seconds())}s')


if __name__ == '__main__':
    main()
