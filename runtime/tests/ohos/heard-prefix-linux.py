#!/usr/bin/env python3
"""Actual OH heard prefixes and VoiceCall, with a small offline Flutter copy."""
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
from urllib.parse import unquote, urlparse

IGNORE = {'.git', '.dart_tool', 'build', 'node_modules', '__pycache__', '.cache', '.vendor'}
TEST = 'runtime/tests/ohos/heard-prefix-data_test.dart'
FIXTURE = 'runtime/tests/ohos/heard-prefix-fixture.dart'
SHIM = 'runtime/tests/ohos/speech-upper/host-fixtures/platform_boundary.dart'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    # Preserve any diagnostic escaped surrogate without rewriting its meaning.
    Path(path).write_text(json.dumps(value, ensure_ascii=True, indent=2) + '\n')


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def files(root):
    found = []
    for current, dirs, names in os.walk(root, followlinks=False):
        dirs[:] = sorted(name for name in dirs if name not in IGNORE)
        found += [Path(current) / name for name in sorted(names)
                  if (Path(current) / name).is_file()]
    return found


def observe(paths):
    return {str(path): sha(path) for path in sorted(set(paths))}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--test-source', type=Path)
    parser.add_argument('--prepared-flutter-source', type=Path, required=True)
    parser.add_argument('--flutter', type=Path, required=True)
    parser.add_argument('--analyze', action='store_true')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    source, prepared, out = args.source.resolve(), args.prepared_flutter_source.resolve(), args.out.resolve()
    test_source = (args.test_source or args.source).resolve()
    out.mkdir(parents=True, exist_ok=False)
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
    # Only immutable cache inputs are copied/observed. Hook locks are mutable
    # runtime outputs, created by the original hook runner in the new directory.
    caches += [str(path.relative_to(prepared)) for path in
               (prepared / 'app/.dart_tool/hooks_runner/shared').rglob('*')
               if path.is_file() and path.name != '.lock']
    for name in caches:
        target = private / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(prepared / name, target)
    assert not (private / '.dart_tool').exists()
    test = private / TEST
    test.parent.mkdir(parents=True)
    shutil.copy2(test_source / TEST, test)
    shutil.copy2(test_source / FIXTURE, private / FIXTURE)
    shutil.copy2(source / SHIM, private / 'app/lib/platform_boundary.dart')
    patch, transforms = '', []
    for name, old, new in ([] if args.analyze else [
        ('app/lib/speech/speech_out.dart', "import 'dart:io' show Platform;",
         "import '../platform_boundary.dart' show Platform;"),
    ]):
        original = (source / name).read_text()
        assert original.count(old) == 1
        transformed = original.replace(old, new)
        body = lambda text: re.sub(r'^import .*;\n', '', text, flags=re.M)
        assert body(original) == body(transformed)
        (private / name).write_text(transformed)
        transforms.append({'path': name, 'sourceSHA256': sha(source / name),
                           'privateSHA256': sha(private / name), 'businessBodyUnchanged': True,
                           'bodySHA256': hashlib.sha256(body(original).encode()).hexdigest()})
        patch += ''.join(difflib.unified_diff(original.splitlines(keepends=True), transformed.splitlines(keepends=True),
                                            fromfile='source/' + name, tofile='private/' + name))
    (out / 'platform-imports.diff').write_text(patch)
    save(out / 'transform.json', {'files': transforms, 'shimSource': str(source / SHIM),
        'shimSHA256': sha(private / 'app/lib/platform_boundary.dart'), 'analyzeUsesOriginalImports': args.analyze})
    config = private / 'app/.dart_tool/package_config.json'
    dependencies, locals_ = [], []
    for package in json.loads(config.read_text())['packages']:
        uri = package['rootUri']
        root = (Path(unquote(urlparse(uri).path)) if uri.startswith('file:')
                else config.parent / unquote(uri)).resolve()
        if root.is_relative_to(private): locals_.append(package['name'])
        else:
            dependencies += [path for path in (root / package.get('packageUri', '')).rglob('*.dart') if path.is_file()]
            if (root / 'pubspec.yaml').is_file(): dependencies.append(root / 'pubspec.yaml')
    assert sorted(locals_) == ['dartssh2', 'dsh_app', 'dsh_client', 'dsh_remote', 'dsh_tavern']
    private_paths = files(private)
    flutter = args.flutter.resolve()
    toolroot = flutter.parent.parent
    tools = [flutter, Path(__file__).resolve()]
    tools += [toolroot / name for name in [
        'bin/cache/dart-sdk/bin/dart', 'bin/cache/dart-sdk/bin/dartvm',
        'bin/cache/dart-sdk/bin/dartaotruntime', 'bin/cache/flutter_tools.snapshot',
        'bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot',
        'bin/cache/artifacts/engine/linux-x64/flutter_tester',
        'bin/cache/artifacts/engine/linux-x64/icudtl.dat',
        'bin/cache/artifacts/engine/common/flutter_patched_sdk/platform_strong.dill',
        'bin/cache/artifacts/engine/common/flutter_patched_sdk/vm_outline_strong.dill',
    ]]
    fixture_inputs = [test_source / TEST, test_source / FIXTURE, source / SHIM]
    preparation_inputs = [prepared / name for name in caches] + [prepared / 'app/pubspec.lock']
    def inputs():
        return {'source': observe(source_paths), 'privateSourceAfterDeclaredImportChange': observe(private_paths),
                'privateLockedCache': observe(private / name for name in caches),
                'preparationInputs': observe(preparation_inputs), 'externalDartAndSpecs': observe(dependencies),
                'testAndBoundaryInputs': observe(fixture_inputs), 'tools': observe(tools)}
    before = inputs()
    assert before['source'] == source_before
    save(out / 'inputs-before.json', before)
    save(out / 'prepare.json', {'createdUTC': now(), 'source': str(source), 'testSource': str(test_source),
        'sourceRecords': len(source_paths), 'privateSourceRecords': len(private_paths),
        'privateSourceBytes': sum(path.stat().st_size for path in private_paths),
        'cacheBytes': sum((private / name).stat().st_size for name in caches),
        'noRepositoryRootResolver': True, 'noPackageInstall': True, 'noHookModification': True,
        'mutableHookLocksAreRuntimeOutputsNotInputs': True, 'noAppTestConfigOrFonts': True})
    env = os.environ.copy()
    cleared = []
    for name in list(env):
        if name in ['NODE_OPTIONS', 'NODE_PATH', 'LD_PRELOAD'] or name.startswith('OHOS_'):
            cleared.append(name)
            env.pop(name)
    updates = {'CI': 'true', 'FLUTTER_SUPPRESS_ANALYTICS': 'true'}
    env.update(updates)
    argv = [str(flutter), '--suppress-analytics', '--no-version-check', '--verbose']
    argv += (['analyze', '--no-pub', 'lib/speech/speech_out.dart'] if args.analyze else
             ['test', '--no-pub', '--no-test-assets', '--reporter=json', '--concurrency=1', '../' + TEST])
    command = {'argv': argv, 'cwd': str(private / 'app'), 'environmentOverrides': updates,
               'environmentCleared': cleared, 'startedUTC': now(), 'timeoutSeconds': 240}
    save(out / 'command.json', command)
    timed_out = False
    with (out / 'stdout.log').open('wb') as stdout, (out / 'stderr.log').open('wb') as stderr:
        try:
            run = subprocess.run(argv, cwd=private / 'app', env=env, stdout=stdout, stderr=stderr, timeout=240)
            code = run.returncode
        except subprocess.TimeoutExpired:
            code, timed_out = 124, True
    ended = now()
    after = inputs()
    save(out / 'inputs-after.json', after)
    starts, rows, events, wires = {}, [], [], []
    for line in (out / 'stdout.log').read_text().splitlines():
        try: row = json.loads(line)
        except (ValueError, TypeError): continue
        if not isinstance(row, dict): continue
        kind = row.get('type')
        if kind == 'testStart': starts[row['test']['id']] = row['test']
        if kind in ['testStart', 'testDone', 'error', 'print', 'done']: events.append(row)
        if kind == 'testDone' and not row.get('hidden', False):
            rows.append({'name': starts[row['testID']]['name'], 'result': row['result'],
                         'skipped': row.get('skipped', False)})
        if kind == 'print' and row.get('message', '').startswith('HEARD_PREFIX_1378 '):
            wires.append(json.loads(row['message'][len('HEARD_PREFIX_1378 '):]))
    complete = args.analyze or (len(rows) == 7 and len(wires) == 7 and all(
        row['result'] == 'success' and not row['skipped'] for row in rows))
    good = code == 0 and not timed_out and before == after and complete
    report = {'status': 'PASS' if good else 'FAIL', 'childExitCode': code, 'timedOut': timed_out,
              'startedUTC': command['startedUTC'], 'endedUTC': ended,
              'inputsUnchanged': before == after, 'inputCounts': {key: len(value) for key, value in before.items()},
              'tests': len(rows), 'passed': sum(row['result'] == 'success' for row in rows),
              'failed': sum(row['result'] in ['failure', 'error'] for row in rows),
              'rows': rows, 'events': events, 'wireCount': len(wires),
              'testSHA256': sha(test), 'fixtureSHA256': sha(test_source / FIXTURE),
              'mode': 'analyze' if args.analyze else 'test',
              'stdoutSHA256': sha(out / 'stdout.log'),
              'scope': 'Actual Flutter SpeechAudio/factory/output/VoiceCall with finite synthesis, recognition, PCM-platform and conversation boundaries. One OS import change in test mode; original imports in app-library analyze mode. No ETS, UI, HTTP/model, SDK/device or acoustic-progress claim.'}
    save(out / 'report.json', report)
    save(out / 'wire.json', wires)
    print(json.dumps({key: value for key, value in report.items() if key != 'events'}, ensure_ascii=True, indent=2))
    return 0 if good else 1


if __name__ == '__main__':
    raise SystemExit(main())
