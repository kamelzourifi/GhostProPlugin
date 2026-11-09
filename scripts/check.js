// Syntax-only check. CSP runs LuaJIT (5.1 + some 5.2/5.3 sugar), so parse as 5.3
// and separately flag 5.1 hazards that would fail at runtime under LuaJIT.
const fs = require('fs');
const path = require('path');
const luaparse = require('./luaparse.js');

const root = process.argv[2];
const files = process.argv.slice(3);

let failed = 0;
for (const rel of files) {
  const full = path.join(root, rel);
  const src = fs.readFileSync(full, 'utf8');
  const lines = src.split('\n');
  try {
    luaparse.parse(src, { luaVersion: '5.3' });
    console.log('SYNTAX OK   ' + rel);
  } catch (e) {
    failed++;
    const line = e.line || '?';
    console.log('SYNTAX FAIL ' + rel + ' line ' + line + ': ' + e.message);
    if (lines[line - 1] !== undefined) console.log('           > ' + lines[line - 1].trim());
    continue;
  }

  // LuaJIT hazards that parse fine but break at runtime.
  const hazards = [];
  lines.forEach((text, i) => {
    const n = i + 1;
    if (/\bbit32\b/.test(text)) hazards.push(n + ': bit32 is not available in CSP (use & | ~ << >>)');
    if (/\bgoto\b|\b::\w+::/.test(text)) hazards.push(n + ': goto may not be available');
    if (/\bunpack\b/.test(text)) hazards.push(n + ': unpack was removed in 5.2+');
    if (/\bmath\.mod\b/.test(text)) hazards.push(n + ': math.mod was removed');
    if (/\bloadstring\b/.test(text)) hazards.push(n + ': loadstring was removed');
    if (/\bstring\.gfind\b/.test(text)) hazards.push(n + ': string.gfind was removed');
    if (/[^%w]%s*#[^\s!]/.test(text) && !/^%s*--/.test(text)) hazards.push(n + ': stray # outside a length operator');
  });
  if (hazards.length) {
    failed++;
    console.log('  hazards:');
    hazards.forEach(h => console.log('    ' + h));
  }
}

process.exit(failed ? 1 : 0);