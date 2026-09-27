"""One-time backfill: every op-cert rotation event since Shelley, from Koios.

A rotation is the first block a pool mints under a new operational-certificate
counter. Upstream (ABCDE sql/55_pool_operators) derives the same events from
db-sync's block.op_cert; the counter increments with every new cert, so a
counter change marks the same moment.

Epochs are fetched in parallel but folded strictly in chain order, because a
rotation is defined against the pool's previous block.
Output rows: pool_bech32, first_seen (ISO), last_old_seen (ISO), op_cert_counter
"""
import csv, json, sys, time, urllib.request, datetime as dt
from concurrent.futures import ThreadPoolExecutor

K = 'https://api.koios.rest/api/v1'
OUT = sys.argv[1]
FIRST, LAST = int(sys.argv[2]), int(sys.argv[3])


def get(url):
    for i in range(12):
        try:
            return json.loads(urllib.request.urlopen(url, timeout=120).read())
        except Exception:
            time.sleep(5 * (i + 1))
    raise SystemExit('koios failed: ' + url)


def epoch(ep):
    rows, off = [], 0
    while True:
        p = get(f'{K}/blocks?select=pool,op_cert_counter,block_time,block_height&epoch_no=eq.{ep}'
                f'&order=block_height.asc&limit=1000&offset={off}')
        rows += p
        if len(p) < 1000:
            return ep, rows
        off += 1000


iso = lambda t: dt.datetime.fromtimestamp(t, dt.UTC).isoformat()
last = {}           # pool -> (counter, time)
events = 0
t0 = time.time()
with open(OUT, 'w', newline='', encoding='utf-8') as f, ThreadPoolExecutor(3) as ex:
    w = csv.writer(f)
    w.writerow(['pool_bech32', 'first_seen', 'last_old_seen', 'op_cert_counter'])
    eps = list(range(FIRST, LAST + 1))
    # map() yields in submission order, so folding stays in chain order
    for ep, rows in ex.map(epoch, eps):
        for b in rows:
            p, c, t = b.get('pool'), b.get('op_cert_counter'), b.get('block_time')
            if not p or c is None:
                continue
            prev = last.get(p)
            if prev and prev[0] != c:
                w.writerow([p, iso(t), iso(prev[1]), c])
                events += 1
            last[p] = (c, t)
        f.flush()
        if ep % 25 == 0:
            print(f'epoch {ep}: {events} rotations, {len(last)} pools, {int(time.time() - t0)}s', flush=True)
print(f'done epochs {FIRST}-{LAST}: {events} rotations across {len(last)} pools in {int(time.time() - t0)}s')
