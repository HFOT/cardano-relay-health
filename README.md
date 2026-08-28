# Cardano Relay Health Ranking

A single-page, interactive comparison of Cardano stake pool relay health, built from public data.
Available in English and Japanese (toggle at the top right).

**Live page:** https://hfot.github.io/cardano-relay-health/

---

## What this is

Pools that minted blocks in the last 30 epochs **and** were actually probed are scored out of 100
across six axes, then ranked. The page shows:

- **Score distribution curve** — the measured distribution across the S/A/B/C/D grade bands (not a theoretical normal curve). Click a band to filter.
- **Signal hexagon** — how often each of the six warning signals appears across all pools. Click a vertex to filter.
- **Ranking table** — one row per pool; click any row for its 6-axis hexagon, the full list of items to check, and why each item might still be perfectly normal.

## What this is **not**

- **Unreachable does not mean offline.** A firewall, rate limit, restart, or a routing difference
  from the single vantage point can all produce "no response".
- **Shared infrastructure is not proof of shared ownership.** Shared endpoints, shared resolved IPs
  and synchronised KES rotation are correlations. NAT, load balancing, shared hosting and third-party
  relay services all produce the same signals.
- **The score is not a safety certificate.** It exists to line up *how much extra checking* a pool
  warrants, on a consistent basis. Do not treat the ranking as the sole basis for a delegation decision.

Every measurement is a snapshot from one observation point at one moment in time.

## Scoring

| Axis | Points | Basis |
|---|---|---|
| Reachability & tip sync | 35 | reachable/probed and at-tip/probed, 17.5 each |
| Relay redundancy | 15 | 3+ reachable hosts = 15, 2 = 11, 1 = 5 |
| Infrastructure & operational independence | 25 | endpoint not shared 10, IP not shared 10, no synchronised KES cluster 5 |
| No borrowing | 10 | awarded when no founding-entity bootstrap backbone is registered |
| Registration continuity | 10 | awarded when all relays were never removed in the past |
| RTT | 5 | ≤150 ms = 5, ≤300 = 4, ≤600 = 3, ≤1000 = 2, above = 1 |

Grades: **S** 95–100 · **A** 85–94 · **B** 70–84 · **C** 50–69 · **D** below 50

Reference only, never deducted: same domain, same ASN, same cloud provider, similar tickers,
stake concentration. These sweep ordinary users and unrelated pools into the same group too easily.

## Data sources

Derived from the public [BEACNpool / ABCDE](https://beacnpool.github.io/abcde/) relay dataset:

- `relay_pool_health.csv`
- `relay_shared_hosts.csv`
- `pool_operator_kes_members.csv`

The source CSVs are not redistributed here; they are fetched at build time. ABCDE is MIT licensed.

## Automatic updates

A GitHub Actions workflow ([`.github/workflows/update.yml`](.github/workflows/update.yml)) runs
daily at 05:17 UTC, and on demand via *Actions → Rebuild ranking → Run workflow*. It:

1. fetches the three CSVs from `BEACNpool/ABCDE@main:data/small/`,
2. regenerates `index.html`,
3. commits **only when the output actually changed**.

Two sanity checks guard against publishing a broken page: a fetched CSV under 1 KB and a generated
page under 200 KB both fail the run rather than committing. GitHub Pages serves `index.html` from
`main`, so a successful commit is the deploy.

Nothing beyond the three public CSVs is needed — pool status (healthy / partial / behind tip /
no response) is derived from the probe counts, which was verified to reproduce the original
observation log for all 1,282 pools.

## Rebuilding

`index.html` is generated, not hand-edited. Put the three CSVs next to the script and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/generate-ranking.ps1 -SrcDir data -Template tools/template.html -OutFile index.html
```

- `tools/template.html` holds all markup, styling and the i18n dictionary. It is the single source
  for the presentation layer; the script only substitutes `__DATA__` and `__CHECKED__`.
- `tools/generate-ranking.ps1` reads the CSVs, computes the scores, and emits language-neutral issue
  codes (`REACH_PARTIAL`, `KES_CLUSTER`, …) which the page renders in the selected language.

The script is saved UTF-8 **with BOM** — Windows PowerShell 5.1 mis-parses the Japanese string
literals without it.

## License

The page and tooling are provided as-is for informational purposes. Underlying data belongs to its
respective sources.
