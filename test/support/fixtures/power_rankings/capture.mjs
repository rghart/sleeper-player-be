// Captures golden fixtures for the Elixir port of the frontend's power
// rankings (docs/dynasty-engine.md, M1 step 1).
//
// For each league it fetches exactly the inputs `PowerRankingsPanel` gathers,
// runs the frontend's own `rankLeague` over them, and writes both to
// `<label>.json`. The Elixir port is correct when it reproduces `expected`
// from `inputs`.
//
// This repo is public, so the fixtures are anonymised before anything is
// ranked: managers become "Manager N" with made-up user ids, the league id
// and name are replaced by the label, and only the league, roster and draft
// fields the rankings read are kept (no nicknames, avatars or co-owners).
// Player ids stay real - they are NFL players, and the values depend on them.
//
// The inputs are also trimmed to the players on the league's rosters so the
// files stay small. Trimming must not change the answer, so the script ranks
// both the full and the trimmed inputs and refuses to write if they differ.
//
// The frontend's `rankLeague` was deleted once the app read these rankings
// from the backend (rghart/my-sleeper-app#188), so recapturing needs a
// my-sleeper-app checkout from before that, e.g. `git worktree add
// /tmp/fe aa57869`. Run from the repo root, pointing at it:
//
//     node test/support/fixtures/power_rankings/capture.mjs ~/src/my-sleeper-app <label>=<league_id>...
//
// Needs network access. The output is deterministic only for the moment it
// was captured, which is the point of saving it.

import { writeFile } from 'node:fs/promises';
import { registerHooks } from 'node:module';
import { isDeepStrictEqual } from 'node:util';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const [frontendPath, ...targets] = process.argv.slice(2);
if (!frontendPath || targets.length === 0 || !targets.every((t) => /^[a-z0-9_]+=\d+$/.test(t))) {
    console.error('usage: capture.mjs <my-sleeper-app path> <label>=<league_id>...');
    process.exit(1);
}

// The frontend's modules are written for Vite, which defines `import.meta.env`;
// plain Node leaves it undefined, and `src/urls.js` reads it at import time.
// Supply the production values rather than changing the frontend.
const frontendSrc = pathToFileURL(resolve(frontendPath, 'src')).href;
registerHooks({
    load(url, context, nextLoad) {
        const result = nextLoad(url, context);
        if (!url.startsWith(frontendSrc)) return result;
        const source = String(result.source).replaceAll('import.meta.env', '({ DEV: false, PROD: true })');
        return { ...result, source };
    },
});

const lib = (file) => import(pathToFileURL(resolve(frontendPath, 'src/lib', file)).href);
const { rankLeague } = await lib('leagueRankings.js');
const { leagueMarketSettings } = await lib('marketValues.js');
const { usesSuperflexValues } = await lib('dynastyValues.js');
const { decorateRosters } = await lib('rosterInfo.js');

const SLEEPER = 'https://api.sleeper.app/v1/';
const BACKEND = 'https://fantasyteamassistant.com/';
const PROJECTIONS = (season) =>
    `https://api.sleeper.com/projections/nfl/${season}` +
    '?season_type=regular&position[]=QB&position[]=RB&position[]=WR&position[]=TE&position[]=K&position[]=DEF';

async function getJson(url) {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`${response.status} ${url}`);
    return response.json();
}

// Same query-string building as the frontend's fetchMarketValues.
function marketValuesUrl(settings) {
    const params = new URLSearchParams();
    if (settings?.dynasty != null) params.set('dynasty', String(settings.dynasty));
    if (settings?.numQbs != null) params.set('num_qbs', String(settings.numQbs));
    if (settings?.numTeams != null) params.set('num_teams', String(settings.numTeams));
    if (settings?.ppr != null) params.set('ppr', String(settings.ppr));
    return `${BACKEND}api/v1/values?${params}`;
}

const pick = (object, keys) =>
    Object.fromEntries(keys.filter((key) => key in (object ?? {})).map((key) => [key, object[key]]));

