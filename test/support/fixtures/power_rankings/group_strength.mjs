// Adds the frontend's position-group strength to each power-rankings fixture,
// as golden data for `Intel.Weakness` (docs/dynasty-engine.md, M2).
//
// `groupStrength` in my-sleeper-app's src/lib/teamComparison.js drives the
// "Starters vs you" bars. It reads the ranked teams' lineups, so it is run
// here over each fixture's `expected` teams - the JS ranking output - for the
// blend and for every source, and written back as `expectedGroupStrength`:
// `{ source: { rosterId: { group: z } } }`.
//
// Run from the repo root, pointing at a my-sleeper-app checkout that still
// has `groupStrength` (anything up to the commit that moves it server-side):
//
//     node test/support/fixtures/power_rankings/group_strength.mjs ~/src/my-sleeper-app

import { readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const [frontendPath] = process.argv.slice(2);
if (!frontendPath) {
    console.error('usage: group_strength.mjs <my-sleeper-app path>');
    process.exit(1);
}

const { groupStrength } = await import(pathToFileURL(resolve(frontendPath, 'src/lib/teamComparison.js')).href);
const dir = dirname(fileURLToPath(import.meta.url));

for (const file of (await readdir(dir)).filter((name) => name.endsWith('.json')).sort()) {
    const path = join(dir, file);
    const fixture = JSON.parse(await readFile(path, 'utf8'));
    const teams = fixture.expected;
    const sources = ['blend', ...Object.keys(teams[0].lineups)];

    fixture.expectedGroupStrength = Object.fromEntries(
        sources.map((source) => [source, Object.fromEntries(groupStrength(teams, source))]),
    );

    await writeFile(path, JSON.stringify(fixture, null, 1) + '\n');
    console.log(`${file}: group strength for ${sources.join(', ')}`);
}
