import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_voice.dart';
import 'package:dsh_app/platform_boundary.dart' as selected_os;
import 'package:dsh_app/companion/companion_voice_source.dart';
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/read_aloud.dart';
import 'package:dsh_app/speech/speech_out.dart';
import 'package:dsh_app/speech/speech_settings.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const channel = MethodChannel('dsh/companion_voice');
const audioChannel = MethodChannel('dsh/speech');
const system = CompanionVoiceSettings(source: CompanionVoiceSource.system);

class Native {
  Native(this.process) {
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final row = jsonDecode(line) as Map<String, dynamic>;
      if (row['event'] case final Map event) {
        final bytes = const StandardMethodCodec().encodeMethodCall(MethodCall('event', event));
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(channel.name, bytes, (_) {});
        events.add(event);
      } else {
        final done = pending.remove(row['id']);
        if (row.containsKey('error')) { done?.completeError(StateError('${row['error']}')); }
        else { done?.complete(row['result']); }
      }
    });
    process.stderr.transform(utf8.decoder).listen(errors.write);
  }
  final Process process;
  final pending = <int, Completer<Object?>>{};
  final events = <Map>[];
  final errors = StringBuffer();
  int serial = 0;
  static Future<Native> start() async {
    final native = Native(await Process.start(Platform.environment['NODE']!, [Platform.environment['READ_ALOUD_RPC']!]));
    await native.ask('snapshot');
    return native;
  }
  Future<Object?> ask(String method, [Object? args]) {
    final id = ++serial;
    final result = Completer<Object?>();
    pending[id] = result;
    process.stdin.writeln(jsonEncode({'id': id, 'method': method, 'args': args}));
    return result.future.timeout(const Duration(seconds: 10));
  }
  Future<Map> snapshot() async => await ask('snapshot') as Map;
  Future<void> close() async {
    await ask('close');
    await process.stdin.close();
    expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0, reason: errors.toString());
  }
}

List<String> texts(Map snapshot) => [
  for (final engine in snapshot['engines'] as List)
    for (final call in (engine as Map)['calls'] as List) (call as Map)['text'] as String,
];

