// Actual product ETS after TypeScript erasure, real Linux files and the production
// C++ descriptor opener. Flutter, picker and album services are explicit doubles.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';
import test from 'node:test';
import vm from 'node:vm';

assert(process.env.OHOS_TYPESCRIPT_PREFIX, 'Set OHOS_TYPESCRIPT_PREFIX to the locked process npm-ci directory');
assert(process.env.OHOS_USER_FILE_ADDON, 'Build user-file-access-addon.cc and set OHOS_USER_FILE_ADDON');
const require = createRequire(import.meta.url);
const native = require(resolve(process.env.OHOS_USER_FILE_ADDON));
const ts = createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX, 'package.json'))('typescript');
const sourceRoot = process.env.OHOS_VIDEO_SAVE_SOURCE_ROOT;
assert(sourceRoot, 'Frozen product source root is required');
const source = fs.readFileSync(resolve(sourceRoot, 'app/ohos/entry/src/main/ets/plugins/FilesMediaPlugin.ets'), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
} });
const pathModule = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(resolve(sourceRoot,
  'app/ohos/entry/src/main/ets/runtime/RuntimePaths.ets'), 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
}).outputText, { module: pathModule, exports: pathModule.exports });
const { RuntimePaths } = pathModule.exports;
const plain = value => Object.prototype.toString.call(value) === '[object Map]'
  ? Object.fromEntries([...value].map(([k, v]) => [k, plain(v)]))
  : Array.isArray(value) ? Array.from(value, plain) : value;
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };

