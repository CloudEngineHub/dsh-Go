// 1391 finite policy target: actual frozen Entry/SpeechPlugin/CompanionVoicePlugin/lane.
// HMS Engine, the whole OhosPcmStream Backend and Flutter embedding are finite boundaries.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import readline from 'node:readline';
import { systemTtsFixture, deferred } from './read-aloud-pending-preview-fixture.mjs';
const fixture = systemTtsFixture();
const accepted = new Map();
const operations = [];
let seq = 0, sentEvents = 0;
let createGate = null;
let createReleased = false;
const mark = (kind, detail = {}) => operations.push({seq: ++seq, kind, ...detail});
function eventRow(event, index) {
  const {channel, method, messenger, ...args} = event;
  return {index, channel, method, args, messenger};
}
function flushEvents() {
  while (sentEvents < fixture.events.length) {
    const row = eventRow(fixture.events[sentEvents], sentEvents);
    sentEvents++;
    // Preserve every event argument, including type/what/id/start/end/value.
    process.stdout.write(JSON.stringify({event: row}) + '\n');
  }
}
function snapshot() {
  return {
    trace: fixture.trace.slice(), operations: operations.slice(),
    createDeferred: createGate !== null, createReleased,
    events: fixture.events.map(eventRow),
    engines: fixture.engines.map(engine => ({closed: engine.closed === true,
      stops: engine.stops, shutdowns: engine.shutdowns,
      calls: engine.calls.map(call => ({text: call.text, params: call.params}))})),
    streams: fixture.streams.map((stream, index) => ({index, config: stream.config,
      opened: stream.opened === true, closed: stream.closed === true,
      current: stream.current(),
      ids: [...accepted].filter(([, value]) => value.stream === stream).map(([id]) => id)})),
    accepted: [...accepted].map(([id, value]) => ({id, streamIndex: fixture.streams.indexOf(value.stream),
      writes: value.writes, endAccepted: value.endAccepted, callbackStarted: value.started,
      callbackDone: value.done})),
  };
}
async function channelCall(which, method, originalArgs = {}) {
  const args = {...(originalArgs ?? {})};
  if (which === 'audio' && method === 'write') {
    assert(Array.isArray(args.bytes), 'RPC write carries an explicit JSON byte array');
    args.bytes = Uint8Array.from(args.bytes);
  }
  mark('method-start', {channel: which, method, args: originalArgs});
  const reply = await fixture.call(which === 'voice' ? fixture.methods : fixture.pcm, method, args).done;
  mark('native-reply-computed', {channel: which, method, reply});
  if (which === 'audio' && method === 'open' && reply.value === true) {
    const stream = fixture.streams.at(-1);
    assert(stream?.opened && stream.current(), 'Accepted actual plugin stream');
    accepted.set(args.id, {stream, writes: [], endAccepted: false, started: false, done: false});
  }
  if (which === 'audio' && method === 'write' && typeof reply.value === 'number' && reply.value >= 0) {
    assert(accepted.has(args.id), 'Actual write must belong to an accepted stream');
    accepted.get(args.id).writes.push({bytes: [...args.bytes], byteLength: args.bytes.byteLength,
      sha256: createHash('sha256').update(args.bytes).digest('hex'), result: reply.value});
  }
  if (which === 'audio' && method === 'end' && !reply.error && !reply.missing) {
    assert(accepted.has(args.id), 'Actual end must belong to an accepted stream');
    accepted.get(args.id).endAccepted = true;
  }
  return reply;
}
async function handle(row) {
  if (row.method === 'configure') {
    assert(operations.length === 0 && fixture.engines.length === 0 && fixture.streams.length === 0,
      'Configure finite SDK boundaries before any product call');
    if (row.args.createDeferred) createGate = deferred();
    fixture.change({createError: row.args.createError === true,
      pcmOpenReject: row.args.pcmOpenReject === true,
      ...(createGate ? {create: () => createGate.promise} : {})});
    mark('finite-boundary-configured', row.args);
    return snapshot();
  }
  if (row.method === 'release-create') {
    assert(createGate && !createReleased, 'Release the one actual SDK create promise once');
    createReleased = true; mark('finite-sdk-create-release'); createGate.resolve();
    return snapshot();
  }
  if (row.method === 'voice' || row.method === 'audio') {
    return channelCall(row.method, row.args.method, row.args.arguments);
  }
  if (row.method === 'snapshot') return snapshot();
  if (row.method === 'pcm-sdk') {
    const item = accepted.get(row.args.id);
    assert(item && item.stream.opened && !item.stream.closed && item.stream.current(),
      'Finite Backend callback only for this accepted, current, unretired stream');
    if (row.args.event === 'start') {
      assert(!item.started && item.writes.length > 0, 'Start after actual accepted write, once');
      item.started = true;
      mark('finite-pcm-backend-callback', {id: row.args.id, event: 'start'});
      item.stream.listener.started();
    } else if (row.args.event === 'done') {
      assert(item.endAccepted && !item.done, 'Done only after actual end, once');
      item.done = true;
      mark('finite-pcm-backend-callback', {id: row.args.id, event: 'done'});
      item.stream.listener.terminal('done', '');
    } else throw Error('Unknown finite PCM callback');
    return snapshot();
  }
  if (row.method === 'tts-sdk') {
    const engine = fixture.engines.findLast(value => value.calls.some(call => call.text === row.args.text));
    assert(engine && !engine.closed, 'A real SDK speak must already be accepted');
    const call = engine.calls.findLast(value => value.text === row.args.text);
    mark('finite-tts-sdk-callback', {text: call.text, requestId: call.params.requestId, event: row.args.event});
    if (row.args.event === 'start') engine.start(call.params.requestId);
    else if (row.args.event === 'done') engine.complete(call.params.requestId);
    else throw Error('Unknown finite TTS callback');
    return snapshot();
  }
  if (row.method === 'close') {
    mark('research-cleanup-start');
    if (createGate && !createReleased) {
      createReleased = true; mark('cleanup-sdk-create-release'); createGate.resolve();
    }
    await channelCall('voice', 'stop');
    await channelCall('audio', 'stop');
    mark('research-cleanup-completed');
    return snapshot();
  }
  throw Error('Unknown RPC: ' + row.method);
}
readline.createInterface({input: process.stdin}).on('line', line => {
  const row = JSON.parse(line);
  Promise.resolve(handle(row)).then(result => {
    flushEvents();
    process.stdout.write(JSON.stringify({id: row.id, result}) + '\n');
  }, error => {
    flushEvents();
    process.stdout.write(JSON.stringify({id: row.id, error: String(error), stack: error.stack}) + '\n');
  });
});
