// Runs every static check in this folder against the plugin sources.
//
//   node scripts/verify.js [path-to-src]
//
// Why these exist: the plugin is two languages whose contract is invisible to
// either compiler. The C# [OnlineEventField] names must match the Lua
// ac.StructItem names exactly, and a mismatch is a silently dropped message —
// the client waits for a grant the server never sends. `dotnet build` cannot see
// that, and luaparse cannot see C#.
//
// Each checker was itself verified against a deliberately broken fixture.
const path = require('path');
const { execFileSync } = require('child_process');

const src = process.argv[2] || path.join(__dirname, '..', 'src');
const plugin = path.join(src, 'GhostProPlugin');
const lua = path.join(plugin, 'lua', 'ghostpro.lua');
const packets = path.join(plugin, 'Packets', 'GhostProPackets.cs');

const steps = [
  {
    name: 'lua syntax (as authored)',
    cmd: [path.join(__dirname, 'check.js'), plugin, 'lua/ghostpro.lua'],
  },
  {
    name: 'lua free variables (as authored)',
    cmd: [path.join(__dirname, 'single.js'), lua],
  },
  {
    // The substituted copy is what actually ships. Checking only the raw file
    // would miss a token that expands into broken Lua.
    name: 'lua after server substitution',
    cmd: [path.join(__dirname, 'subst.js'), lua, path.join(__dirname, '..', '.verify', 'substituted.lua')],
    then: [
      [path.join(__dirname, 'check.js'), path.join(__dirname, '..', '.verify'), 'substituted.lua'],
      [path.join(__dirname, 'single.js'), path.join(__dirname, '..', '.verify', 'substituted.lua')],
      [path.join(__dirname, 'proto.js'), packets, path.join(__dirname, '..', '.verify', 'substituted.lua')],
    ],
  },
  { name: 'C# structure', cmd: [path.join(__dirname, 'csstruct.js'), plugin] },
  { name: 'C# delimiter balance', cmd: [path.join(__dirname, 'csbalance.js'), packets] },
];

let failed = 0;

for (const step of steps) {
  console.log('== ' + step.name);
  try {
    const out = execFileSync(process.execPath, step.cmd, { encoding: 'utf8' });
    process.stdout.write(out.split('\n').map(l => (l ? '   ' + l : l)).join('\n'));
    for (const nested of step.then || []) {
      const nestedOut = execFileSync(process.execPath, nested, { encoding: 'utf8' });
      process.stdout.write(nestedOut.split('\n').map(l => (l ? '   ' + l : l)).join('\n'));
    }
  } catch (e) {
    failed++;
    process.stdout.write((e.stdout || '') + (e.stderr || ''));
  }
  console.log('');
}

console.log(failed ? failed + ' check group(s) FAILED' : 'all checks passed');
process.exit(failed ? 1 : 0);