export async function fixture(t, options = {}) {
  const root = await fsp.mkdtemp(join(tmpdir(), 'dsh-files-'));
  const context = { filesDir: join(root, 'files'), cacheDir: join(root, 'cache'), tempDir: join(root, 'temp') };
  const paths = new RuntimePaths(context.filesDir);
  const workspace = paths.workspace;
  for (const path of [workspace, context.cacheDir, context.tempDir, join(root, 'selected'), join(root, 'album')]) {
    await fsp.mkdir(path, { recursive: true });
  }
  const channels = [], starts = [], dialogs = [], photos = [], warnings = [], fds = new Set(), opened = [];
  const operations = []; let helperGets = 0;
  const record = (op, fields = {}) => operations.push({ seq: operations.length + 1, op, ...fields });
  const snapshot = () => ({ operations: operations.slice(), photos: photos.slice(), helperGets,
    releases, reads, writes, opened: opened.slice(), trackedOpenFds: [...fds] });
  const documentOpened = deferred(), photoOpened = deferred();
  const destination = join(root, 'selected', '导出.bin'), imageDestination = join(root, 'album', '图片.bin');
  await fsp.writeFile(destination, 'old'); await fsp.writeFile(imageDestination, 'old');
  let releases = 0, reads = 0, writes = 0;
  const mapped = path => path === 'content://picker/one' ? destination : path === 'file://media/one' ? imageDestination : path;
  const fdOf = file => typeof file === 'number' ? file : file.fd;
  const stat = value => ({
    size: value.size, mtime: Math.floor(value.mtimeMs / 1000),
    isDirectory: () => value.isDirectory(), isSymbolicLink: () => value.isSymbolicLink(), isFile: () => value.isFile(),
  });
  const api = {
    OpenMode: {
      READ_WRITE: fs.constants.O_RDWR, CREATE: fs.constants.O_CREAT,
      TRUNC: fs.constants.O_TRUNC, NOFOLLOW: fs.constants.O_NOFOLLOW,
    },
    async mkdir(path) { try { await fsp.mkdir(path); } catch (error) { if (error.code === 'EEXIST') error.code = 13900015; throw error; } },
    async mkdtemp(template) {
      assert(template.endsWith('XXXXXX'), 'OH uv_fs_mkdtemp requires six terminal X characters');
      if (options.mkdtempFail) throw new Error('simulated directory allocation failure');
      const path = await fsp.mkdtemp(template.slice(0, -6));
      if (options.afterMkdtemp) await options.afterMkdtemp(path);
      return path;
    },
    async lstat(path) { return stat(await fsp.lstat(path)); },
    async stat(path) {
      const value = typeof path === 'number' ? await promisify(fs.fstat)(path) : await fsp.stat(mapped(path));
      record('fs-stat', { path, size: value.size, regular: value.isFile() }); return stat(value);
    },
    async access(path) { try { await fsp.access(path); return true; } catch { return false; } },
    listFile: path => fsp.readdir(path),
    async open(path, mode) {
      const fd = await promisify(fs.open)(mapped(path), mode, 0o600);
      fds.add(fd); opened.push(path); record('fs-open', { path, fd }); return { fd, path };
    },
    async close(file) { const fd = fdOf(file); await promisify(fs.close)(fd); fds.delete(fd); record('fs-close', { fd }); },
    async read(fd, buffer, opts) {
      reads++;
      if (options.beforeRead) await options.beforeRead({ fd, reads, plugin, context, workspace });
      if (options.zeroRead) return 0;
      const length = Math.min(opts.length, options.maxRead ?? Infinity);
      return (await promisify(fs.read)(fd, Buffer.from(buffer), 0, length, opts.offset)).bytesRead;
    },
    async write(fd, buffer, opts) {
      writes++;
      if (options.beforeWrite) await options.beforeWrite({ fd, writes, plugin, context, workspace });
      if (options.zeroWrite) return 0;
      const length = Math.min(buffer.byteLength, options.maxWrite ?? Infinity);
      return (await promisify(fs.write)(fd, Buffer.from(buffer), 0, length, opts.offset)).bytesWritten;
    },
    fsync: fd => promisify(fs.fsync)(fd), rename: fsp.rename, unlink: fsp.unlink,
    // Public OH rmdir recursively removes contents; Node rmdir does not.
    rmdir: path => fsp.rm(path, { recursive: true }),
  };
  class Channel {
    constructor(_messenger, name) { this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
  }
  const module = { exports: {} };
  vm.runInNewContext(compiled.outputText, {
    module, exports: module.exports, ArrayBuffer, Uint8Array,
    require(name) {
      if (name === '@ohos.file.fs') return { default: api };
      if (name === '@ohos.file.picker') return { default: { DocumentViewPicker: class {
        async save(args) { dialogs.push(args); documentOpened.resolve(); return options.pick ? await options.pick(args) : ['content://picker/one']; }
      } } };
      if (name === '@ohos.file.fileuri') return { default: { getUriFromPath: path => pathToFileURL(path).href } };
      if (name === '@ohos.file.photoAccessHelper') return { default: {
        // Official PhotoType values and [] cancellation are bound in API-SOURCES.json.
        // This is a finite platform boundary, not an installed PhotoAccessHelper.
        PhotoType: { IMAGE: 1, VIDEO: 2 }, getPhotoAccessHelper: () => {
          helperGets++; record('photo-helper-get');
          return {
            async showAssetsCreationDialog(uris, configs) {
              const request = { uris: Array.from(uris), configs: JSON.parse(JSON.stringify(configs)) };
              photos.push(request); record('photo-confirmation-called', request);
              photoOpened.resolve();
              const answer = options.photo ? await options.photo(uris, configs) : [];
              record('photo-confirmation-returned', { uris: Array.from(answer) }); return answer;
            },
            async release() { releases++; record('photo-helper-release'); },
          };
        },
      } };
      if (name === '@ohos.app.ability.wantConstant') return { default: { Flags: { FLAG_AUTH_READ_URI_PERMISSION: 1 } } };
      if (name === '@ohos.security.cryptoFramework') return { default: { createMd: algorithm => {
        assert.equal(algorithm, 'SHA256'); const hash = createHash('sha256');
        return { async update({ data }) { hash.update(data); }, async digest() { return { data: hash.digest() }; } };
      } } };
      if (name === '@ohos.util') return { default: {
        generateRandomUUID: randomUUID,
        TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
      } };
      if (name === '@ohos.hilog') return { default: { warn: (...args) => warnings.push(args) } };
      if (name === '../runtime/NativeHost') return { async loadNativeHost() {
        if (options.beforeNativeLoad) await options.beforeNativeLoad();
        return { openUserFile(root, relative) {
          const fd = native.openUserFile(root, relative); fds.add(fd);
          const info = fs.fstatSync(fd);
          record('user-file-opened', { root, relative, fd, regular: info.isFile(), size: info.size }); return fd;
        } };
      } };
      if (name === '@ohos/flutter_ohos') return { MethodChannel: Channel };
      // PDF page behaviour has its own suite, files-pdf-channel.test.mjs.
      if (name === './HmsPdfPages') return { HmsPdfPages: class { async close() {} } };
      if (name === './PdfInput') return { PdfChannelError: class extends Error { constructor(code, message) { super(message); this.code = code; } } };
      // The controller's path derivation is actual product code. Its native
      // lifecycle is independently exercised by runtime-channel.test.mjs.
      if (name === '../runtime/RuntimeController') return { RuntimeController: {
        get(actual) { assert.equal(actual, context); return { paths }; },
      } };
      throw new Error(`Unexpected runtime import ${name}`);
    },
  });
  const engine = { getApplicationContext: () => context, getBinaryMessenger: () => ({}) };
  const ability = { context: { ...context, async startAbility(want) {
    starts.push(JSON.parse(JSON.stringify(want))); if (options.start) await options.start(want);
  } } };
  const plugin = new module.exports.default();
  plugin.onAttachedToEngine(engine);
  const binding = { getAbility: () => ability };
  if (options.attached !== false) plugin.onAttachedToAbility(binding);
  t.after(async () => {
    record('cleanup-start', { trackedOpenFds: [...fds] });
    try { assert.equal(fds.size, 0, `Leaked descriptors: ${[...fds]}`); }
    finally {
      // Original cleanup fallback is retained; any leaked-FD assertion still fails.
      for (const fd of fds) { try { fs.closeSync(fd); } catch {} }
      await fsp.rm(root, { recursive: true, force: true });
      record('cleanup-completed', { rootAbsent: !fs.existsSync(root) });
      if (options.onCleanup) options.onCleanup(snapshot());
    }
  });
  const call = (channel, method, args = {}) => new Promise(resolve => {
    const handler = channels.find(c => c.name === channel).handler;
    record('method-call', { channel, method, args });
    handler.onMethodCall({ method, argument: name => args[name] }, {
      success: value => { record('method-success', { value: plain(value) }); resolve({ value: plain(value) }); },
      error: (error, message) => { record('method-error', { error, message }); resolve({ error, message }); },
      notImplemented: () => { record('method-missing'); resolve({ missing: true }); },
    });
  });
  return { snapshot, root, context, workspace, paths, plugin, binding, engine, call, channels, fds, opened, starts, dialogs, photos, warnings, documentOpened, photoOpened,
    destination, imageDestination, get releases() { return releases; },
    async file(name = '中文 空格.txt', bytes = 'hello') { const path = join(workspace, name); await fsp.mkdir(resolve(path, '..'), { recursive: true }); await fsp.writeFile(path, bytes); return path; },
    async cacheFiles() { return await fsp.readdir(context.cacheDir, { recursive: true }); },
  };
}
