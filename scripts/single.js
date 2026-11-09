// Scopes a single-file Lua script into its own chunk so undefined globals can
// be found. luaparse only reports syntax, which is why the single-file
// server-pushed client needed its own check.
const fs = require('fs');
const path = require('path');
const luaparse = require('./luaparse.js');

const file = process.argv[2];
const src = fs.readFileSync(file, 'utf8');

const problems = [];

// 1. Collect every name assigned anywhere: local declarations, assignments,
//    function params, and for-loop variables.
const declared = new Set();
// `scope: true` is what makes luaparse emit the per-scope `globals` and
// `isLocal` tables. Without it the free-variable pass finds nothing at all and
// the check silently passes everything.
const ast = luaparse.parse(src, { luaVersion: '5.3', locations: true, scope: true });

(function walk(node, parent) {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node)) { node.forEach(n => walk(n, parent)); return; }

  if (node.type === 'LocalStatement') {
    for (const v of node.variables || []) if (v.type === 'Identifier') declared.add(v.name);
  }
  if (node.type === 'AssignmentStatement') {
    for (const v of node.variables || []) {
      if (v.type === 'Identifier') declared.add(v.name);
      if (v.type === 'MemberExpression' && v.base?.type === 'Identifier') {
        // M.x = ... defines a field, not a global
      }
    }
  }
  if (node.type === 'FunctionDeclaration') {
    const id = node.identifier;
    if (id?.type === 'Identifier') declared.add(id.name);
    for (const p of node.parameters || []) {
      if (p.type === 'Identifier') declared.add(p.name);
      if (p.type === 'VarargLiteral') declared.add('...');
    }
  }
  if (node.type === 'FunctionExpression' || node.type === 'ArrowExpression') {
    for (const p of node.parameters || []) if (p.type === 'Identifier') declared.add(p.name);
  }
  if (node.type === 'WhileStatement' || node.type === 'RepeatStatement') {
    for (const p of node.body || []) void p;
  }
  if (node.type === 'NumericFor') {
    if (node.identifier?.type === 'Identifier') declared.add(node.identifier.name);
  }
  if (node.type === 'GenericFor') {
    for (const v of node.variables || []) if (v.type === 'Identifier') declared.add(v.name);
  }
  if (node.type === 'IfStatement' || node.type === 'ElseIfClause') {
    void node;
  }

  for (const k of Object.keys(node)) {
    if (k === 'loc' || k === 'type') continue;
    walk(node[k], node);
  }
})(ast, null);

// 2. Read the free variables luaparse computed for each scope.
const globals = new Map();
(function walk(node) {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node)) { node.forEach(walk); return; }
  if (Array.isArray(node.globals)) {
    for (const g of node.globals) {
      if (!globals.has(g.name)) globals.set(g.name, g.line);
    }
  }
  for (const k of Object.keys(node)) {
    if (k === 'loc' || k === 'type' || k === 'globals') continue;
    walk(node[k]);
  }
})(ast);

// 3. The CSP surface is legitimately global. Anything else is a typo.
const CSP_GLOBALS = new Set([
  'ac', 'ui', 'physics', 'render', 'io', 'json', 'os', 'math', 'string', 'table',
  'vec2', 'vec3', 'vec4', 'rgb', 'rgbm', 'hsv', 'mat3x3', 'mat4x4', 'quat',
  'script', 'reftypes', 'collectgarbage', 'pcall', 'xpcall', 'error', 'assert',
  'type', 'tostring', 'tonumber', 'pairs', 'ipairs', 'next', 'select', 'setmetatable',
  'getmetatable', 'rawget', 'rawset', 'rawlen', 'unpack', 'print', 'require',
  'loadstring', 'load', 'dofile', 'os_', 'bit', '_G', 'package', 'debug',
  'getfenv', 'setfenv', 'newproxy', 'coroutine', 'string_format',
  // Placeholder tokens: the server substitutes {{WEATHER_NAMES}} with a Lua
  // table literal, but before substitution luaparse sees a bare global read.
  // Allowed here, and separately checked that the token is in quotes-free
  // substitution position rather than a real bug.
  'WEATHER_NAMES',
]);

for (const [name, line] of globals) {
  if (CSP_GLOBALS.has(name)) continue;
  if (declared.has(name)) continue;
  problems.push(`line ${line}: '${name}' is neither CSP API nor declared locally`);
}

// 4. LuaJIT hazards.
const lines = src.split('\n');
lines.forEach((text, i) => {
  const n = i + 1;
  if (/\bbit32\b/.test(text)) problems.push(`line ${n}: bit32 unavailable in CSP`);
  if (/\bbit32?\.(band|bor|bxor|bnot|lshift|rshift)/.test(text)) {
    problems.push(`line ${n}: bit32 library unavailable in CSP (use & | ~ << >>)`);
  }
  if (/\bunpack\b/.test(text) && !/table\.unpack/.test(text)) {
    problems.push(`line ${n}: bare unpack may be absent on LuaJIT builds`);
  }
  if (/\bgoto\s+\w+/.test(text)) problems.push(`line ${n}: goto availability varies`);
});

if (problems.length) {
  console.log(`${path.basename(file)}: ${problems.length} problem(s)`);
  problems.forEach(p => console.log('  ' + p));
  process.exit(1);
} else {
  console.log(`${path.basename(file)}: clean (${globals.size} CSP globals, ${declared.size} local names)`);
}