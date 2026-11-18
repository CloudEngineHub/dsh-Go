#!/usr/bin/env python3
"""1391: real-provider pending-preview policy targets with declared finite SDK/HTTP boundaries."""
import argparse
import datetime
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
from urllib.parse import unquote, urlparse

IGNORE = {'.git', '.dart_tool', 'build', 'node_modules', '__pycache__', '.cache', '.vendor'}
TEST = 'runtime/tests/ohos/read-aloud-pending-preview-data_test.dart'
RPC = 'runtime/tests/ohos/read-aloud-pending-preview-rpc.mjs'
FIXTURE = 'runtime/tests/ohos/read-aloud-pending-preview-fixture.mjs'
SHIM = 'runtime/tests/ohos/speech-upper/host-fixtures/platform_boundary.dart'
TRANSFORMS = {
    'app/lib/companion/companion_voice.dart': (
        "import 'dart:io';\n", "import 'dart:io' hide Platform;\nimport '../platform_boundary.dart' show Platform;\n"),
    'app/lib/speech/speech_out.dart': (
        "import 'dart:io' show Platform;\n", "import '../platform_boundary.dart' show Platform;\n"),
    'app/lib/speech/deepseek_speech.dart': (
        "import 'dart:io' show Platform;\n", "import '../platform_boundary.dart' show Platform;\n"),
}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def files(root):
    found = []
    for current, dirs, names in os.walk(root, followlinks=False):
        dirs[:] = sorted(name for name in dirs if name not in IGNORE)
        found += [Path(current) / name for name in sorted(names) if (Path(current) / name).is_file()]
    return found


def observe(paths):
    return {str(path): sha(path) for path in sorted(set(paths))}


