// Pure page interaction check. No browser, network, MIDI or driver connection.
const fs = require('fs');
const vm = require('vm');
const assert = require('node:assert/strict');
const html = fs.readFileSync(new URL('../panel-ext/touch.html', `file://${__filename}`), 'utf8');
new vm.Script(html.match(/<script>([\s\S]*)<\/script>/)[1]);
const worker = html.split('const AUDIO_WORKER = `')[1].split('`;')[0];
new vm.Script(worker);
assert.ok(!worker.includes('startAudio'), 'Worker must not call page-only audio setup');
const code = html.split('// ---------------------------------------------------------------- direct touches from the installed macOS driver')[1].split('// ---------------------------------------------------------------- /touchui:')[0];
const events = [];
const target = {dispatchEvent: e => events.push(e)};
let audioStarts = 0;
const context = {window: {}, document: {elementFromPoint: (x, y) => x >= 0 && y >= 0 ? target : null}, PointerEvent: class {constructor(type, fields) {Object.assign(this, {type}, fields)}}, startAudio: () => audioStarts++};
vm.runInNewContext(code, context);
const touch = context.window.touchSampleDirect;
touch(1, 1000, 100); touch(2, -10, 200); touch(3, -10, 200);
assert.deepEqual(events.map(e => e.type), ['pointerdown','pointermove','pointerup']);
assert.deepEqual(events.map(e => e.buttons), [1,1,0]);
assert.equal(events[1].clientX, -10); // Drag and release still go to the held control.
events.length = 0;
touch(1,100,100); touch(1,200,200); touch(3,200,200);
assert.deepEqual(events.map(e => e.type), ['pointerdown','pointercancel','pointerdown','pointerup']);
events.length = 0;
touch(2,100,100); touch(3,100,100); touch(1,NaN,100); touch(4,100,100);
assert.equal(events.length,0);
assert.equal(audioStarts,3);
console.log('Direct touch hold, drag, release, cancellation and invalid-packet checks passed');
