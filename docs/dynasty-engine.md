# Dynasty Engine: Plan

Status: draft, 2026-09-30. Replaces the build order in `HANDOFF.md`, which was
written without knowing about `my-sleeper-app` and `sleeper-player-be`. The
goals in that doc still stand; the route to them changes.

## Goal

A deterministic dynasty analysis engine that works for any Sleeper user and
league — power rankings, positional weaknesses, contend/rebuild window, sell
signals, trade suggestions, a cross-league summary — exposed as JSON endpoints
that both the app and a later LLM agent call. The agent explains results; it
never invents values.

## Architecture

```
                  ┌────────────────────────────────────────────┐
Sleeper API ─────▶│ sleeper-player-be (Elixir / Phoenix / PG)  │
FantasyCalc ─────▶│  ingest · values · draft corpus · ADP      │──▶ my-sleeper-app (React)
KeepTradeCut ────▶│  ENGINE: rankings · weakness · window ·    │
                  │          sells · trades · summary          │──▶ dynasty-agent (Python, later)
                  └────────────────────────────────────────────┘        tools = engine endpoints
                                     ▲                                  evals · models
                                     └──── model values written back as a value source
```

- **`sleeper-player-be` is the engine and the one source of truth.** It
  already owns ingest, Postgres, the nightly jobs, value sources, pick
  ownership, `TradeFinder` and `TradeValue`. New analysis lands here as pure
  modules under `Intel.*` with a thin controller each.
- **`my-sleeper-app` renders.** Where it computes analysis today
  (`powerRankings.js`, `pickSlots.js`), that logic moves server-side, and the
  JS copy is deleted once the panel reads the endpoint.
- **`dynasty-agent` (new, Python) comes later** for the agent, evals, and
  trained value models. It adds no ingest of its own. It calls the engine over
  HTTP.

## Cost

Hosting must be free or close to it, on par with today's backend: one Google
Cloud VM (`instance-1`) running Phoenix and Postgres together.

| Piece | Where it runs | Recurring cost |
|---|---|---|
| M1–M4 engine endpoints, caches, ADP corpus | Existing VM and Postgres | $0 extra. New tables and cron jobs only; no new host. |
| Frontend | Firebase Hosting (existing) | $0 |
| `dynasty-agent` (M5) | Your Mac, as a CLI | $0 hosting. **LLM API calls are the one real cost:** pay per use, with a monthly cap set in the console. Use the cheapest model that passes the evals, prompt caching, and compact tool JSON. |
| Evals | Your Mac | LLM calls only. Run them through the Batch API, which costs about half. |
| Fine-tuning a 3–8B model, value models | Your Mac (M1 Max, 64 GB) via MLX | $0. Free Colab/Kaggle GPUs if a run outgrows it. |
| Data (nflverse, Sleeper, FantasyCalc, KTC) | Public | $0 |

Rules this sets:

- **No new hosted services, managed databases, or paid data APIs** without
  a named monthly cost and your sign-off.
- **Check VM headroom before M3's wider crawl.** Before widening it, measure
  memory and disk on the VM (`free -m`, `df -h`, the Postgres table sizes)
  and cap nightly growth to fit. The disk is the limit most likely to bite.
- **In-app agent chat, if it ever happens:** proxy it through the existing
  backend with a per-user rate limit and a hard spend cap. Never call the LLM
  directly from the browser.

## Principles

- **Pure analysis modules.** Data in, result out, no HTTP or Repo calls
  inside. Controllers fetch; `Intel.*` decides. Same rule the JS lib follows.
- **Tunables in config**, never inline: tier thresholds, age cutoffs, trade
  tolerance, source weights, ADP sample minimums.
- **Every response says what it rests on**: sources used, sources missing,
  sample sizes, and value freshness (`/status` already reports this). The
  agent needs this to hedge honestly.
- **Real API responses as fixtures**, saved as the work goes, under
  `test/support/fixtures/`.
