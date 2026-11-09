// Counts delimiters with a proper C# lexer state machine. Used to locate an
// imbalance in a file that cannot be compiled locally.
const fs = require('fs');

const src = fs.readFileSync(process.argv[2], 'utf8');

let out = '';
let i = 0;
const trace = [];

function isVerbatimStart(str, idx) {
  return str[idx] === '$' && str[idx + 1] === '"';
}

while (i < src.length) {
  const c = src[i];
  const n = src[i + 1];

  // line comment
  if (c === '/' && n === '/') {
    while (i < src.length && src[i] !== '\n') i++;
    continue;
  }
  // block comment
  if (c === '/' && n === '*') {
    i += 2;
    while (i < src.length && !(src[i] === '*' && src[i + 1] === '/')) i++;
    i += 2;
    continue;
  }
  // verbatim interpolated string $@"..." or @$"..."
  if (isVerbatimStart(src, i)) {
    let j = i + 2;
    while (j < src.length) {
      if (src[j] === '"') {
        if (src[j + 1] === '"') { j += 2; continue; }
        break;
      }
      j++;
    }
    trace.push({ kind: 'verbstring', from: i, to: j });
    i = j + 1;
    continue;
  }
  // regular string
  if (c === '"') {
    let j = i + 1;
    while (j < src.length) {
      if (src[j] === '\\') { j += 2; continue; }
      if (src[j] === '"') break;
      j++;
    }
    trace.push({ kind: 'string', from: i, to: j });
    i = j + 1;
    continue;
  }
  // char literal
  if (c === "'") {
    let j = i + 1;
    while (j < src.length) {
      if (src[j] === '\\') { j += 2; continue; }
      if (src[j] === "'") break;
      j++;
    }
    i = j + 1;
    continue;
  }

  if (c === '{' || c === '}' || c === '(' || c === ')' || c === '[' || c === ']') {
    out += c;
    trace.push({ kind: c, at: i });
  } else {
    out += c;
  }
  i++;
}

function count(ch) {
  return out.split(ch).length - 1;
}

function lineOf(offset) {
  return src.slice(0, offset).split('\n').length;
}

const pairs = [['{', '}'], ['(', ')'], ['[', ']']];
let bad = 0;
for (const [open, close] of pairs) {
  const a = count(open), b = count(close);
  const status = a === b ? 'ok  ' : 'BAD ';
  if (a !== b) bad++;
  console.log(`${status} '${open}' ${a}  '${close}' ${b}`);
  if (a !== b) {
    // Walk the trace to find where the nesting first goes negative.
    let depth = 0;
    for (const t of trace) {
      if (t.kind === open) depth++;
      else if (t.kind === close) {
        depth--;
        if (depth < 0) {
          console.log(`     first '${close}' with nothing open at line ${lineOf(t.at)}`);
          console.log(`     >>> ${src.split('\n')[lineOf(t.at) - 1].trim()}`);
          break;
        }
      }
    }
  }
}

process.exit(bad ? 1 : 0);