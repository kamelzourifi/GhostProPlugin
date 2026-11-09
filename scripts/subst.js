// Simulates GhostProScriptPusher's token substitution, then re-runs the Lua
// checks on the substituted output. The unsubstituted file cannot be validated
// fully: {{WEATHER_NAMES}} is a placeholder that becomes a real Lua table.
const fs = require('fs');
const path = require('path');

const src = fs.readFileSync(process.argv[2], 'utf8');
const out = process.argv[3];

// Same values as a default extra_cfg.yml, plus the real enum names from
// AssettoServer.Shared/Weather/WeatherFxType.cs.
const WEATHER = ['Clear', 'FewClouds', 'ScatteredClouds', 'BrokenClouds', 'OvercastClouds',
  'Fog', 'Mist', 'Rain', 'HeavyRain', 'LightRain', 'Drizzle', 'Snow', 'Hail',
  'Squalls', 'Tornado', 'Thunderstorm', 'HeavyThunderstorm', 'LightThunderstorm',
  'Sand', 'Dust', 'Haze', 'Smoke', 'Wind'];

// split/join, not .replace(): JS replaces only the FIRST match, and every token
// also appears in a comment above its use. C# string.Replace is global, so the
// real plugin is fine — this harness would have silently left the live token.
function replaceAll(text, token, value) {
  return text.split(token).join(value);
}

const substituted = replaceAll(src, '{{ANNOUNCE_INTERVAL}}', '4');
const s2 = replaceAll(substituted, '{{STATE_TTL}}', '14');
const s3 = replaceAll(s2, '{{ALLOW_REMOTE_PAINT}}', 'true');
const s4 = replaceAll(s3, '{{ALLOW_BOTS}}', 'false');
const s5 = replaceAll(s4, '{{PERSONAL_TIME}}', 'true');
const substituted2 = replaceAll(s5, '{{WEATHER_NAMES}}',
  '{' + WEATHER.map(n => `'${n}'`).join(',') + '}');

const leftovers = substituted2.match(/\{\{\w+\}\}/g);
if (leftovers) {
  console.log('UNSUBSTITUTED TOKENS: ' + [...new Set(leftovers)].join(', '));
  process.exit(1);
}

// Create the directory: callers pass a scratch path that may not exist yet, and
// failing here would look like a substitution error rather than a missing dir.
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, substituted2, 'utf8');
console.log('substituted OK -> ' + path.basename(out) +
  ' (' + WEATHER.length + ' weather names, no tokens left)');