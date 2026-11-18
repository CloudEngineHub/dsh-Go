#!/usr/bin/env python3
"""Real Flutter/Riverpod read-aloud with only the existing OS import boundary.

The supplied Flutter source already has its locked, offline dependencies and
assets prepared. This driver copies it privately; it never installs packages,
changes the caller's source, or substitutes a business/controller class.
"""
import argparse
import datetime
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.parse import unquote, urlparse

IGNORE = {'.git', 'node_modules', '.dart_tool', 'build', '__pycache__', '.cache', '.vendor'}
TEST = 'runtime/tests/ohos/read-aloud-preflight-data_test.dart'
RPC = 'runtime/tests/ohos/read-aloud-preflight-rpc.mjs'
SHIM = 'runtime/tests/ohos/speech-upper/host-fixtures/platform_boundary.dart'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def files(root):
    result = []
    for current, dirs, names in os.walk(root, followlinks=False):
        dirs[:] = sorted(name for name in dirs if name not in IGNORE)
        result.extend(Path(current) / name for name in sorted(names) if name not in IGNORE)
    return [path for path in result if path.is_file()]


def observe(paths):
    return {str(path): sha(path) for path in sorted(set(paths))}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--prepared-flutter-source', type=Path, required=True)
    parser.add_argument('--flutter', type=Path, required=True)
    parser.add_argument('--node', type=Path, required=True)
    parser.add_argument('--typescript-prefix', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    source, prepared, out = args.source.resolve(), args.prepared_flutter_source.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    private = out / 'flutter-source'
    private.mkdir()
    original_paths = files(source)
    prepared_paths = files(prepared / 'app') + files(prepared / 'packages')
    original_before = observe(original_paths)
    prepared_before = observe(prepared_paths)
    for folder in ['app', 'packages']:
        shutil.copytree(prepared / folder, private / folder, symlinks=True,
                        ignore=shutil.ignore_patterns(*IGNORE))
    # Use the caller's already-resolved packages and existing native-asset cache.
    caches = ['app/.dart_tool/package_config.json', 'app/.dart_tool/package_graph.json']
    shared = prepared / 'app/.dart_tool/hooks_runner/shared'
    if shared.is_dir():
        # Hook .lock files are rewritten by every flutter test run; they are not inputs.
        caches += [str(path.relative_to(prepared)) for path in shared.rglob('*')
                   if path.is_file() and path.name != '.lock']
    for relative in caches:
        target = private / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(prepared / relative, target)
    assert not (private / '.dart_tool').exists(), 'No repository-root resolver'
    assert sha(private / 'app/pubspec.lock') == sha(source / 'app/pubspec.lock')
    for name in ['speech/read_aloud.dart', 'speech/speech_out.dart', 'companion/companion_voice.dart']:
        assert sha(private / 'app/lib' / name) == sha(source / 'app/lib' / name), name
    test = private / TEST
    test.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / TEST, test)
    shim = private / 'app/lib/platform_boundary.dart'
    shutil.copy2(source / SHIM, shim)
    transformations = []
    patch = ''
    for name, old, new in [
        ('app/lib/companion/companion_voice.dart', "import 'dart:io';",
         "import 'dart:io' hide Platform;\nimport '../platform_boundary.dart' show Platform;"),
        ('app/lib/speech/speech_out.dart', "import 'dart:io' show Platform;",
         "import '../platform_boundary.dart' show Platform;"),
    ]:
        original = (source / name).read_text()
        assert original.count(old) == 1
        transformed = original.replace(old, new)
        body = lambda text: re.sub(r'^import .*;\n', '', text, flags=re.M)
        assert body(original) == body(transformed), 'Only imports may change'
        (private / name).write_text(transformed)
        transformations.append({'path': name, 'sourceSHA256': sha(source / name),
                                'preparedSHA256': sha(private / name),
                                'bodySHA256': hashlib.sha256(body(original).encode()).hexdigest(),
                                'bodyUnchanged': True})
        patch += ''.join(difflib.unified_diff(original.splitlines(keepends=True), transformed.splitlines(keepends=True),
                                            fromfile='source/' + name, tofile='prepared/' + name))
    (out / 'platform-imports.diff').write_text(patch)
    save(out / 'transform.json', {'files': transformations, 'shimSource': str(source / SHIM), 'shimSHA256': sha(shim),
                                'realFlutterAndRiverpod': True, 'businessMethodsUnchanged': True})
    config_path = private / 'app/.dart_tool/package_config.json'
    dependencies = []
    local = []
    for package in json.loads(config_path.read_text())['packages']:
        uri = package['rootUri']
        root = (Path(unquote(urlparse(uri).path)) if uri.startswith('file:') else config_path.parent / unquote(uri)).resolve()
        if root.is_relative_to(private):
            local.append(package['name'])
        else:
            dependencies += [path for path in (root / package.get('packageUri', '')).rglob('*.dart') if path.is_file()]
            if (root / 'pubspec.yaml').is_file(): dependencies.append(root / 'pubspec.yaml')
    assert sorted(local) == ['dartssh2', 'dsh_app', 'dsh_client', 'dsh_remote', 'dsh_tavern']
    private_paths = files(private)
    tools = [args.flutter.resolve(), args.node.resolve(), args.typescript_prefix.resolve() / 'node_modules/typescript/lib/typescript.js',
             args.typescript_prefix.resolve() / 'node_modules/typescript/package.json', Path(__file__).resolve()]
    cache_paths = [private / name for name in caches]
    def inputs():
        return {'source': observe(original_paths), 'preparedFlutterInput': observe(prepared_paths),
                'privateSourceAfterTwoImportChanges': observe(private_paths), 'privateCache': observe(cache_paths),
                'externalDartAndSpecs': observe(dependencies), 'tools': observe(tools)}
    before = inputs()
    assert before['source'] == original_before and before['preparedFlutterInput'] == prepared_before
    save(out / 'inputs-before.json', before)
    argv = [str(args.flutter.resolve()), '--suppress-analytics', '--no-version-check', '--verbose',
            'test', '--no-pub', '--reporter', 'json', '--concurrency=1', '../' + TEST]
    env = os.environ.copy()
    cleared = []
    for name in list(env):
        if name in ['NODE_OPTIONS', 'NODE_PATH', 'LD_PRELOAD'] or name.startswith('OHOS_'):
            cleared.append(name)
            env.pop(name)
    updates = {'CI': 'true', 'FLUTTER_SUPPRESS_ANALYTICS': 'true', 'NODE': str(args.node.resolve()),
               'OHOS_TYPESCRIPT_PREFIX': str(args.typescript_prefix.resolve()), 'OHOS_TTS_SOURCE_ROOT': str(source),
               'READ_ALOUD_RPC': str(source / RPC)}
    env.update(updates)
    command = {'argv': argv, 'cwd': str(private / 'app'), 'environmentOverrides': updates, 'environmentCleared': cleared,
               'startedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'timeoutSeconds': 240}
    save(out / 'command.json', command)
    timed_out = False
    with (out / 'stdout.log').open('wb') as stdout, (out / 'stderr.log').open('wb') as stderr:
        try:
            result = subprocess.run(argv, cwd=private / 'app', env=env, stdout=stdout, stderr=stderr, timeout=240)
            code = result.returncode
        except subprocess.TimeoutExpired:
            code = 124
            timed_out = True
    after = inputs()
    save(out / 'inputs-after.json', after)
    starts, rows, events, wires = {}, [], [], []
    for line in (out / 'stdout.log').read_text().splitlines():
        try: value = json.loads(line)
        except (ValueError, TypeError): continue
        if not isinstance(value, dict): continue
        kind = value.get('type')
        if kind == 'testStart': starts[value['test']['id']] = value['test']
        if kind in ['testStart', 'testDone', 'error', 'print', 'done']: events.append(value)
        if kind == 'testDone' and not value.get('hidden', False):
            rows.append({'name': starts[value['testID']]['name'], 'result': value['result'], 'skipped': value.get('skipped', False)})
        if kind == 'print' and value.get('message', '').startswith('READ_ALOUD_1365 '):
            wires.append(json.loads(value['message'][len('READ_ALOUD_1365 '):]))
    good = code == 0 and not timed_out and before == after and len(rows) == 11 and all(row['result'] == 'success' and not row['skipped'] for row in rows)
    report = {'status': 'PASS' if good else 'FAIL', 'childExitCode': code, 'timedOut': timed_out,
              'endedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'inputsUnchanged': before == after,
              'inputCounts': {key: len(value) for key, value in before.items()}, 'tests': len(rows),
              'passed': sum(row['result'] == 'success' and not row['skipped'] for row in rows),
              'failed': sum(row['result'] in ['failure', 'error'] for row in rows), 'rows': rows, 'events': events,
              'testSHA256': sha(test), 'rpcSHA256': sha(source / RPC), 'stdoutSHA256': sha(out / 'stdout.log'),
              'scope': 'Real Flutter/Riverpod/ReadAloud and actual ETS. Two declared Platform import changes; finite HMS/embedding boundaries. No UI pumping, SDK/device or physical release claim.'}
    save(out / 'report.json', report)
    save(out / 'wire.json', wires)
    print(json.dumps({key: value for key, value in report.items() if key != 'events'}, ensure_ascii=False, indent=2))
    return 0 if good else 1


if __name__ == '__main__':
    raise SystemExit(main())