- **Tool-shaped JSON**: stable keys, IDs alongside names, no display strings
  the agent would have to parse.

## What exists today

| Capability | Where | Notes |
|---|---|---|
| Players file, daily | BE `Tasks.GetSleeperPlayerData` | 08:00 UTC cron |
| FantasyCalc + KTC values, history | BE `player_value_sources/`, `player_value_history` | FC per format; KTC 1QB/SF only |
| Format → value request | BE `market_settings.ex`, FE `marketValues.js` | |
| Pick values | BE `draft_pick_values` | |
| Pick ownership | BE `PickHoldings`, FE `ownedPicks` | Two implementations |
| Next season's pick priced by projected finish | FE `pickSlots.js` | FE only |
| Best legal lineup, Now/Future, 5 tiers | FE `powerRankings.js`, `leagueRankings.js` | FE only; Now uses proj + ADP + KTC + FC, Future uses KTC |
| Projections scored by league settings | FE `projections.js` | Season projections, not rest-of-season |
| Trade finder (fit + fairness) | BE `TradeFinder`, `TradeValue` | Not window-aware yet |
| Rookie draft corpus | BE `CrawlLeaguemateDrafts`, `observed_drafts/picks` | Rookie drafts only, from one league's leaguemates |
| Live league reads | BE `TradeController` pattern | Live fetches of rosters, users, league, drafts, traded picks |

**Not built:** positional weaknesses, sell signals, cross-league summary,
window-aware trades, any engine output an agent can call for rankings.

## Milestones

Each one ships on its own and can be reviewed on its own.

### M1: Power rankings on the server (start here)

The rest depends on this. Weakness, window, sells, summary and window-aware
trades all read the best lineup and the tier.

1. **Parity fixtures first.** Pick two real leagues: League of Boredom
   (SF, TEP 0.5, 12 teams) and 4 QB Madness (3 QB + SF, 8 teams). Run the
   existing JS `rankLeague` on their saved inputs and commit the inputs and
   outputs as golden JSON. That locks in the behavior before any porting.
2. **Port to Elixir as `Intel.PowerRankings`:** `best_lineup`, `z_scores`,
   `rank_teams`, `tier_for`. Also port `pickSlots` pricing as
   `Intel.PickSlots`. Reuse `PickHoldings` instead of porting `ownedPicks`.
   Thresholds move to config.
3. **New input: Sleeper season projections**, cached daily in the BE. The FE
   fetches them itself today.
4. **Endpoint:** `GET /api/v1/leagues/:id/rankings`. Live league reads, same as
   `TradeController`. Returns per team: now/future scores, per-source lineup
   values, tier, picks, and a `sources` block.
5. **Done when** the Elixir output matches the golden JSON. Switching the FE
   panel to the endpoint and deleting the JS copy is a separate follow-up PR.

**Done, 2026-09-30.** Server side in rghart/sleeper-player-be#60–#63 (#62
sends the tier thresholds, #63 counts an undrafted league's projections as
available), all deployed. The app switched over in rghart/my-sleeper-app#188:
the panel and the menu tier chips read `/rankings`, and `powerRankings.js`,
`pickSlots.js` and `projections.js` are gone. Checked live: the endpoint
matches the app's old `rankLeague` exactly on all five of Ryan's dynasty
leagues, and the #188 preview rendered correctly against it.

- **Fixtures:** `test/support/fixtures/power_rankings/` holds three leagues
  (`sf_te05_12t`, `qb3_sf_te075_8t`, `qb2_sf_te1_10t`), captured by
  `capture.mjs` beside them. Between them they cover all five tiers, injured
  players, 8/10/12 teams, TE premium 0.5 to 1.0, and traded future picks.
  **They are anonymised because this repo is public**: made-up manager
  names and user ids, labels instead of league ids, and only the fields the
  rankings read.
- **Port:** `Intel.PowerRankings`, `Intel.PickSlots`, `Intel.Projections`,
  `Intel.LeagueRankings`, plus `MarketSettings.from_league/1`. Thresholds and
  the ADP ceiling are in `config.exs`.
