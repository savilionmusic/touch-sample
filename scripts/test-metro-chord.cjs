// Pure page check for the METRO, COUNT-IN and SHIFT ? additions on /touch. No browser, network, MIDI or driver connection.
// Runs the page's own METRO / COUNT-IN / SHIFT ? code against stand-ins for act(), sleep() and the DOM, then turns the
// recorded steps into Sample frames with the same rules as vendor/virtual-mpc-sample/panel/server.py frames_for().
const fs = require('fs');
const path = require('node:path');
const vm = require('vm');
const assert = require('node:assert/strict');
const html = fs.readFileSync(path.join(__dirname, '../panel-ext/touch.html'), 'utf8');
const controls = JSON.parse(fs.readFileSync(path.join(__dirname, '../vendor/virtual-mpc-sample/panel/controls.json'), 'utf8')).controls;
const code = html.split('// ---------------------------------------------------------------- METRO, COUNT-IN: SHIFT + one Sample control')[1]
  .split('// ---------------------------------------------------------------- faders (absolute)')[0];

// The new elements must not carry data-name, or the page would also bind them as plain Sample buttons.
for (const id of ['btnMetro', 'btnCountIn', 'btnShiftHelp']) {
  const tag = html.match(new RegExp('<div[^>]*id="' + id + '"[^>]*>'));
  assert.ok(tag, id + ' missing');
  assert.ok(!/data-name|data-bank/.test(tag[0]), id + ' must not be a data-name button');
}
// Existing on-screen buttons are all still there.
for (const n of ['SCREEN 1', 'SCREEN 2', 'SCREEN 3', 'CHOP', 'MUTE', 'LOOP', 'PAD FX', 'MINUS', 'PLUS', 'SAMPLE', 'SEQ', 'SAMPLE SELECT', 'KNOB FX'])
  assert.ok(html.includes('data-name="' + n + '"'), n + ' missing');

class Fake {
  constructor() { this.handlers = {}; this.cls = new Set(); this.classList = {add: c => this.cls.add(c), remove: c => this.cls.delete(c), contains: c => this.cls.has(c)}; }
  addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); }
  fire(type) { for (const fn of this.handlers[type] || []) fn({preventDefault() {}}); }
}
function makePage({failOn} = {}) {
  const els = {}, calls = [], sleeps = [], gates = [];
  const ctx = {
    $: id => els[id] || (els[id] = new Fake()),
    act: (name, action, value) => { if (failOn && failOn(name, action)) throw new Error('act failed'); calls.push([name, action, value]); },
    sleep: ms => { sleeps.push(ms); return new Promise(r => gates.push(r)); },
  };
  vm.runInNewContext(code, ctx);
  const settle = async () => { for (let i = 0; i < 20; i++) { while (gates.length) gates.shift()(); await new Promise(r => setImmediate(r)); } };
  return {els, calls, sleeps, settle};
}
// controls.json frame rules (frames_for): "{id}" and "{value}" fill from the control, tokens are hex bytes.
function frame(name, action, value) {
  const c = controls[name];
  assert.ok(c, 'unknown control ' + name);
  const tpl = c[action];
  assert.ok(tpl, name + ' has no ' + action);
  return tpl.split(' ').map(t => {
    if (!t.startsWith('{')) return parseInt(t, 16);
    const field = t.slice(1, -1), v = field === 'value' ? value : c[field];
    assert.ok(v !== undefined, name + ' ' + action + ' needs ' + field);
    return v & 0x7f;
  }).map(b => b.toString(16).padStart(2, '0')).join(' ');
}
const frames = calls => calls.map(c => frame(...c));

(async () => {
  // METRO: SHIFT down, TAP TEMPO down, TAP TEMPO up, SHIFT up, 30 ms between steps.
  let p = makePage();
  p.els.btnMetro.fire('pointerdown');
  assert.ok(p.els.btnMetro.cls.has('down'));
  await p.settle();
  assert.deepEqual(p.calls, [['SHIFT', 'press', undefined], ['TAP TEMPO', 'press', undefined], ['TAP TEMPO', 'release', undefined], ['SHIFT', 'release', undefined]]);
  assert.deepEqual(frames(p.calls), ['90 31 7f', '90 35 7f', '80 35 00', '80 31 00']);
  assert.deepEqual(p.sleeps, [30, 30, 30]);
  p.els.btnMetro.fire('pointerup');
  assert.ok(!p.els.btnMetro.cls.has('down'));

  // COUNT-IN: SHIFT + pad 4 (pad frames need a velocity).
  p = makePage();
  p.els.btnCountIn.fire('pointerdown');
  await p.settle();
  assert.deepEqual(p.calls, [['SHIFT', 'press', undefined], ['PAD 4', 'press', 127], ['PAD 4', 'release', undefined], ['SHIFT', 'release', undefined]]);
  assert.deepEqual(frames(p.calls), ['90 31 7f', '99 52 7f', '89 52 00', '80 31 00']);

  // A second tap during a chord is ignored (no doubled SHIFT); after it ends the button works again.
  p = makePage();
  p.els.btnMetro.fire('pointerdown'); p.els.btnMetro.fire('pointerdown'); p.els.btnCountIn.fire('pointerdown');
  await p.settle();
  assert.equal(p.calls.length, 4, 'overlapping taps must not interleave');
  p.els.btnMetro.fire('pointerdown');
  await p.settle();
  assert.equal(p.calls.length, 8);

  // SHIFT is always released, even if a step fails.
  p = makePage({failOn: (n, a) => n === 'TAP TEMPO' && a === 'press'});
  p.els.btnMetro.fire('pointerdown');
  await p.settle();
  assert.deepEqual(p.calls, [['SHIFT', 'press', undefined], ['SHIFT', 'release', undefined]]);
  p.els.btnMetro.fire('pointerdown');          // and the chord lock is freed
  await p.settle();
  assert.ok(p.calls.length > 2);

  // SHIFT ?: opens the sheet and sends nothing; a tap anywhere on the sheet closes it.
  p = makePage();
  p.els.btnShiftHelp.fire('pointerdown');
  assert.ok(p.els.shiftSheet.cls.has('on'));
  p.els.btnShiftHelp.fire('pointerup');
  assert.ok(p.els.shiftSheet.cls.has('on'), 'release of the opening tap must not close it');
  p.els.shiftSheet.fire('pointerdown');
  assert.ok(!p.els.shiftSheet.cls.has('on'));
  await p.settle();
  assert.equal(p.calls.length, 0, 'the sheet must not send anything');
  console.log('METRO, COUNT-IN and SHIFT ? checks passed: 90 31 7f, 90 35 7f, 80 35 00, 80 31 00 (METRO); 99 52 7f, 89 52 00 (COUNT-IN pad 4)');
})().catch(e => { console.error(e); process.exit(1); });
