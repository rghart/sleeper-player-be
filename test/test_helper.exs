# The leaguemate-intel golden tests run against `test/support/corpus/`, which is
# gitignored (this repo is public; the corpus is a compiled behavioural profile
# of real, named leaguemates). It is therefore absent on any checkout but a
# developer's own — including the deploy VM, where `CI=true mix test` gates the
# whole deploy and `set -e` would abort it on a missing-file error.
#
# So: skip the corpus-backed tests when the corpus isn't there, loudly. Every
# pure unit test — including all four estimator trap regressions — is untagged
# and still runs, so the constants that matter stay protected in CI.
corpus_present? =
  File.exists?(Path.join([__DIR__, "support", "corpus", "rookie_drafts.json"]))

exclude =
  if corpus_present? do
    []
  else
    IO.puts("""

    NOTE: test/support/corpus is absent — skipping :corpus-tagged tests
    (the leaguemate-intel golden test). Pure unit tests still run.
    """)

    [:corpus]
  end

ExUnit.start(exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(SleeperPlayerApi.Repo, :manual)