- **Parity:** `league_rankings_test.exs` reproduces the JS output field by
  field (floats to 1e-9 relative). A mutation check confirmed it fails when an
  ADP value or a tier line moves.
- **Projections (step 3):** a `player_projections` table holding Sleeper's raw
  season stats, so each league scores them itself. A nightly job runs at
  3:45am Central for the current `league_season`. `RefreshProjections.ensure/1`
  fills a season on first request. An empty or failed fetch never prunes
  what's stored.
- **Endpoint (step 4):** `GET /api/v1/leagues/:id/rankings`. Live Sleeper
  reads, KTC and pick values from the DB, FantasyCalc via `MarketValues`.
  The response carries `sources` (with `asOf`), `missing` (which source
  dropped out and why), `notes` (format gaps the market doesn't price: 3+ QBs,
  TE premium, not dynasty), the tier legend, and per-team ranks, lineups and
  pick detail. A 503 when no KTC values are stored, and a 404 for an
  unknown league.
- **Follow-up:** `PowerRankings.owned_picks/4` duplicates
  `PickHoldings.build/4`, which drops the original roster that pricing needs.
  Fold them into one after the endpoint lands.

### M2: Weakness, window, sells

**Built, 2026-10-01** (decisions from the open questions, as recommended):

- **One loader, separate endpoints.** `Intel.LeagueSnapshot` reads Sleeper
  and the stored values once, ranks, and caches the result for 60s
  (`LeagueSnapshotCache`). `/rankings`, `/weaknesses` and `/sells` all start
  from it, so an agent calling all three costs one set of Sleeper reads.
- **Weakness:** `Intel.Weakness` ports the app's `groupStrength` (the
  "Starters vs you" bars), pinned to the JS output on the three fixtures
  (`group_strength.mjs`). `GET /api/v1/leagues/:id/weaknesses` returns per
  team: each position group's blended z, z per source, and KTC value against
  the league median, plus `deficits` and `surpluses` at |z| ≥ 0.5 (config).
- **Window:** the five tiers, not terciles. Each team in `/rankings` gains a
  `window`: tier, `agedShare` (share of projected starting points past the
  age cliff, falling back to KTC), and `aging` (contenders only, true at
  ≥ 25%, config).
- **Sells:** `Intel.SellSignals` handles Middle, Rebuilding and Stuck
  teams. A candidate is a rostered player at or past his position's cutoff
  (RB 26, WR 29, TE 30, QB 33) worth ≥ 2,500 KTC. Each candidate is paired
  with the contenders whose lineup is thin (z ≤ −0.25) at his group or at
  FLEX, neediest first. `GET /api/v1/leagues/:id/sells` returns the rules
  it used beside the list.
- **Tuned 2026-10-01 on Ryan's five leagues** (rghart/sleeper-player-be#65).
  The first guesses (40% of KTC value, 1,000 KTC, buyer z ≤ 0) flagged no
  contender as aging and listed 210 sells. KTC already discounts age, so
  aging moved to projections: shares ran 6–37%, and 25% flags 5 of 17
  contenders. Sells at 2,500 / −0.25 list 149 candidates across the five
  leagues (down from 258), 62 of them with a real buyer: about one per team. The age cutoffs themselves are still the
  spec's; the deferred research pass is where they'd be checked.
- **Still to do:** move the app's "Starters vs you" bars to `/weaknesses`
  and delete `groupStrength`.

### M3: ADP from real drafts

Sleeper's projections endpoint already carries ADP columns (`adp_dynasty*`,
`adp_rookie`, `adp_2qb`, …). Nobody publishes how it is built. The plan is to
**use it provisionally, build our own from completed drafts, then measure the
disagreement** and decide from that.

1. **Provisional:** ingest Sleeper's dynasty, rookie and redraft ADP columns as
   value sources, clearly labelled `sleeper_adp`. The FE already uses the
   redraft column.