class Rig {
  Rig(this.native, {String? platform = 'ohos', this.holdReady = 1, this.heldValue = true, this.holdNextReady = false}) {
    selected_os.Platform.operatingSystem = platform ?? 'linux';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      final row = <String, Object?>{'method': call.method, 'arguments': call.arguments};
      wire.add(row);
      final reply = await native.ask('voice', {'method': call.method, 'arguments': call.arguments}) as Map;
      row['nativeReply'] = reply;
      if (call.method == 'ready' && ++readyCalls == holdReady) {
        held = true;
        // Actual ETS has finished initialization and computed this true/false result.
        // Only its MethodChannel reply delivery is held. No old native work is
        // allowed to calculate success after stop/retirement.
        expect(reply, {'value': heldValue});
        readyComputed.complete();
        await deliverReady.future;
      } else if (call.method == 'ready' && holdNextReady && readyCalls == holdReady + 1) {
        expect(reply, {'value': true});
        nextReadyComputed.complete();
        await deliverNextReady.future;
      }
      if (reply['error'] case final String code) throw PlatformException(code: code);
      return reply['value'];
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(audioChannel, (call) async {
      final row = <String, Object?>{'method': call.method, 'arguments': call.arguments};
      audioWire.add(row);
      final reply = await native.ask('audio', {'method': call.method, 'arguments': call.arguments}) as Map;
      row['nativeReply'] = reply;
      if (reply['error'] case final String code) throw PlatformException(code: code);
      return reply['value'];
    });
    container = ProviderContainer(overrides: [
      if (platform != null) operatingSystemProvider.overrideWithValue(platform),
      deepSeekSpeechProvider.overrideWithValue(() async { resolverCalls++; return null; }),
      deepSeekSpeechGapProvider.overrideWithValue(() => DeepSeekSpeechFailure.rejected),
      companionVoiceClientProvider.overrideWithValue(() => MockClient((_) async {
        externalCalls++;
        throw StateError('No external request');
      })),
    ]);
    speaker = container.read(speechSpeakerProvider);
    controller = container.read(readAloudProvider.notifier);
  }
  final Native native;
  final int holdReady;
  final bool heldValue, holdNextReady;
  int readyCalls = 0, resolverCalls = 0;
  late final ProviderContainer container;
  late final CompanionSpeaker speaker;
  late final ReadAloudController controller;
  final readyComputed = Completer<void>(), deliverReady = Completer<void>();
  final nextReadyComputed = Completer<void>(), deliverNextReady = Completer<void>();
  final wire = <Map<String, Object?>>[], audioWire = <Map<String, Object?>>[];
  final errors = <Object>[];
  bool held = false, disposed = false;
  int externalCalls = 0;
  Future<Map> untilTexts(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      final snapshot = await native.snapshot();
      if (texts(snapshot).length >= count) return snapshot;
      if (DateTime.now().isAfter(deadline)) throw StateError('SDK speak did not arrive');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }
  Future<void> quiet() async {
    for (var round = 0; round < 4; round++) {
      await pumpEventQueue();
      await Future.wait(native.pending.values.map((value) => value.future).toList())
          .timeout(const Duration(seconds: 10));
    }
  }
  void disposeContainer() {
    if (disposed) return;
    disposed = true;
    container.dispose();
  }
  Future<void> close() async {
    if (!deliverReady.isCompleted) deliverReady.complete();
    if (!deliverNextReady.isCompleted) deliverNextReady.complete();
    if (!disposed) {
      controller.stop();
      disposeContainer();
    }
    await pumpEventQueue();
    await native.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(audioChannel, null);
  }
  void record(String name, Map before, Map after, Object? previewResult) {
    final state = container.read(readAloudProvider);
    debugPrint('READ_ALOUD_1365 ${jsonEncode({'case': name, 'speaker': speaker.runtimeType.toString(),
      'wire': wire, 'audioWire': audioWire, 'nativeEvents': native.events, 'before': before, 'after': after,
      'controllerState': {'id': state.id, 'phase': state.phase.name}, 'previewResult': previewResult,
      'errors': errors.map((e) => e.toString()).toList(), 'externalCalls': externalCalls, 'resolverCalls': resolverCalls})}');
  }
}


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'speech_voice_v1': jsonEncode({'source': 'system'})});
  });

  for (final platform in ['ohos', 'android', null]) {
    test('${platform ?? "default host"}: normal delayed ready preserves its selected provider and wire', () async {
      final rig = Rig(await Native.start(), platform: platform);
      try {
        if (platform == 'ohos') { expect(rig.speaker, isA<OhosSpeechSpeaker>()); }
        else { expect(rig.speaker.runtimeType, CompanionSpeaker); }
        final reading = rig.controller.toggle('message', '正常朗读。', onError: rig.errors.add);
        await rig.readyComputed.future.timeout(const Duration(seconds: 10));
        final before = await rig.native.snapshot();
        expect(texts(before), isEmpty);
        expect(rig.container.read(readAloudProvider).phase, ReadAloudPhase.loading);
        rig.deliverReady.complete();
        await reading;
        await rig.quiet();
        final after = await rig.untilTexts(1);
        await rig.native.ask('sdk', {'event': 'start', 'text': '正常朗读。'});
        await rig.quiet();
        rig.record('normal-${platform ?? "default"}', before, after, null);
        expect(texts(after), ['正常朗读。']);
        expect(rig.container.read(readAloudProvider).phase, ReadAloudPhase.playing);
        final args = rig.wire.singleWhere((row) => row['method'] == 'speak')['arguments'] as Map;
        expect({...args}..remove('id'), {'text': '正常朗读。', 'flush': false, 'pitch': 1.12, 'rate': 1.0});
        expect(rig.errors, isEmpty);
        expect(rig.externalCalls, 0);
      } finally { await rig.close(); }
    });
  }

  for (final firstReady in [true, false]) {
    test('OH shared preview retires pending read-aloud before late ready=$firstReady without a false setup error', () async {
      final native = await Native.start();
      if (!firstReady) await native.ask('availability', {'unavailable': true});
      final rig = Rig(native, heldValue: firstReady);
      try {
        final old = rig.controller.toggle('old-message', '旧消息朗读。', onError: rig.errors.add);
        await rig.readyComputed.future.timeout(const Duration(seconds: 10));
        await native.ask('availability', {'unavailable': false});
        final preview = rig.speaker.preview(system, '新共享试听。');
        final before = await rig.untilTexts(1);
        await native.ask('sdk', {'event': 'start', 'text': '新共享试听。'});
        await rig.quiet();
        final stops = rig.wire.where((row) => row['method'] == 'stop').length;
        rig.deliverReady.complete();
        await old;
        await rig.quiet();
        final after = await native.snapshot();
        final stateBeforeCompletion = rig.container.read(readAloudProvider);
        await native.ask('sdk', {'event': 'complete', 'text': '新共享试听。'});
        await rig.quiet();
        final result = await preview.timeout(const Duration(seconds: 10));
        rig.record('preview-late-$firstReady', before, after, result);
        expect(texts(after), ['新共享试听。']);
        expect(result, isNull, reason: 'retired old preflight must not cancel the new preview');
        expect(stateBeforeCompletion.id, isNull);
        expect(stateBeforeCompletion.phase, ReadAloudPhase.idle);
        expect(rig.errors, isEmpty, reason: 'user replacement is not an unconfigured voice');
        expect(rig.wire.where((row) => row['method'] == 'stop').length, stops);
      } finally { await rig.close(); }
    });
  }

  for (final explicitStop in [false, true]) {
    test('OH ${explicitStop ? "stop then new toggle" : "new toggle"} keeps the latest output after an old ready reply', () async {
      final native = await Native.start();
      if (explicitStop) await native.ask('availability', {'unavailable': true});
      final rig = Rig(native, heldValue: !explicitStop, holdNextReady: !explicitStop);
      try {
        final old = rig.controller.toggle('old-message', '旧消息不得提交。', onError: rig.errors.add);
        await rig.readyComputed.future.timeout(const Duration(seconds: 10));
        if (explicitStop) rig.controller.stop();
        await native.ask('availability', {'unavailable': false});
        final next = rig.controller.toggle('new-message', '新消息朗读。', onError: rig.errors.add);
        if (!explicitStop) {
          await rig.nextReadyComputed.future.timeout(const Duration(seconds: 10));
          await rig.quiet();
          final preparingOwner = (rig.speaker as OhosSpeechSpeaker).systemOutput;
          expect(rig.container.read(readAloudProvider).id, 'new-message');
          expect(rig.container.read(readAloudProvider).phase, ReadAloudPhase.loading);
          rig.deliverReady.complete();
          await old;
          await rig.quiet();
          expect(rig.container.read(readAloudProvider).id, 'new-message');
          expect(rig.container.read(readAloudProvider).phase, ReadAloudPhase.loading);
          expect(identical((rig.speaker as OhosSpeechSpeaker).systemOutput, preparingOwner), isTrue);
          expect(texts(await native.snapshot()), isEmpty);
          expect(rig.errors, isEmpty);
          rig.deliverNextReady.complete();
        }
        await next;
        final before = await rig.untilTexts(1);
        await native.ask('sdk', {'event': 'start', 'text': '新消息朗读。'});
        await rig.quiet();
        final owner = (rig.speaker as OhosSpeechSpeaker).systemOutput;
        expect(owner, isNotNull);
        if (!rig.deliverReady.isCompleted) rig.deliverReady.complete();
        await old;
        await rig.quiet();
        final after = await native.snapshot();
        rig.record('new-toggle-$explicitStop', before, after, null);
        expect(texts(after), ['新消息朗读。']);
        expect(identical((rig.speaker as OhosSpeechSpeaker).systemOutput, owner), isTrue);
        expect(rig.container.read(readAloudProvider).id, 'new-message');
        expect(rig.container.read(readAloudProvider).phase, ReadAloudPhase.playing);
        expect(rig.errors, isEmpty);
      } finally { await rig.close(); }
    });
  }

  test('OH real ready failure retires its empty output and a later explicit retry succeeds', () async {
    final native = await Native.start();
    await native.ask('availability', {'unavailable': true});
    final rig = Rig(native, heldValue: false);
    try {
      final failed = rig.controller.toggle('failed-message', '首次失败。', onError: rig.errors.add);
      await rig.readyComputed.future.timeout(const Duration(seconds: 10));
      final before = await native.snapshot();
      rig.deliverReady.complete();
      await failed;
      await rig.quiet();
      expect(rig.errors, hasLength(1));
      expect(rig.errors.single, isA<ReadAloudNotSetUp>());
      expect(rig.container.read(readAloudProvider).phase, ReadAloudPhase.idle);
      expect((rig.speaker as OhosSpeechSpeaker).systemOutput, isNull);
      expect(texts(await native.snapshot()), isEmpty);
      await native.ask('availability', {'unavailable': false});
      await rig.controller.toggle('retry-message', '用户重试朗读。', onError: rig.errors.add);
      final after = await rig.untilTexts(1);
      await native.ask('sdk', {'event': 'start', 'text': '用户重试朗读。'});
      await rig.quiet();
      rig.record('failure-then-retry', before, after, null);
      expect(texts(after), ['用户重试朗读。']);
      expect(rig.container.read(readAloudProvider).id, 'retry-message');
      expect(rig.container.read(readAloudProvider).phase, ReadAloudPhase.playing);
      expect(rig.errors, hasLength(1));
    } finally { await rig.close(); }
  });

  test('OH new explicit read-aloud takes the existing preview before waiting for system ready', () async {
    final rig = Rig(await Native.start(), holdReady: 2);
    try {
      String? outcome = 'pending';
      final preview = rig.speaker.preview(system, '先前试听。').then((value) { outcome = value; return value; });
      await rig.untilTexts(1);
      await rig.native.ask('sdk', {'event': 'start', 'text': '先前试听。'});
      await rig.quiet();
      final reading = rig.controller.toggle('new-message', '新的明确朗读。', onError: rig.errors.add);
      await rig.readyComputed.future.timeout(const Duration(seconds: 10));
      await rig.quiet();
      final before = await rig.native.snapshot();
      final duringReady = outcome;
      rig.deliverReady.complete();
      await reading;
      final after = await rig.untilTexts(2);
      await rig.quiet();
      final result = await preview.timeout(const Duration(seconds: 10));
      rig.record('explicit-new-read', before, after, result);
      expect(duringReady, 'cancelled', reason: 'the new explicit OH request owns preparation too');
      expect(texts(before), ['先前试听。']);
      expect(texts(after), ['先前试听。', '新的明确朗读。']);
      expect(result, 'cancelled');
      expect(rig.errors, isEmpty);
    } finally { await rig.close(); }
  });


  test('OH actual provider-container disposal retires prepared output before its late ready reply', () async {
    final rig = Rig(await Native.start());
    try {
      final reading = rig.controller.toggle('disposed-message', '销毁后不得提交。', onError: rig.errors.add);
      await rig.readyComputed.future.timeout(const Duration(seconds: 10));
      final before = await rig.native.snapshot();
      final hadPreparedOwner = (rig.speaker as OhosSpeechSpeaker).systemOutput != null;
      rig.disposeContainer();
      await rig.quiet();
      rig.deliverReady.complete();
      await reading;
      await rig.quiet();
      final after = await rig.native.snapshot();
      debugPrint('READ_ALOUD_1365 ${jsonEncode({'case': 'container-dispose', 'before': before, 'after': after,
        'wire': rig.wire, 'audioWire': rig.audioWire, 'hadPreparedOwner': hadPreparedOwner,
        'systemOutputAfter': (rig.speaker as OhosSpeechSpeaker).systemOutput == null ? null : 'retained',
        'errors': rig.errors.map((error) => error.toString()).toList()})}');
      expect(texts(after), isEmpty);
      expect((rig.speaker as OhosSpeechSpeaker).systemOutput, isNull);
      expect(rig.errors, isEmpty);
      expect((after['engines'] as List).every((value) => (value as Map)['closed'] == true), isTrue);
    } finally { await rig.close(); }
  });

  test('DeepSeek read-aloud keeps its existing resolver path without a system ready query', () async {
    SharedPreferences.setMockInitialValues({'speech_voice_v1': jsonEncode({'source': 'deepseek'})});
    final rig = Rig(await Native.start());
    try {
      await rig.controller.toggle('deepseek-message', '外部来源配置控制。', onError: rig.errors.add);
      await rig.quiet();
      final state = await rig.native.snapshot();
      rig.record('deepseek-control', state, state, null);
      expect(rig.resolverCalls, 1);
      expect(rig.audioWire.map((row) => row['method']), ['open', 'stop']);
      expect(rig.wire, isEmpty);
      expect(rig.errors, hasLength(1));
      expect(rig.errors.single, isA<DeepSeekSpeechError>());
      expect(rig.container.read(readAloudProvider).phase, ReadAloudPhase.idle);
      expect(rig.externalCalls, 0);
    } finally { await rig.close(); }
  });
}
