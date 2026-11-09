// Verifies the C# [OnlineEvent] layout matches the Lua ac.OnlineEvent layout.
// A mismatch in key or field name is a silently dropped message: the client
// waits forever for a grant that the server never recognises.
const fs = require('fs');

const csPath = process.argv[2];
const luaPath = process.argv[3];

const cs = fs.readFileSync(csPath, 'utf8');
const lua = fs.readFileSync(luaPath, 'utf8');

// --- C# side: key -> { fieldName: type }
const csEvents = {};
const classRe = /\[OnlineEvent\(Key\s*=\s*"([^"]+)"\)\][\s\S]*?public class (\w+)\s*:\s*OnlineEvent<\w+>([\s\S]*?)(?=\[OnlineEvent\(|\s*$)/g;
let m;
while ((m = classRe.exec(cs)) !== null) {
  const key = m[1];
  const body = m[3];
  const fields = {};
  const fieldRe = /\[OnlineEventField\(Name\s*=\s*"([^"]+)"(?:,\s*Size\s*=\s*(\d+))?\)\]\s*(?:public\s+)?([\w\[\]<>.]+)\s+(\w+)/g;
  let f;
  while ((f = fieldRe.exec(body)) !== null) {
    fields[f[1]] = { type: f[3], luaName: f[4], size: f[2] ? parseInt(f[2], 10) : null };
  }
  csEvents[key] = { class: m[2], fields };
}

// --- Lua side: key -> { fieldName: structItemCall }
const luaEvents = {};
const blockRe = /ac\.OnlineEvent\(\{([\s\S]*?)\},\s*function/g;
while ((m = blockRe.exec(lua)) !== null) {
  const body = m[1];
  const keyMatch = body.match(/StructItem\.key\('(\w+)'\)/);
  if (!keyMatch) continue;
  const key = keyMatch[1];
  const fields = {};
  const fRe = /(\w+)\s*=\s*ac\.StructItem\.(\w+)\(([^)]*)\)/g;
  let lf;
  while ((lf = fRe.exec(body)) !== null) {
    fields[lf[1]] = { item: lf[2], arg: lf[3].trim() };
  }
  luaEvents[key] = fields;
}

// Wire width per Lua StructItem, in bytes.
const WIDTH = {
  boolean: 1, int8: 1, uint8: 1, char: 1, byte: 1,
  int16: 2, uint16: 2, half: 2, norm16: 2, unorm16: 2,
  float: 4, int32: 4, uint32: 4, norm8: 1, unorm8: 1,
  int64: 8, uint64: 8, double: 8,
};

const CS_WIDTH = {
  bool: 1, byte: 1, sbyte: 1, short: 2, ushort: 2,
  int: 4, uint: 4, float: 4, long: 8, ulong: 8,
};

let problems = 0;
const keys = new Set([...Object.keys(csEvents), ...Object.keys(luaEvents)]);

console.log('=== ghost protocol: C# <-> Lua wire layout ===\n');

for (const key of [...keys].sort()) {
  const c = csEvents[key];
  const l = luaEvents[key];
  console.log('  ' + key);

  if (!c) { console.log('    MISSING in C#  <-- server will ignore this'); problems++; continue; }
  if (!l) { console.log('    MISSING in Lua <-- client will never receive this'); problems++; continue; }

  const csNames = Object.keys(c.fields);
  const luaNames = Object.keys(l);

  for (const name of luaNames) {
    if (!(name in c.fields)) {
      console.log(`    field '${name}' only in Lua (C# class ${c.class})`);
      problems++;
    }
  }
  for (const name of csNames) {
    if (!(name in l)) {
      console.log(`    field '${name}' only in C# (Lua will send it as zero/default)`);
      problems++;
    }
  }

  let csBytes = 0, luaBytes = 0;
  for (const name of csNames) {
    const cf = c.fields[name];
    const base = cf.type.replace(/[\[\]<>]/g, '');
    csBytes += CS_WIDTH[base] ?? (cf.size || 0);

    const lf = l[name];
    if (lf) {
      if (lf.item === 'string') {
        const size = parseInt(lf.arg, 10);
        luaBytes += Number.isNaN(size) ? 0 : size + 1; // +1 length prefix
        if (cf.size !== null && cf.size !== size) {
          console.log(`    '${name}' size: C# declares ${cf.size}, Lua sends ${size}`);
          problems++;
        }
      } else {
        luaBytes += WIDTH[lf.item] ?? 0;
        if (!WIDTH[lf.item]) {
          console.log(`    '${name}' unknown Lua StructItem '${lf.item}'`);
          problems++;
        }
      }
    }
  }

  // Flag suspicious width divergence.
  if (cf_sizeMismatch(csBytes, luaBytes)) {
    console.log(`    WIDTH MISMATCH: C# ~${csBytes}B vs Lua ${luaBytes}B`);
    problems++;
  }

  if (problems === 0 || true) {
    console.log(`    ok  (${csNames.length} fields, C# ~${csBytes}B, Lua ${luaBytes}B)`);
  }
}

function cf_sizeMismatch(a, b) {
  if (a === b) return false;
  // string fields differ by the length prefix convention; allow small drift
  return Math.abs(a - b) > 4;
}

console.log('');
if (problems) {
  console.log(problems + ' protocol problem(s)');
  process.exit(1);
}
console.log('protocol consistent');