2. **Record format on every observed draft.** Today the corpus stores
   `player_type` but not format. Add `scoring_type` (e.g. `dynasty_2qb`,
   `dynasty_ppr`), the `slots_*` settings, team count, and TE premium (from the
   league's `bonus_rec_te`) as a format bucket key.
3. **Add startup drafts** to the crawl: `player_type == 0` in a dynasty league
   with enough rounds to be a startup (threshold in config). Today it keeps
   rookie drafts only.
4. **Quality filters:** `status == "complete"`, every pick filled, at least 8
   teams, not a test league, within a recency window (config). Report how many
   drafts each filter drops.
5. **Compute ADP** per bucket: mean pick, median pick, stdev, n, and
   date range. Suppress any player below a minimum sample size.
6. **Widen the corpus deliberately.** It is currently leaguemates of one
   league, which is biased toward your own circles. That is useful for intel,
   but it isn't the market. A bounded snowball crawl (leaguemates of
   leaguemates, capped per night, rate-limited) grows the sample. Report
   n per bucket so the gain is visible.
7. **Decision gate:** compare our ADP to Sleeper's per bucket
   (rank correlation, biggest disagreements). Keep, replace, or blend.
   Your call, made with the numbers in hand.

Win-now note: it's week 4. Redraft ADP is a preseason signal and goes stale
once the season starts. In-season Now should shift weight toward
rest-of-season projections (Sleeper weekly projections, summed over remaining
weeks), with ADP weight decaying by week. The weights go in config.

Optional, low priority: Fantasy Football Calculator's public redraft ADP
(`/api/v1/adp/{format}?teams=&year=`) as a cross-check.

