// Original Entry/ETS fixture; finite SDK callbacks are the only event source.
import readline from 'node:readline';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const root = process.env.OHOS_TTS_SOURCE_ROOT;
const { systemTtsFixture } = await import(pathToFileURL(resolve(root, 'runtime/tests/ohos/system-tts-fixture.mjs')).href);
const fixture = systemTtsFixture();
const sdkCallbacks = [];
let sentEvents = 0;

function flushEvents() {
  while (sentEvents < fixture.events.length) {
    const event = fixture.events[sentEvents++];
    if (event.channel === 'dsh/companion_voice') {
      process.stdout.write(JSON.stringify({ event: { type: event.type, id: event.id } }) + '\n');
    }
  }
}
function snapshot() {
  return {
    trace: fixture.trace.slice(), sdkCallbacks: sdkCallbacks.slice(),
    engines: fixture.engines.map(engine => ({
      closed: engine.closed === true, stops: engine.stops, shutdowns: engine.shutdowns,
      calls: engine.calls.map(call => ({ text: call.text, requestId: call.params.requestId,
        queueMode: call.params.extraParams.queueMode })),
    })),
    events: fixture.events.map(event => ({ type: event.type, id: event.id })),
  };
}
async function handle(row) {
  if (row.method === 'voice') return fixture.call(fixture.methods, row.args.method, row.args.arguments ?? {}).done;
  if (row.method === 'snapshot') return snapshot();
  if (row.method === 'sdk') {
    const accepted = fixture.engines.flatMap(engine => engine.calls.map(call => ({ engine, call })));
    const value = accepted[row.args.index];
    if (!Number.isInteger(row.args.index) || !value) throw Error('No accepted request at this index');
    const id = value.call.params.requestId;
    sdkCallbacks.push({ event: row.args.event, requestId: id, text: value.call.text });
    if (row.args.event === 'start') value.engine.start(id);
    else if (row.args.event === 'complete') value.engine.complete(id);
    else if (row.args.event === 'error') value.engine.error(id);
    else throw Error('Unknown finite callback');
    return snapshot();
  }
  if (row.method === 'close') { await fixture.call(fixture.methods, 'stop').done; return snapshot(); }
  throw Error('unknown RPC: ' + row.method);
}

readline.createInterface({ input: process.stdin }).on('line', line => {
  const row = JSON.parse(line);
  Promise.resolve(handle(row)).then(result => {
    flushEvents();
    process.stdout.write(JSON.stringify({ id: row.id, result }) + '\n');
  }, error => process.stdout.write(JSON.stringify({ id: row.id, error: String(error) }) + '\n'));
});
