# Measures how even real Sleeper trades are, for `Intel.TradeFairness`
# (docs/dynasty-engine.md, M4). Read-only against production; the analysis
# runs locally with the app's own `TradeValue`.
#
# 1. Export, into $CALIBRATION_DIR, from the production database (read-only):
#
#    trade_players.csv - every player in a completed trade, with his KTC value
#    on the latest day on or before the trade, in both formats:
#
#      \copy (with t as (select id, league_id, created::date as day, adds
#        from observed_transactions where type = 'trade' and status = 'complete'),
#      p as (select t.id, t.league_id, t.day, kv.key as player_id, kv.value as roster_id
#        from t, jsonb_each_text(t.adds::jsonb) kv where kv.key ~ '^[0-9]+$')
#      select p.id, p.league_id, p.day, p.player_id, p.roster_id,
#        (select value from player_value_history h where h.player_id = p.player_id::bigint
#          and h.source = 'keeptradecut:sf' and h.day <= p.day order by h.day desc limit 1) as sf,
#        (select value from player_value_history h where h.player_id = p.player_id::bigint
#          and h.source = 'keeptradecut:1qb' and h.day <= p.day order by h.day desc limit 1) as oq
#      from p) to stdout with csv header
#
#    trade_picks.csv - every pick in a completed trade:
#
#      \copy (select t.id, t.league_id, t.created::date as day, (pk->>'season') as season,
#        (pk->>'round') as round, (pk->>'owner_id') as owner_id,
#        (pk->>'roster_id') as original_roster_id
#      from observed_transactions t, unnest(t.draft_picks) pk
#      where t.type = 'trade' and t.status = 'complete') to stdout with csv header
#
# 2. trade_leagues.json - each league's format from Sleeper's public API:
#    `{league_id: {qb, type, teams, tep, te_slots, rec}}`, qb = QB + SUPER_FLEX slots.
# 3. picks_sf.json / picks_1qb.json - `/api/v1/dynasty-values` (and
#    `?superflex=false`). Picks have no value history, so a pick is priced by
#    how many drafts away it was when traded, at today's price for a pick
#    that far out (mid tier) - an approximation that ignores picks gaining
#    value as their draft nears.
# 4. te_ids.json - the ids of every tight end, for the TE-premium check.
#
# Run: CALIBRATION_DIR=... MIX_ENV=test mix run --no-start priv/calibration/real_trade_gaps.exs
# The last line printed is the quantile list for `TradeFairness` config.
dir = System.get_env("CALIBRATION_DIR") || raise("set CALIBRATION_DIR to the folder holding the exported files")
alias SleeperPlayerApi.Intel.TradeValue
read_csv = fn file ->
  [header | rows] = File.read!(Path.join(dir, file)) |> String.split("\n", trim: true) |> Enum.map(&String.split(&1, ","))
  Enum.map(rows, &Map.new(Enum.zip(header, &1)))
end
leagues = File.read!(Path.join(dir, "trade_leagues.json")) |> Jason.decode!()
pick_price = for {fmt, f} <- [{"sf", "picks_sf.json"}, {"oq", "picks_1qb.json"}], into: %{} do
  ps = File.read!(Path.join(dir, f)) |> Jason.decode!() |> Map.fetch!("picks")
  {fmt, for(p <- ps, p["tier"] == "mid", into: %{}, do: {{p["season"], p["round"]}, p["value"]})}
end
num = fn s -> case Float.parse(s || "") do {f, _} -> f; :error -> nil end end
players = read_csv.("trade_players.csv")
te_ids = File.read!(Path.join(dir, "te_ids.json")) |> Jason.decode!() |> MapSet.new()
picks = read_csv.("trade_picks.csv")
by_trade = Enum.group_by(players, & &1["id"])
picks_by_trade = Enum.group_by(picks, & &1["id"])
ids = Enum.uniq(Map.keys(by_trade) ++ Map.keys(picks_by_trade))

results =
  for id <- ids, reduce: [] do
    acc ->
      ps = Map.get(by_trade, id, []); pk = Map.get(picks_by_trade, id, [])
      any = List.first(ps) || List.first(pk)
      league = leagues[any["league_id"]] || %{}
      fmt = if (league["qb"] || 2) >= 2, do: "sf", else: "oq"
      {:ok, day} = Date.from_iso8601(any["day"])
      next_draft = if Date.compare(day, ~D[2026-06-01]) == :lt, do: 2026, else: 2027
      sides =
        Enum.map(ps, &{&1["roster_id"], num.(&1[fmt])}) ++
          Enum.map(pk, fn p ->
            {season, _} = Integer.parse(p["season"]); {round, _} = Integer.parse(p["round"])
            {p["owner_id"], pick_price[fmt][{2027 + (season - next_draft), round}]}
          end)
      grouped = Enum.group_by(sides, &elem(&1, 0), &elem(&1, 1))
      cond do
        map_size(grouped) != 2 -> acc
        league["type"] != 2 -> acc
        Enum.any?(sides, fn {_, v} -> v == nil end) -> acc
        true ->
          [a, b] = Map.values(grouped)
          ev = TradeValue.evaluate(a, b, 10_000)
          larger = max(ev.one.adjusted, ev.two.adjusted)
          if larger <= 0, do: acc, else: [%{gap: abs(ev.one.adjusted - ev.two.adjusted) / larger,
            raw_gap: abs(ev.one.raw - ev.two.raw) / max(max(ev.one.raw, ev.two.raw), 1),
            picks: pk != [], pieces: length(sides), fmt: fmt,
            has_te: Enum.any?(ps, &MapSet.member?(te_ids, &1["player_id"])),
            tep_league: (league["tep"] || 0) > 0} | acc]
      end
  end

pct = fn list, p -> s = Enum.sort(list); Enum.at(s, min(length(s) - 1, round(p * (length(s) - 1)))) end
show = fn label, rs ->
  gaps = Enum.map(rs, & &1.gap); raws = Enum.map(rs, & &1.raw_gap)
  within = fn band -> Enum.count(gaps, &(&1 <= band)) / max(length(gaps), 1) end
  IO.puts("#{String.pad_trailing(label, 30)} n=#{String.pad_leading("#{length(rs)}", 4)}  adjusted gap p50 #{Float.round(pct.(gaps, 0.5) * 100, 1)}%  p75 #{Float.round(pct.(gaps, 0.75) * 100, 1)}%  p90 #{Float.round(pct.(gaps, 0.9) * 100, 1)}% | within 12%: #{round(within.(0.12) * 100)}%  20%: #{round(within.(0.20) * 100)}% | raw-sum gap p50 #{Float.round(pct.(raws, 0.5) * 100, 1)}%")
end
show.("all 2-team dynasty trades", results)
show.("no TE in a TEP league", Enum.reject(results, &(&1.has_te and &1.tep_league)))
show.("  ...and players only", Enum.reject(results, &(&1.picks or (&1.has_te and &1.tep_league))))
show.("TE involved, TEP league", Enum.filter(results, &(&1.has_te and &1.tep_league)))
gaps = results |> Enum.map(& &1.gap) |> Enum.sort()
quantiles = for q <- 0..20, do: Float.round(pct.(gaps, q / 20), 4)
IO.puts("QUANTILES (every 5%, 0..100): " <> inspect(quantiles))
