const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { smooth } = require('../AudioSpectrum.js');

test('attack follows a beat quickly while release fades more gently', () => {
  const attack = smooth(Array(16).fill(0), Array(16).fill(1));
  const release = smooth(Array(16).fill(1), Array(16).fill(0));
  assert(attack.every(value => value === 0.8));
  assert(release.every(value => value === 0.8));
  assert(attack[0] > 1 - release[0]);
});

test('silence settles to zero without a permanent animation floor', () => {
  let bands = Array(16).fill(1);
  for (let frame = 0; frame < 30; frame++) bands = smooth(bands, Array(16).fill(0));
  assert.deepEqual(bands, Array(16).fill(0));
});

test('frequency bands stay independent and reset safely on initial frames', () => {
  const input = Array(16).fill(0);
  input[4] = 1;
  const output = smooth([], input);
  assert.equal(output[4], 0.8);
  assert(output.every((value, index) => index === 4 || value === 0));
});

const qml = fs.readFileSync(path.join(__dirname, '../BarWidget.qml'), 'utf8');
function handler(name, args, bindings) {
  const start = qml.indexOf(`  function ${name}(`);
  assert(start >= 0);
  const bodyStart = qml.indexOf('{', start) + 1;
  let end = bodyStart, depth = 1;
  for (; depth; end++) {
    if (qml[end] === '{') depth++;
    if (qml[end] === '}') depth--;
  }
  return new Function(...Object.keys(bindings), ...args, qml.slice(bodyStart, end - 1))
    .bind(null, ...Object.values(bindings));
}

test('text toggle persists both off and on, including the right-click path', () => {
  const root = { showText: true };
  const textPreference = { running: false };
  const toggle = handler('toggleTrackText', [], { root, textPreference });
  toggle();
  assert.equal(root.showText, false);
  assert.deepEqual(textPreference.command.slice(3), ['custom.media', 'showText', 'false', '--json']);
  textPreference.running = false;
  toggle();
  assert.equal(textPreference.command[5], 'true');
  assert(qml.includes('property bool showText: setting("showText", true) === true'));
});

test('animation selection persists its mode and requests a repaint', () => {
  const root = {}, animationPreference = { running: false };
  let painted = false;
  handler('selectAnimation', ['mode'], {
    root, animationPreference, waveCanvas: { requestPaint() { painted = true; } }
  })('ribbon');
  assert.equal(root.visualizerMode, 'ribbon');
  assert.deepEqual(animationPreference.command.slice(3), ['custom.media', 'visualizerMode', 'ribbon', '--json']);
  assert(painted);
  assert(qml.includes('setting("visualizerMode", "wave")'));
});