// Every field below is one the rankings read; anything else is left behind.
function anonymise({ label, league, rosters, users, draft }) {
    const fakeId = new Map(rosters.map((roster, i) => [roster.owner_id, String(1000 + i + 1)]));
    const anonId = (userId) => (userId == null ? null : (fakeId.get(userId) ?? null));

    return {
        league: {
            league_id: label,
            name: label,
            ...pick(league, ['season', 'status', 'total_rosters', 'roster_positions', 'scoring_settings']),
            settings: pick(league.settings, ['type', 'draft_rounds', 'playoff_week_start']),
        },
        rosters: rosters.map((roster) => ({
            ...pick(roster, ['roster_id', 'players', 'reserve', 'taxi']),
            owner_id: anonId(roster.owner_id),
            settings: pick(roster.settings, ['wins', 'losses', 'ties', 'fpts', 'fpts_decimal']),
        })),
        users: rosters
            .filter((roster) => roster.owner_id != null && users.some((u) => u.user_id === roster.owner_id))
            .map((roster) => ({ user_id: anonId(roster.owner_id), display_name: `Manager ${roster.roster_id}` })),
        draft: draft && {
            ...pick(draft, ['season', 'status', 'type']),
            draft_order: draft.draft_order
                ? Object.fromEntries(
                      Object.entries(draft.draft_order)
                          .filter(([userId]) => fakeId.has(userId))
                          .map(([userId, slot]) => [anonId(userId), slot]),
                  )
                : null,
        },
    };
}

// Only the player fields `bestLineup` reads.
const PLAYER_FIELDS = ['position', 'fantasy_positions', 'injury_status'];

function trim({ rankArgs, rostered }) {
    const keep = (id) => rostered.has(String(id));
    const { inputs, playerInfo, league } = rankArgs;
    // Projections are scored as a dot product over the league's own scoring
    // keys, and ADP is read from the `adp_*` columns; no other stat is read.
    const statKeys = (key) => key in (league.scoring_settings ?? {}) || key.startsWith('adp_');
    const valueFields = ({ playerId, value }) => ({ playerId, value });
    return {
        ...rankArgs,
        playerInfo: Object.fromEntries(
            Object.entries(playerInfo)
                .filter(([id]) => keep(id))
                .map(([id, player]) => [id, Object.fromEntries(PLAYER_FIELDS.map((f) => [f, player[f] ?? null]))]),
        ),
        inputs: {
            ...inputs,
            ktc: { ...inputs.ktc, values: inputs.ktc.values.filter((v) => keep(v.playerId)).map(valueFields) },
            fc: inputs.fc && {
                ...inputs.fc,
                values: inputs.fc.values.filter((v) => keep(v.playerId)).map(valueFields),
            },
            projections:
                inputs.projections &&
                inputs.projections
                    .filter((row) => keep(row.player_id))
                    .map(({ player_id, stats }) => ({
                        player_id,
                        stats: Object.fromEntries(Object.entries(stats ?? {}).filter(([key]) => statKeys(key))),
                    })),
        },
    };
}

const players = await getJson(`${BACKEND}api/legacy/players`);
const outDir = dirname(fileURLToPath(import.meta.url));

for (const target of targets) {
    const [label, leagueId] = target.split('=');
    const [rawLeague, rawRosters, rawUsers, tradedPicks, drafts] = await Promise.all(
        ['', '/rosters', '/users', '/traded_picks', '/drafts'].map((path) =>
            getJson(`${SLEEPER}league/${leagueId}${path}`),
        ),
    );
    const { league, rosters, users, draft } = anonymise({
        label,
        league: rawLeague,
        rosters: rawRosters,
        users: rawUsers,
        draft: drafts[0],
    });

    const settings = leagueMarketSettings(league);
    const superflex = usesSuperflexValues(settings);
    const [ktc, fc, projections] = await Promise.all([
        getJson(`${BACKEND}api/v1/dynasty-values${superflex ? '' : '?superflex=false'}`),
        getJson(marketValuesUrl(settings)),
        getJson(PROJECTIONS(league.season)),
    ]);

    const rankArgs = {
        league,
        rosters: decorateRosters({ rosterData: rosters, managerData: users }),
        playerInfo: players,
        inputs: {
            ktc,
            fc,
            // roster_id / owner_id here are roster ids, not user ids, so they
            // need no anonymising; the user-id fields are dropped.
            tradedPicks: tradedPicks.map((t) => pick(t, ['season', 'round', 'roster_id', 'owner_id'])),
            projections,
        },
        currentDraftComplete: draft?.status === 'complete',
        draft,
    };
    const rostered = new Set(rosters.flatMap((roster) => (roster.players ?? []).map(String)));
    const trimmed = trim({ rankArgs, rostered });

    const expected = rankLeague(rankArgs);
    if (!isDeepStrictEqual(expected, rankLeague(trimmed))) {
        throw new Error(`${label}: trimming the inputs changed the rankings; not writing`);
    }

    // Rosters are written undecorated, with `users` beside them, so the port
    // resolves display names itself the way the endpoint will have to.
    const { rosters: _decorated, ...rest } = trimmed;
    const fixture = { label, capturedAt: new Date().toISOString(), inputs: { ...rest, rosters, users }, expected };
    const file = join(outDir, `${label}.json`);
    await writeFile(file, JSON.stringify(fixture, null, 1) + '\n');
    console.log(`${label}: ${expected.length} teams -> ${file}`);
}
