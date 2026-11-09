// Structural sanity for C# that cannot be compiled here (no net9 SDK, and the
// AssettoServer project references are not present). Catches unbalanced braces,
// unterminated strings, and using-directives that reference nothing we know of.
const fs = require('fs');
const path = require('path');

const dir = process.argv[2];
const files = fs.readdirSync(dir).filter(f => f.endsWith('.cs'));

const KNOWN_NS = [
  'AssettoServer', 'AssettoServer.Server', 'AssettoServer.Server.Configuration',
  'AssettoServer.Server.Plugin', 'AssettoServer.Server.Weather',
  'AssettoServer.Shared.Network.Packets.Outgoing', 'AssettoServer.Shared.Weather',
  'AssettoServer.Network.Tcp', 'AssettoServer.Network.ClientMessages',
  'Autofac', 'Microsoft.Extensions.Hosting', 'Serilog', 'System',
  'System.Collections.Generic', 'System.Linq', 'System.Reflection', 'System.Threading',
  'System.Threading.Tasks', 'YamlDotNet.Serialization', 'JetBrains.Annotations',
  'NodaTime',
  // Own namespaces, defined in this project.
  'GhostProPlugin', 'GhostProPlugin.Packets',
];

let problems = 0;

for (const file of files) {
  const full = path.join(dir, file);
  const src = fs.readFileSync(full, 'utf8');
  const issues = [];

  // Strip strings and comments before counting delimiters.
  let stripped = '';
  let i = 0;
  let inLine = false, inBlock = false, inStr = false, inVerb = false;
  while (i < src.length) {
    const c = src[i], next = src[i + 1];
    if (inLine) { if (c === '\n') { inLine = false; stripped += c; } i++; continue; }
    if (inBlock) { if (c === '*' && next === '/') { inBlock = false; i += 2; } else i++; continue; }
    if (inVerb) { if (c === '"' && src[i - 1] !== '\\') { inVerb = false; i++; } else i++; continue; }
    if (inStr) {
      if (c === '\\') { i += 2; continue; }
      if (c === '"') { inStr = false; i++; continue; }
      i++; continue;
    }
    if (c === '/' && next === '/') { inLine = true; i += 2; continue; }
    if (c === '/' && next === '*') { inBlock = true; i += 2; continue; }
    if (c === '$' && next === '"') { inVerb = true; i += 2; continue; }
    if (c === '"') { inStr = true; i++; continue; }
    stripped += c;
    i++;
  }

  if (inStr || inVerb) issues.push('unterminated string literal');
  if (inBlock) issues.push('unterminated block comment');

  const count = ch => (stripped.match(new RegExp('\\' + ch, 'g')) || []).length;
  for (const [open, close, label] of [['{', '}', 'brace'], ['(', ')', 'paren'], ['[', ']', 'bracket']]) {
    const a = count(open), b = count(close);
    if (a !== b) issues.push(`${label} imbalance: ${a} '${open}' vs ${b} '${close}'`);
  }

  // using directives we cannot account for
  const usingRe = /^\s*using\s+([\w.]+)\s*;/gm;
  let u;
  while ((u = usingRe.exec(src)) !== null) {
    const ns = u[1];
    if (!KNOWN_NS.some(k => ns === k || ns.startsWith(k + '.'))) {
      issues.push(`unknown namespace '${ns}' — cannot verify it exists in AssettoServer`);
    }
  }

  // placeholder markers that must not survive into a release build
  if (/\bTODO\b|\bFIXME\b|\bNotImplementedException\b/.test(stripped)) {
    issues.push('contains TODO/FIXME/NotImplementedException');
  }

  console.log((issues.length ? 'FAIL  ' : 'ok    ') + file);
  issues.forEach(x => { console.log('        ' + x); problems++; });
}

console.log('');
if (problems) { console.log(problems + ' issue(s)'); process.exit(1); }
console.log('structure ok (NOT compiled — net9 SDK and AssettoServer refs absent)');