// Actual frozen fixture and ETS. Only the existing HMS SDK and Flutter
// embedding boundaries are substituted; the test does not call a real service.
import readline from 'node:readline';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
const root = process.env.OHOS_TTS_SOURCE_ROOT;
const { systemTtsFixture } = await import(pathToFileURL(resolve(root, 'runtime/tests/ohos/system-tts-fixture.mjs')).href);
const fixture = systemTtsFixture();
let sentEvents = 0;
function flushEvents() {
  while (sentEvents < fixture.events.length) {
    const event = fixture.events[sentEvents++];
    if (event.channel === 'dsh/companion_voice') {
      process.stdout.write(JSON.stringify({event: {type: event.type, id: event.id}}) + '\n');
    }
  }
}
function snapshot() {
  return { trace: fixture.trace.slice(), engines: fixture.engines.map(engine => ({
    closed: engine.closed === true, stops: engine.stops, shutdowns: engine.shutdowns,
    calls: engine.calls.map(call => ({text: call.text, requestId: call.params.requestId,
      queueMode: call.params.extraParams.queueMode}))
  })), events: fixture.events.map(event => ({type: event.type, id: event.id})) };
}
async function handle(row) {
  if (row.method === 'voice') return fixture.call(fixture.methods, row.args.method, row.args.arguments ?? {}).done;
  if (row.method === 'audio') {
    const args = { ...(row.args.arguments ?? {}) };
    // JSON transport cannot carry the real MethodChannel's Uint8List type.
    // Reconstruct only this declared byte boundary before the actual plugin.
    if (row.args.method === 'write' && Array.isArray(args.bytes)) args.bytes = Uint8Array.from(args.bytes);
    return fixture.call(fixture.pcm, row.args.method, args).done;
  }
  if (row.method === 'snapshot') return snapshot();
  if (row.method === 'availability') {
    fixture.change({createError: row.args.unavailable === true});
    return null;
  }
  if (row.method === 'sdk') {
    const engine = fixture.engines.findLast(value => value.calls.some(call => call.text === row.args.text));
    if (!engine) throw Error('No accepted SDK request for requested text');
    const call = engine.calls.findLast(value => value.text === row.args.text);
    if (row.args.event === 'start') engine.start(call.params.requestId);
    else if (row.args.event === 'complete') engine.complete(call.params.requestId);
    else throw Error('Unknown finite SDK event');
    return snapshot();
  }
  if (row.method === 'close') { await fixture.call(fixture.methods, 'stop').done; return snapshot(); }
  throw Error('unknown RPC: ' + row.method);
}
readline.createInterface({input: process.stdin}).on('line', line => {
  const row = JSON.parse(line);
  Promise.resolve(handle(row)).then(result => {
    flushEvents();
    process.stdout.write(JSON.stringify({id: row.id, result}) + '\n');
  }, error => process.stdout.write(JSON.stringify({id: row.id, error: String(error)}) + '\n'));
});
