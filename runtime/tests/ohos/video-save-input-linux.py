#!/usr/bin/env python3
"""Finite video-save input gate: actual ETS and native safe FD opener on Linux."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--node', required=True, type=Path)
    parser.add_argument('--node-headers', required=True, type=Path)
    parser.add_argument('--typescript-prefix', required=True, type=Path)
    parser.add_argument('--cxx', default='g++')
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--mode', choices=('plain', 'jitless'), default='plain')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    tests = repo / 'runtime/tests/ohos'
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    node = args.node.resolve()
    headers = args.node_headers.resolve()
    compiler = Path(shutil.which(args.cxx) or args.cxx).resolve()
    prefix = args.typescript_prefix.resolve()
    typescript = prefix / 'node_modules/typescript'
    version = json.loads((typescript / 'package.json').read_text())['version']
    if not version.startswith('5.9.'):
        raise ValueError('TypeScript 5.9.x is required')
    sources = [tests / name for name in ('video-save-empty.test.mjs',
        'files-media-fixture.mjs', 'video-save-input-linux.py', 'user-file-access-addon.cc')]
    sources += [repo / name for name in (
        'app/ohos/entry/src/main/ets/plugins/FilesMediaPlugin.ets',
        'app/ohos/entry/src/main/ets/runtime/RuntimePaths.ets',
        'app/ohos/entry/src/main/cpp/file_access.h')]
    sources += [node, compiler, typescript / 'package.json', typescript / 'lib/typescript.js']
    sources += sorted(path for path in headers.rglob('*') if path.is_file())
    snapshot = lambda: {str(path): {'bytes': path.stat().st_size, 'sha256': sha(path)} for path in sources}
    before = snapshot()
    save(out / 'sources-before.json', before)
    addon = out / 'user-file-access.node'
    build = [str(compiler), '-std=c++17', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
        '-I', str(headers), str(tests / 'user-file-access-addon.cc'), '-o', str(addon)]
    save(out / 'native-command.json', {'argv': build, 'cwd': str(repo), 'timeoutSeconds': 90,
        'scope': 'Production safe opener compiled as a Linux host N-API addon, not OH cross compilation'})
    started = utc()
    with (out / 'native-build.log').open('wb') as log:
        try:
            build_code = subprocess.run(build, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=90).returncode
        except subprocess.TimeoutExpired:
            build_code = 124
    env = {'OHOS_TYPESCRIPT_PREFIX': str(prefix), 'OHOS_VIDEO_SAVE_SOURCE_ROOT': str(repo),
        'OHOS_USER_FILE_ADDON': str(addon), 'LC_ALL': 'C'}
    argv = [str(node), *(['--jitless'] if args.mode == 'jitless' else []), '--test',
        '--test-concurrency=1', '--test-reporter=tap',
        'runtime/tests/ohos/video-save-empty.test.mjs']
    save(out / 'command.json', {'argv': argv, 'cwd': str(repo), 'environmentOverrides': env,
        'environmentCleared': ['NODE_PATH'], 'timeoutSeconds': 90, 'started': build_code == 0})
    child_env = {**os.environ, **env}
    child_env.pop('NODE_PATH', None)
    code = None
    if build_code == 0:
        with (out / 'test.log').open('wb') as log:
            try:
                code = subprocess.run(argv, cwd=repo, env=child_env,
                    stdout=log, stderr=subprocess.STDOUT, timeout=90).returncode
            except subprocess.TimeoutExpired:
                code = 124
    output = (out / 'test.log').read_text() if code is not None else ''
    sys.stdout.write(output)
    counts = {}
    for key in ('tests', 'pass', 'fail', 'cancelled', 'skipped', 'todo'):
        values = re.findall(r'^# ' + key + r' (\d+)$', output, re.M)
        if len(values) == 1:
            counts[key] = int(values[0])
    after = snapshot()
    save(out / 'sources-after.json', after)
    passed = build_code == 0 and code == 0 and counts == {
        'tests': 2, 'pass': 2, 'fail': 0, 'cancelled': 0, 'skipped': 0, 'todo': 0} and before == after
    report = {'schema': 1, 'status': 'PASS_SCOPED' if passed else 'FAIL',
        'startedUTC': started, 'endedUTC': utc(), 'buildExitCode': build_code, 'childExitCode': code,
        'counts': counts, 'mode': args.mode, 'inputsUnchanged': before == after,
        'typescriptVersion': version, 'addonSHA256': sha(addon) if addon.is_file() else None,
        'scope': 'Actual FilesMediaPlugin/RuntimePaths and production safe FD opener with real Linux files; '
                 'finite PhotoType.VIDEO confirmation returns []; no media target creation or decoding',
        'notRun': ['OH SDK/ArkTS build', 'device album permission or acceptance', 'full unified gates']}
    save(out / 'report.json', report)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
