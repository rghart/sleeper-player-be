# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     SleeperPlayerApi.Repo.insert!(%SleeperPlayerApi.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.
for pos <- [
  "OLB",
  "CB",
  "LB",
  "DL",
  "SS",
  "K",
  "OG",
  "P",
  "OT",
  "ILB",
  "T",
  "G",
  "WR",
  "OL",
  "DT",
  "TE",
  "S",
  "RB",
  "QB",
  "FS",
  "DEF",
  "C",
  "FB",
  "NT",
  "LS",
  "DB",
  "DE"
] do
  {:ok, _} = SleeperPlayerApi.Sleeper.create_position(%{abbreviation: pos})
end

for team <- [
  "ARI",
  "ATL",
  "BAL",
  "BUF",
  "CAR",
  "CHI",
  "CIN",
  "CLE",
  "DAL",
  "DEN",
  "DET",
  "GB",
  "HOU",
  "IND",
  "JAX",
  "KC",
  "LAC",
  "LAR",
  "LV",
  "MIA",
  "MIN",
  "NE",
  "NO",
  "NYG",
  "NYJ",
  "OAK",
  "PHI",
  "PIT",
  "SEA",
  "SF",
  "TB",
  "TEN",
  "WAS"
] do
  {:ok, _} = SleeperPlayerApi.Sleeper.create_team(%{abbreviation: team})
end

for status <- [
  "Inactive",
  "Injured Reserve",
  "Non Football Injury",
  "Practice Squad",
  "Active",
  "Physically Unable to Perform"
] do
  {:ok, _} = SleeperPlayerApi.Sleeper.create_status(%{status: status})
end