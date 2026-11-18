// Two finite channel observations; product ETS and production C++ opener are loaded by the fixture.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import test from 'node:test';
import { fixture } from './files-media-fixture.mjs';

function declineVideo(uris, configs) {
  assert.equal(uris.length, 1);
  assert.equal(configs.length, 1);
  assert.equal(configs[0].photoType, 2);
  assert.equal(configs[0].fileNameExtension, 'mp4');
  assert.equal(new URL(uris[0]).protocol, 'file:');
  return []; // User declined to save: successful Promise of [], not a rejection/accepted URI.
}
function publish(row) {
  return cleanup => console.log('VIDEO_SAVE_EMPTY_1392 ' + JSON.stringify({ ...row, cleanup }));
}
function assertSettled(f, snapshot) {
  assert.equal(snapshot.trackedOpenFds.length, 0);
  assert.equal(f.fds.size, 0);
  assert.equal(snapshot.reads, 0);
  assert.equal(snapshot.writes, 0);
  assert.equal(snapshot.opened.length, 0); // No media destination open/copy on cancellation.
}

test('control: nonempty supported local file reaches finite VIDEO cancellation and releases its FD/helper', { timeout: 10000 }, async t => {
  const row = { case: 'nonempty-control', bodyKind: 'nonempty marker bytes, no decoding claim' };
  const f = await fixture(t, { photo: declineVideo, onCleanup: publish(row) });
  const path = await f.file('非空视频.mp4', Buffer.from([1, 2, 3, 4]));
  row.source = { path, bytes: (await fs.stat(path)).size };
  row.reply = await f.call('dsh/media', 'saveVideoFile', { path, name: '非空视频.mp4' });
  row.final = f.snapshot();
  assert.equal(row.reply.error, 'cancelled');
  assert.equal(row.final.helperGets, 1);
  assert.equal(row.final.photos.length, 1);
  assert.deepEqual(row.final.photos[0].uris, [pathToFileURL(path).href]);
  assert.equal(row.final.releases, 1);
  assert.equal(row.final.operations.find(v => v.op === 'user-file-opened').size, 4);
  assertSettled(f, row.final);
  assert.equal(await fs.readFile(f.imageDestination, 'utf8'), 'old');
});

test('target: empty local video is invalid before confirmation; same plugin can then cancel a nonempty save', { timeout: 10000 }, async t => {
  const row = { case: 'empty-then-nonempty', expectedContract: 'ROOT-SCOPE-1392: zero-length invalid before confirmation' };
  const f = await fixture(t, { photo: declineVideo, onCleanup: publish(row) });
  const empty = await f.file('空视频.mp4', Buffer.alloc(0));
  row.emptySource = { path: empty, bytes: (await fs.stat(empty)).size };
  row.emptyReply = await f.call('dsh/media', 'saveVideoFile', { path: empty, name: '空视频.mp4' });
  row.afterEmpty = f.snapshot();
  assertSettled(f, row.afterEmpty);
  assert.equal(row.afterEmpty.operations.find(v => v.op === 'user-file-opened').regular, true);
  assert.equal(row.afterEmpty.operations.find(v => v.op === 'user-file-opened').size, 0);

  // Finish this public follow-up before checking the candidate policy assertion.
  // This exposes retained picking/FD state even when the old empty-source behavior differs.
  const next = await f.file('后续视频.mp4', Buffer.from([5, 6, 7, 8]));
  row.nextReply = await f.call('dsh/media', 'saveVideoFile', { path: next, name: '后续视频.mp4' });
  row.final = f.snapshot();
  assert.equal(row.nextReply.error, 'cancelled');
  assert.equal(row.final.photos.length - row.afterEmpty.photos.length, 1);
  assert.equal(row.final.helperGets - row.afterEmpty.helperGets, 1);
  assert.equal(row.final.releases - row.afterEmpty.releases, 1);
  assertSettled(f, row.final);
  assert.equal(await fs.readFile(f.imageDestination, 'utf8'), 'old');

  assert.equal(row.emptyReply.error, 'invalid');
  assert.equal(row.afterEmpty.helperGets, 0);
  assert.equal(row.afterEmpty.photos.length, 0);
  assert.equal(row.afterEmpty.releases, 0);
});