**Corpus built, 2026-10-01** (rghart/sleeper-player-be#67):

- **A separate market corpus**, not `observed_drafts`. About 15 leaguemate-intel
  and availability queries read that table assuming every row is a
  leaguemate's rookie draft, and the availability model is calibrated
  against it. New tables: `market_users` (the frontier), `market_leagues`,
  `market_drafts` (with format), and `market_picks`.
- **Buckets** are `{kind, qb, tep}`: rookie or startup, 1QB or superflex
  (QB slots + superflex ≥ 2), TE premium or not. Eight in all. Team count and
  PPR are recorded but not split on.
- **Rules** (`Market.Format`, config): complete, `dynasty*` scoring, a
  dynasty league (type 2), ≥ 8 teams, started in the last 365 days. A
  rookie draft is player_type 1; a startup is player_type 0 with ≥ 15 rounds.
  A draft whose picks don't fill every slot is stored but not counted.
- **Crawl** (`Tasks.CrawlMarketDrafts`, 5:15am Central): seeds from the
  leaguemate users and snowballs through each qualifying draft's league.
  It stops at 1,500 calls, skips full buckets (150), and revisits a user
  after 30 days. Each draft is stored as it's fetched, so memory stays flat.
- **Measured locally against live Sleeper**, seeded from Ryan alone: 300
  calls in 19s stored 95 complete drafts (6,058 picks) and found 709
  users. 80 drafts were superflex rookie, 11 1QB rookie, and 5 startups.
  Startups are scarce (one per league), so the startup buckets will fill
  over weeks, not nights.

**ADP built, 2026-10-01** (rghart/sleeper-player-be#68):

- `GET /api/v1/adp` shows corpus progress per bucket against the target.
  `GET /api/v1/adp/:bucket` (e.g. `startup-sf-tep`) returns per player:
  mean pick, median, spread, min/max, `n` drafts and `rate` (the share of
  the bucket's drafts that took him), with Sleeper's ADP beside it. A
  player needs ≥ 5 drafts (config).
- **Comparison** (the decision gate): Spearman over shared players, mean
  rank difference, and the biggest disagreements.
- **Sleeper's columns:** `adp_dynasty_2qb` (superflex) and `adp_dynasty_ppr`
  (1QB). `adp_rookie` and `adp_dynasty` are empty for every player
  (checked 2026-10-01), so rookie buckets compare against startup ADP
  ranked among the same rookies. There is no TE-premium column. The
  response states both.
- **First real read**, from a 400-call local crawl (not production): rookie
  SF TEP, 77 drafts: ρ 0.953, mean |rank diff| 4.4. Rookie SF, 29 drafts:
  ρ 0.935, 3.6. Startup SF TEP, 5 drafts: ρ 0.979, 13.3 over 296 players.
  Sleeper's order broadly agrees, with players 12–19 places apart in rookie
  drafts. **Decide keep/replace/blend only once buckets reach ~150 drafts.**

### M4: Summary and window-aware trades

- `GET /api/v1/users/:username/summary`: every dynasty league the user is in,
  with tier, top weakness, top assets, and players who are a sell in one league
  and a hold in another. Skip redraft (0), guillotine (3), and anything else
  that isn't type 2, with a stated reason.
- **Window-aware trades:** `TradeFinder` currently disclaims knowing who is
  contending. Pass it the M2 window so contenders favor Now value and
  rebuilders favor Future value and picks. Score by the improvement to both
  sides' lineups.

### M5: `dynasty-agent` (Python), deferred

Scaffolded only after M1–M4 endpoints are stable. Tools are the engine
endpoints, so there's nothing to reimplement. Then evals over saved league
scenarios. Trained value models (age curves, rookie models on nflverse data)
come after that and publish back to the BE as a value source. The research
pass (JJ Zachariason et al.) is deferred and would feed this phase as cited
defaults and model features.

## Known format gaps

- **FantasyCalc `numQbs` caps at 2.** 3 or more starting QBs prices as
  superflex, so QBs are undervalued in leagues like 4 QB Madness. Flag it in
  the response. Later, adjust with a QB-scarcity multiplier (config).
- **No TE-premium parameter** in FantasyCalc (`tePremium` is ignored) or in
  KTC's 1QB/SF lists. Projections already score TEP correctly via
  `scoring_settings`. Market values need a TE multiplier scaled by
  `bonus_rec_te` (config).
- **FantasyCalc pick tiers:** only next year has early/mid/late. Later years
  are round-only, rounds 1–4. Round 5+ needs a fallback (config, default ~0).

## API facts verified 2026-09-30

- Sleeper `settings.type`: **0 redraft** (confirmed in a 2022 league),
  **2 dynasty** (confirmed), **3 guillotine** (not in HANDOFF; "Chopped",
  2025). **1 keeper not observed**, so treat as unverified.
- `traded_picks` lists **only traded picks**, and still includes seasons whose
  draft is done. Full ownership = every roster × season × round, minus
  trades. `PickHoldings` already does this.
- `bonus_rec_te` is **absent** (not 0) when there's no premium.
- Draft objects carry `settings.player_type` (1 rookie, 0 all players),
  `metadata.scoring_type`, `settings.rounds`, and `settings.slots_*`.
- FantasyCalc `values/current`: `isDynasty`, `numQbs` (1 or 2 only),
  `numTeams`, and `ppr` all take effect. Dynasty returns ~420 entries,
  redraft ~194. Every entry has `player.sleeperId`. Picks look like
  `FP_2027_early_0`. 93% of rostered players matched in League of Boredom;
  the misses are deep bench.
- Sleeper projections live on `api.sleeper.com` (not `.app/v1`). Season and
  weekly endpoints both work. The ADP columns are keyed by Sleeper ID.

## Open questions

1. ~~**M2 endpoints:**~~ Decided: separate endpoints over one cached snapshot.
2. **M3 snowball crawl:** how wide may it grow per night? This is a
   rate-limit and Postgres-size budget, sized from the VM headroom check in
   Cost.
3. ~~**Aging flag:**~~ Decided: share of KTC starting value past the
   position cutoffs, flagged at 40% on contenders.