def main():
    parser = argparse.ArgumentParser()
    for name in ['source', 'prepared-flutter-source', 'flutter', 'node', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--test-source', type=Path)
    parser.add_argument('--plan', type=Path)
    parser.add_argument('--context')
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--typescript-package', type=Path)
    group.add_argument('--typescript-prefix', type=Path)
    args = parser.parse_args()
    source, prepared, out = args.source.resolve(), args.prepared_flutter_source.resolve(), args.out.resolve()
    tests = (args.test_source or source).resolve()
    manifest_path = None
    if args.plan:
        plan = json.loads(args.plan.read_text())
        assert plan['frozenInputs']['driverSHA256'] == sha(__file__)
        for name, expected in plan['frozenInputs']['targets'].items():
            assert sha(tests / name) == expected, name
        context = plan['contexts'][args.context]
        manifest_path = Path(context['sourceManifestPath'])
        assert sha(manifest_path) == context['sourceManifestSHA256']
        manifest = json.loads(manifest_path.read_text())
        assert {name: sha(source / name) for name in manifest} == manifest
    assert not out.exists(), 'Never overwrite any observation'
    out.mkdir(parents=True)
    private = out / 'flutter-source'
    source_paths = files(source)
    source_before = observe(source_paths)
    shutil.copytree(source / 'app/lib', private / 'app/lib', symlinks=True)
    shutil.copytree(source / 'packages', private / 'packages', symlinks=True,
                    ignore=shutil.ignore_patterns(*IGNORE))
    for name in ['pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml']:
        shutil.copy2(source / 'app' / name, private / 'app' / name)
    assert sha(prepared / 'app/pubspec.lock') == sha(source / 'app/pubspec.lock')
    caches = ['app/.dart_tool/package_config.json', 'app/.dart_tool/package_graph.json']
    caches += [str(path.relative_to(prepared)) for path in
               (prepared / 'app/.dart_tool/hooks_runner/shared').rglob('*')
               if path.is_file() and path.name != '.lock']
    for name in caches:
        target = private / name; target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(prepared / name, target)
    assert not (private / '.dart_tool').exists()
    for name in [TEST, RPC, FIXTURE]:
        target = private / name; target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(tests / name, target)
    shutil.copy2(source / SHIM, private / 'app/lib/platform_boundary.dart')
    transforms, diff = [], []
    for name, (old, new) in TRANSFORMS.items():
        original = (source / name).read_text()
        assert original.count(old) == 1, name
        transformed = original.replace(old, new)
        body = lambda text: re.sub(r'^import .*;\n', '', text, flags=re.M)
        assert body(original) == body(transformed), 'Every non-import byte is preserved'
        (private / name).write_text(transformed)
        transforms.append({'path': name, 'originalSHA256': sha(source / name),
                           'preparedSHA256': sha(private / name), 'oldImport': old, 'newImport': new,
                           'nonImportTextSHA256': hashlib.sha256(body(original).encode()).hexdigest()})
        diff.extend(difflib.unified_diff(original.splitlines(True), transformed.splitlines(True),
                                       fromfile='source/' + name, tofile='private/' + name))
    (out / 'PLATFORM-IMPORTS.diff').write_text(''.join(diff))
    original_private = files(private)
    source_diffs = sorted(str(path.relative_to(private)) for path in original_private
                          if (source / path.relative_to(private)).is_file()
                          and sha(path) != sha(source / path.relative_to(private)))
    assert source_diffs == sorted(TRANSFORMS), source_diffs
    save(out / 'SOURCE-TRANSFORM.json', {'transformations': transforms,
          'sourceDiffs': source_diffs, 'methodBodiesAndOtherNonImportBytesUnchanged': True,
          'shimSource': str(source / SHIM), 'shimSHA256': sha(source / SHIM)})
    config = private / 'app/.dart_tool/package_config.json'
    dependencies, locals_ = [], []
    for package in json.loads(config.read_text())['packages']:
        uri = package['rootUri']
        root = (Path(unquote(urlparse(uri).path)) if uri.startswith('file:')
                else config.parent / unquote(uri)).resolve()
        assert root.is_dir(), str(root)
        if root.is_relative_to(private):
            locals_.append(package['name'])
        else:
            dependencies += [path for path in (root / package.get('packageUri', '')).rglob('*.dart') if path.is_file()]
            if (root / 'pubspec.yaml').is_file(): dependencies.append(root / 'pubspec.yaml')
    assert sorted(locals_) == ['dartssh2', 'dsh_app', 'dsh_client', 'dsh_remote', 'dsh_tavern']
    flutter, node = args.flutter.resolve(), args.node.resolve()
    ts_package = (args.typescript_package or args.typescript_prefix / 'node_modules/typescript').resolve()
    assert json.loads((ts_package / 'package.json').read_text())['version'].startswith('5.9.')
    ts_prefix = out / 'typescript-prefix'
    (ts_prefix / 'node_modules').mkdir(parents=True)
    (ts_prefix / 'package.json').write_text('{"private":true,"name":"1391-pending-preview-prefix"}\n')
    (ts_prefix / 'node_modules/typescript').symlink_to(ts_package, target_is_directory=True)
    toolroot = flutter.parent.parent
    tools = [flutter, node, Path(__file__).resolve(), Path(sys.executable).resolve()]
    tools += [ts_package / name for name in ['package.json', 'lib/typescript.js', 'LICENSE.txt']]
    tools += [toolroot / name for name in [
        'bin/cache/dart-sdk/bin/dart', 'bin/cache/dart-sdk/bin/dartvm',
        'bin/cache/dart-sdk/bin/dartaotruntime', 'bin/cache/flutter_tools.snapshot',
        'bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot',
        'bin/cache/artifacts/engine/linux-x64/flutter_tester', 'bin/cache/artifacts/engine/linux-x64/icudtl.dat',
        'bin/cache/artifacts/engine/common/flutter_patched_sdk/platform_strong.dill',
        'bin/cache/artifacts/engine/common/flutter_patched_sdk/vm_outline_strong.dill',
    ]]
    target_inputs = [tests / TEST, tests / RPC, tests / FIXTURE, source / SHIM]
    if args.plan: target_inputs += [args.plan.resolve(), manifest_path]
    preparation_inputs = [prepared / name for name in caches] + [prepared / 'app/pubspec.lock', ts_prefix / 'package.json']
    def inputs():
        return {'frozenSource': observe(source_paths), 'privateDeclaredSourceAndTargets': observe(original_private),
                'privateLockedCache': observe(private / name for name in caches),
                'preparationInputs': observe(preparation_inputs), 'externalDartAndSpecs': observe(dependencies),
                'targetInputsAndPlan': observe(target_inputs), 'tools': observe(tools)}
    before = inputs()
    assert before['frozenSource'] == source_before
    save(out / 'inputs-before.json', before)
    save(out / 'prepare.json', {'createdUTC': now(), 'source': str(source), 'testSource': str(tests),
         'sourceRecords': len(source_paths), 'privateSourceRecords': len(original_private),
         'privateSourceBytes': sum(path.stat().st_size for path in original_private),
         'cacheBytes': sum((private / name).stat().st_size for name in caches),
         'sourceTransforms': transforms, 'sourceDiffs': source_diffs,
         'noRepositoryRootResolver': True, 'noPackageInstall': True, 'noHookModification': True,
         'noAppTestConfig': True, 'noWidgetOrFontClaim': True,
         'mutableHookLocksAreRuntimeOutputsNotInputs': True,
         'typescriptPrefixOnlyLinksRecoveredExactPackage': str(ts_package)})
    env = os.environ.copy(); cleared = []
    for name in list(env):
        if name in ['NODE_OPTIONS', 'NODE_PATH', 'LD_PRELOAD'] or name.startswith('OHOS_'):
            cleared.append(name); env.pop(name)
    updates = {'CI': 'true', 'FLUTTER_SUPPRESS_ANALYTICS': 'true',
               'PUB_CACHE': str(toolroot.parent / 'pub-cache'), 'FLUTTER_ROOT': str(toolroot),
               'NODE': str(node), 'PENDING_PREVIEW_RPC': str(private / RPC),
               'OHOS_TTS_SOURCE_ROOT': str(source), 'OHOS_TYPESCRIPT_PREFIX': str(ts_prefix)}
    env.update(updates)
    argv = [str(flutter), '--suppress-analytics', '--no-version-check', '--verbose',
            'test', '--no-pub', '--no-test-assets', '--reporter=json', '--concurrency=1', '../' + TEST]
    command = {'argv': argv, 'cwd': str(private / 'app'), 'environmentOverrides': updates,
               'environmentCleared': sorted(cleared), 'startedUTC': now(), 'timeoutSeconds': 300}
    save(out / 'command.json', command)
    timed_out = False
    with (out / 'stdout.log').open('wb') as stdout, (out / 'stderr.log').open('wb') as stderr:
        process = subprocess.Popen(argv, cwd=private / 'app', env=env, stdout=stdout, stderr=stderr, start_new_session=True)
        try: code = process.wait(timeout=300)
        except subprocess.TimeoutExpired:
            timed_out = True; os.killpg(process.pid, signal.SIGTERM)
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL); process.wait()
            code = 124
    ended = now(); after = inputs(); save(out / 'inputs-after.json', after)
    starts, rows, events, wires = {}, [], [], []
    for line in (out / 'stdout.log').read_text().splitlines():
        try: row = json.loads(line)
        except (ValueError, TypeError): continue
        if not isinstance(row, dict): continue
        kind = row.get('type')
        if kind == 'testStart': starts[row['test']['id']] = row['test']
        if kind in ['testStart', 'testDone', 'error', 'print', 'done']: events.append(row)
        if kind == 'testDone' and not row.get('hidden', False):
            rows.append({'name': starts[row['testID']]['name'], 'result': row['result'], 'skipped': row.get('skipped', False)})
        if kind == 'print' and row.get('message', '').startswith('PENDING_PREVIEW_1391 '):
            wires.append(json.loads(row['message'][len('PENDING_PREVIEW_1391 '):]))
    done = [event for event in events if event.get('type') == 'done']
    good = code == 0 and not timed_out and before == after and len(rows) == 11 and len(wires) == 11 and all(
        row['result'] == 'success' and not row['skipped'] for row in rows) and len(done) == 1 and done[0].get('success') is True
    report = {'status': 'PASS' if good else 'FAIL_OR_INCOMPLETE_REQUIRES_RAW_REVIEW',
              'childExitCode': code, 'timedOut': timed_out, 'startedUTC': command['startedUTC'], 'endedUTC': ended,
              'inputsUnchanged': before == after, 'inputCounts': {key: len(value) for key, value in before.items()},
              'tests': len(rows), 'passed': sum(row['result'] == 'success' for row in rows),
              'failed': sum(row['result'] in ['failure', 'error'] for row in rows),
              'rows': rows, 'events': events, 'wireCount': len(wires), 'testSHA256': sha(private / TEST),
              'rpcSHA256': sha(private / RPC), 'fixtureSHA256': sha(private / FIXTURE), 'driverSHA256': sha(__file__),
              'stdoutSHA256': sha(out / 'stdout.log'), 'stderrSHA256': sha(out / 'stderr.log'),
              'scope': ('Eleven finite real-provider policy cases. Only OH DeepSeek ReadAloud output creation '
                        'logically retires a shared system preview still awaiting its initial phone.ready. '
                        'Actual shared speaker/voice settings/ReadAloud and DeepSeek resolver to OhosDirectSpeech; '
                        'real Flutter codec and EntryAbility/CompanionVoicePlugin/SpeechPlugin/playback lane. '
                        'Three declared Platform-import substitutions only in a private Dart copy. '
                        'Configuration seams: explicit OS or unchanged host default, activeConnection null, '
                        'test-only key and preference storage, no encoded/external network client. '
                        'Finite HTTP Client and whole OhosPcmStream Backend/HMS Engine boundaries; '
                        'PCM open rejection is handled by actual SpeechPlugin, never a fabricated channel reply. '
                        'Ready delivery and SDK-create waiting are separate finite windows; one accepted-preview '
                        'control holds the PCM open request before Native handling. All holds distinguish '
                        'explicit release from timeout. Both channels preserve original event fields. '
                        'No widget, actual HTTP/model/renderer, physical release, device or Android playback claim.')}
    save(out / 'report.json', report); save(out / 'wire.json', wires)
    print(json.dumps({key: value for key, value in report.items() if key != 'events'}, ensure_ascii=False, indent=2))
    return 0 if good else 1


if __name__ == '__main__':
    raise SystemExit(main())
