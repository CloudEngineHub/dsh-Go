import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/companion/companion_voice.dart';
import 'package:dsh_app/companion/companion_voice_source.dart';
import 'package:dsh_app/platform_boundary.dart' as selected_os;
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/read_aloud.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/speech_out.dart';
import 'package:dsh_app/speech/speech_settings.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const voiceChannel = MethodChannel('dsh/companion_voice');
const pcmChannel = MethodChannel('dsh/speech');
const systemSettings = CompanionVoiceSettings(source: CompanionVoiceSource.system);
const deepSeekSettings = CompanionVoiceSettings(source: CompanionVoiceSource.deepseek);
const fakeKey = '1391-TEST-ONLY-NOT-A-CREDENTIAL';
const oldText = '较早发起的系统试听。';
const readText = '较晚发起的外部朗读正文。';
final finitePcm = Uint8List.fromList(List<int>.generate(16, (index) => index));

// Configuration/storage boundary only. The speech resolver itself is not overridden.
class TestSettings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(apiKey: fakeKey, loaded: true, autoStartLocal: false);
}

class FiniteHttp extends http.BaseClient {
  FiniteHttp(this.log) {
    body = StreamController<List<int>>(
      onListen: () {
        listening = true;
        log('http-body-listen');
      },
      onCancel: () {
        bodyOnCancelObserved = true;
        log('http-body-cancel');
      },
    );
  }
  final void Function(String, [Map<String, Object?>]) log;
  late final StreamController<List<int>> body;
  final requests = <Map<String, Object?>>[];
  bool listening = false, bodyOnCancelObserved = false, eofRequested = false;
  int closeCalls = 0;
  Future<void>? ending;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    final record = <String, Object?>{
      'method': request.method,
      'url': request.url.toString(),
      'headers': Map<String, String>.from(request.headers),
      'body': utf8.decode(bytes),
    };
    requests.add(record);
    log('http-send-finite-client', record);
    if (requests.length != 1) throw StateError('This finite model permits one synthesis request');
    if (request.url.toString() != 'https://api.deepseek.com/v1/tools/tts') {
      throw StateError('Unexpected destination; no network client is used');
    }
    return http.StreamedResponse(body.stream, 200, headers: {'content-type': 'application/octet-stream'});
  }

  void supply() {
    if (!listening || eofRequested || bodyOnCancelObserved) throw StateError('PCM must enter the live finite response');
    log('http-body-bytes', {'bytes': finitePcm.toList()});
    body.add(finitePcm);
  }

  Future<void> finish(String reason) {
    if (!eofRequested) {
      eofRequested = true;
      log('http-body-eof-request', {'reason': reason});
      ending = body.close();
    }
    return ending!;
  }

  @override
  void close() {
    closeCalls++;
    log('http-client-close', {'count': closeCalls});
    unawaited(finish('actual-direct-owner.close'));
  }
}

class ForbiddenEncodedClient extends http.BaseClient {
  ForbiddenEncodedClient(this.onRequest);
  final void Function() onRequest;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    onRequest();
    throw StateError('Encoded external synthesis is outside this observation');
  }
}

class Native {
  Native(this.process) {
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final row = jsonDecode(line) as Map<String, dynamic>;
      rawRows.add(row);
      if (row['event'] case final Map envelope) {
        final channel = envelope['channel'] as String;
        if (channel != voiceChannel.name && channel != pcmChannel.name) {
          throw StateError('Unexpected native event channel: $channel');
        }
        final args = envelope['args'] as Map;
        events.add(envelope);
        final bytes = const StandardMethodCodec().encodeMethodCall(MethodCall(envelope['method'] as String, args));
        final delivered = Completer<void>();
        eventDeliveries.add(delivered.future);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(channel, bytes, (_) {
          delivered.complete();
        });
      } else {
        final result = pending.remove(row['id']);
        if (row.containsKey('error')) {
          result?.completeError(StateError('${row['error']}'));
        } else {
          result?.complete(row['result']);
        }
      }
    });
    process.stderr.transform(utf8.decoder).listen(stderr.write);
  }
  final Process process;
  final pending = <int, Completer<Object?>>{};
  final events = <Map>[], rawRows = <Map>[];
  final eventDeliveries = <Future<void>>[];
  final stderr = StringBuffer();
  int serial = 0;
  static Future<Native> start() async {
    final native = Native(
      await Process.start(Platform.environment['NODE']!, [Platform.environment['PENDING_PREVIEW_RPC']!]),
    );
    // Initialize the actual stdin sink before later shutdown; not a product method.
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
  Future<Map> close() async {
    final last = await ask('close') as Map;
    await process.stdin.close().timeout(const Duration(seconds: 10));
    expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0, reason: stderr.toString());
    return last;
  }
}

List<String> ttsTexts(Map snapshot) => [
  for (final engine in snapshot['engines'] as List)
    for (final call in (engine as Map)['calls'] as List) (call as Map)['text'] as String,
];
Map? acceptedStream(Map snapshot, String id) {
  for (final value in snapshot['accepted'] as List) {
    if ((value as Map)['id'] == id) return value;
  }
  return null;
}

// Every hold has a finite limit. A timeout is never accepted as cancellation.
class DeliveryGate {
  DeliveryGate(this.name, this.mark, {this.expectedReady});
  final String name;
  final bool? expectedReady;
  final void Function(String, [Map<String, Object?>]) mark;
  final entered = Completer<void>(), delivery = Completer<void>();
  bool outstanding = false;
  String? settlement, releaseReason;
  Future<void> hold() async {
    outstanding = true;
    mark('transport-held', {'name': name});
    entered.complete();
    try {
      await delivery.future.timeout(const Duration(seconds: 20));
      settlement = releaseReason == 'research-cleanup' ? 'cleanup' : 'explicit';
      mark('transport-released', {'name': name, 'reason': releaseReason, 'settlement': settlement});
    } on TimeoutException {
      settlement = 'timeout';
      mark('transport-timeout', {'name': name});
      rethrow;
    } finally {
      outstanding = false;
      mark('transport-hold-ended', {'name': name, 'settlement': settlement});
    }
  }

  void release(String reason) {
    expect(outstanding, isTrue);
    expect(delivery.isCompleted, isFalse);
    expect(settlement, isNull);
    releaseReason = reason;
    mark('transport-explicit-release', {'name': name, 'reason': reason});
    delivery.complete();
  }

  void releaseForCleanup() {
    if (!delivery.isCompleted) {
      releaseReason = 'research-cleanup';
      delivery.complete();
    }
  }

  Map<String, Object?> record() => {
    'name': name,
    'expectedReady': expectedReady,
    'outstanding': outstanding,
    'settlement': settlement,
    'releaseReason': releaseReason,
  };
}

class PreviewObservation {
  PreviewObservation(this.text);
  final String text;
  bool completed = false;
  String? value, thrown;
  late final Future<void> observed;
  Map<String, Object?> record() => {'text': text, 'completed': completed, 'value': value, 'thrown': thrown};
}

class Rig {
  Rig(this.native, {this.platform = 'ohos'}) {
    selected_os.Platform.operatingSystem = platform ?? 'linux';
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(voiceChannel, (call) async {
      final row = <String, Object?>{'channel': voiceChannel.name, 'method': call.method, 'arguments': call.arguments};
      methodWire.add(row);
      mark('dart-method-start', row);
      final ordinal = call.method == 'ready' ? ++readyCalls : null;
      final reply = await native.ask('voice', {'method': call.method, 'arguments': call.arguments}) as Map;
      row['nativeReply'] = reply;
      if (ordinal != null) row['readyOrdinal'] = ordinal;
      mark('dart-received-native-reply', row);
      final gate = readyGates[ordinal];
      if (gate != null) {
        expect(reply, {
          'value': gate.expectedReady,
        }, reason: 'Native computes the expected value before delivery is held');
        await gate.hold();
      }
      if (reply['error'] case final String code) throw PlatformException(code: code);
      return reply['value'];
    });
    messenger.setMockMethodCallHandler(pcmChannel, (call) async {
      final row = <String, Object?>{'channel': pcmChannel.name, 'method': call.method, 'arguments': call.arguments};
      methodWire.add(row);
      mark('dart-method-start', row);
      final gate = openGate;
      if (call.method == 'open' && gate != null && !gate.entered.isCompleted) await gate.hold();
      // The declared JSON transport restores Uint8List at the Node boundary.
      final reply = await native.ask('audio', {'method': call.method, 'arguments': call.arguments}) as Map;
      row['nativeReply'] = reply;
      mark('dart-received-native-reply', row);
      if (call.method == 'open' && reply['value'] == true) pcmId = (call.arguments as Map)['id'] as String;
      if (reply['error'] case final String code) throw PlatformException(code: code);
      return reply['value'];
    });
    container = ProviderContainer(
      overrides: [
        if (platform != null) operatingSystemProvider.overrideWithValue(platform!),
        activeConnectionProvider.overrideWithValue(const AsyncData(null)),
        settingsProvider.overrideWith(TestSettings.new),
        deepSeekSpeechHttpProvider.overrideWithValue(() {
          final index = httpClients.length;
          mark('http-client-factory', {'client': index, 'creationStack': StackTrace.current.toString()});
          final client = FiniteHttp((kind, [values = const {}]) => mark(kind, {'client': index, ...values}));
          httpClients.add(client);
          return client;
        }),
        companionVoiceClientProvider.overrideWithValue(
          () => ForbiddenEncodedClient(() {
            encodedRequests++;
          }),
        ),
      ],
    );
    speaker = container.read(speechSpeakerProvider);
    controller = container.read(readAloudProvider.notifier);
    stateSubscription = container.listen(readAloudProvider, (_, value) {
      mark('read-aloud-state', {'id': value.id, 'phase': value.phase.name});
    }, fireImmediately: true);
    audioSubscription = container.read(speechAudioProvider).events.listen((event) {
      if (event is PlayEvent) {
        final row = <String, Object?>{'id': event.id, 'phase': event.phase.name};
        audioEvents.add(row);
        mark('decoded-pcm-event', row);
      } else if (event is PlayLevel) {
        mark('decoded-pcm-level', {'id': event.id, 'value': event.value});
      }
    });
    voiceSubscription = speaker.events.listen((event) {
      mark('decoded-shared-speaker-event', {
        'type': event.type.name,
        'id': event.id,
        'start': event.start,
        'end': event.end,
      });
    });
  }
  final Native native;
  final String? platform;
  late final ProviderContainer container;
  late final CompanionSpeaker speaker;
  late final ReadAloudController controller;
  late final ProviderSubscription<ReadAloudState> stateSubscription;
  late final StreamSubscription<SpeechAudioEvent> audioSubscription;
  late final StreamSubscription<CompanionVoiceEvent> voiceSubscription;
  final httpClients = <FiniteHttp>[];
  final readyGates = <int, DeliveryGate>{};
  DeliveryGate? openGate;
  final previews = <PreviewObservation>[];
  final timeline = <Map<String, Object?>>[],
      methodWire = <Map<String, Object?>>[],
      audioEvents = <Map<String, Object?>>[];
  final errors = <String>[], toggleReturns = <String>[];
  final snapshots = <String, Object?>{};
  int serial = 0, readyCalls = 0, encodedRequests = 0;
  bool disposed = false;
  String? pcmId, previousReadPcmId;
  int expectedReadClientIndex = 0;
  final clientsByPcmId = <String, FiniteHttp>{};
  void mark(String kind, [Map<String, Object?> values = const {}]) {
    timeline.add({'seq': ++serial, 'kind': kind, ...values});
  }

  Map<String, Object?> state() {
    final value = container.read(readAloudProvider);
    return {'id': value.id, 'phase': value.phase.name};
  }

  Future<void> initialize() async {
    expect(speaker is OhosSpeechSpeaker, platform == 'ohos');
    expect(container.read(activeConnectionProvider).value, isNull);
    expect(container.read(settingsProvider).apiKey, fakeKey);
    final settings = await container.read(speechVoiceSettingsProvider.notifier).ready();
    expect(settings.source, CompanionVoiceSource.system);
    mark('initial-settings-ready', {
      'source': settings.source.name,
      'speaker': speaker.runtimeType.toString(),
      'platformOverride': platform,
      'actualOSProvider': container.read(operatingSystemProvider),
    });
  }

  DeliveryGate holdReady(int ordinal, bool value) =>
      readyGates[ordinal] = DeliveryGate('ready-$ordinal', mark, expectedReady: value);
  PreviewObservation beginPreview([String text = oldText]) {
    final result = PreviewObservation(text);
    previews.add(result);
    mark('public-preview-call', {'source': 'system', 'text': text});
    result.observed = speaker
        .preview(systemSettings, text)
        .then<void>(
          (value) {
            result.completed = true;
            result.value = value;
            mark('public-preview-completed', {'text': text, 'result': value});
          },
          onError: (Object error, StackTrace stack) {
            result.completed = true;
            result.thrown = error.toString();
            mark('public-preview-threw', {'text': text, 'error': result.thrown});
          },
        );
    return result;
  }

  Future<void> beginDeepSeek([String id = 'new-message']) async {
    mark('public-settings-update-start', {'source': 'deepseek'});
    await container.read(speechVoiceSettingsProvider.notifier).update(deepSeekSettings);
    mark('public-settings-update-return', {'source': container.read(speechVoiceSettingsProvider)!.source.name});
    expect(identical(container.read(speechSpeakerProvider), speaker), isTrue);
    expectedReadClientIndex = httpClients.length;
    previousReadPcmId = pcmId;
    mark('public-toggle-call', {
      'id': id,
      'text': readText,
      'expectedNewClientIndex': expectedReadClientIndex,
      'previousPcmId': previousReadPcmId,
    });
    await controller.toggle(
      id,
      readText,
      onError: (error) {
        errors.add(error.toString());
        mark('read-aloud-onError', {'error': error.toString()});
      },
    );
    toggleReturns.add(id);
    mark('public-toggle-return', state());
  }

  Future<Map> until(bool Function(Map) condition, String stage) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      final value = await native.snapshot();
      if (condition(value)) return value;
      if (DateTime.now().isAfter(deadline)) throw StateError('Finite frontier not reached: $stage');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> quiet() async {
    for (var i = 0; i < 4; i++) {
      await pumpEventQueue();
      await Future.wait(native.eventDeliveries.toList()).timeout(const Duration(seconds: 10));
    }
  }

  Future<Map> startWrittenPcm() async {
    // Non-OH DeepSeekOut opens after its first HTTP chunk; do not impose OH order on it.
    final clientIndex = expectedReadClientIndex;
    final previousId = previousReadPcmId;
    await until(
      (_) => httpClients.length > clientIndex && httpClients[clientIndex].listening,
      'this read actual resolver creates its own finite HTTP listener',
    );
    final client = httpClients[clientIndex];
    expect(httpClients.length, clientIndex + 1);
    expect(client.requests, hasLength(1));
    final request = client.requests.single;
    expect((request['headers'] as Map)['authorization'], 'Bearer $fakeKey');
    expect((jsonDecode(request['body'] as String) as Map)['text'], readText);
    client.supply();
    final written = await until(
      (value) =>
          pcmId != null &&
          pcmId != previousId &&
          acceptedStream(value, pcmId!)?['writes'] is List &&
          (acceptedStream(value, pcmId!)!['writes'] as List).isNotEmpty,
      'actual SpeechPlugin write acknowledgment',
    );
    clientsByPcmId[pcmId!] = client;
    mark('read-client-pcm-bound', {'client': clientIndex, 'pcmId': pcmId, 'previousPcmId': previousId});
    final writes = acceptedStream(written, pcmId!)!['writes'] as List;
    expect((writes.single as Map)['bytes'], finitePcm.toList());
    expect((writes.single as Map)['result'], finitePcm.length);
    expect(acceptedStream(written, pcmId!)!['endAccepted'], isFalse);
    expect(client.eofRequested, isFalse);
    await native.ask('pcm-sdk', {'id': pcmId, 'event': 'start'});
    await until(
      (_) => container.read(readAloudProvider).phase == ReadAloudPhase.playing,
      'decoded finite Backend start',
    );
    return native.snapshot();
  }

  Map stream(Map snapshot, String id) {
    final accepted = acceptedStream(snapshot, id)!;
    return (snapshot['streams'] as List)[accepted['streamIndex'] as int] as Map;
  }

  void expectCurrentUnfinished(Map snapshot, String id) {
    expect(stream(snapshot, id)['current'], isTrue);
    expect(stream(snapshot, id)['closed'], isFalse);
    expect(acceptedStream(snapshot, id)!['endAccepted'], isFalse);
    expect(audioEvents.where((e) => e['id'] == id && e['phase'] != 'start'), isEmpty);
    expect(clientsByPcmId[id]!.eofRequested, isFalse);
  }

  int phoneStops() => methodWire.where((row) => row['channel'] == voiceChannel.name && row['method'] == 'stop').length;
  Future<void> finishNatural(String reason) async {
    final id = pcmId!;
    await clientsByPcmId[id]!.finish(reason).timeout(const Duration(seconds: 10));
    await until((value) => acceptedStream(value, id)!['endAccepted'] == true, 'actual end after finite HTTP EOF');
    await native.ask('pcm-sdk', {'id': id, 'event': 'done'});
    await until(
      (_) =>
          container.read(readAloudProvider).phase == ReadAloudPhase.idle &&
          audioEvents.any((e) => e['id'] == id && e['phase'] == 'done'),
      'decoded finite Backend done',
    );
    await quiet();
  }

  Future<Map> releaseAndSettle(DeliveryGate gate, PreviewObservation preview, String reason) async {
    final before = await native.snapshot();
    expect(preview.completed, isFalse);
    expect(ttsTexts(before), isNot(contains(preview.text)));
    mark('release-preconditions-confirmed', {'preview': preview.text, ...gate.record()});
    gate.release(reason);
    return settlePreview(preview);
  }

  Future<Map> settlePreview(PreviewObservation preview) async {
    final frontier = await until(
      (value) => preview.completed || ttsTexts(value).contains(preview.text),
      'public preview completion or real SDK speak',
    );
    snapshots['frontier-${preview.text}'] = frontier;
    // Settle actual old-source acceptance, so policy assertions fail without a hung SDK request.
    if (ttsTexts(frontier).contains(preview.text)) {
      await native.ask('tts-sdk', {'text': preview.text, 'event': 'start'});
      await native.ask('tts-sdk', {'text': preview.text, 'event': 'done'});
    }
    await preview.observed.timeout(const Duration(seconds: 10));
    await quiet();
    final after = await native.snapshot();
    snapshots['settled-${preview.text}'] = after;
    if (!disposed) snapshots['state-settled-${preview.text}'] = state();
    return after;
  }

  void disposeContainer() {
    mark('public-container-dispose');
    stateSubscription.close();
    container.dispose();
    disposed = true;
  }

  Future<void> close() async {
    mark('research-cleanup-start');
    for (final gate in readyGates.values) {
      gate.releaseForCleanup();
    }
    openGate?.releaseForCleanup();
    final snap = await native.snapshot();
    if (snap['createDeferred'] == true && snap['createReleased'] != true) await native.ask('release-create');
    if (!disposed) {
      controller.stop();
      disposeContainer();
    }
    await audioSubscription.cancel();
    await voiceSubscription.cancel();
    for (final client in httpClients) {
      // No future is claimed to complete for a never-listened synthetic body.
      if (client.listening || client.bodyOnCancelObserved) {
        await client.finish('research-cleanup').timeout(const Duration(seconds: 10));
      } else {
        mark('research-unlistened-body-boundary', {'client': httpClients.indexOf(client)});
      }
    }
    for (final preview in previews) {
      await preview.observed.timeout(const Duration(seconds: 10));
    }
    await quiet();
    snapshots['afterCleanup'] = await native.close();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(voiceChannel, null);
    messenger.setMockMethodCallHandler(pcmChannel, null);
    mark('research-cleanup-completed');
  }

  void record(String name, String? failure) {
    debugPrint(
      'PENDING_PREVIEW_1391 ${jsonEncode({
        'case': name,
        'failure': failure,
        'speakerType': speaker.runtimeType.toString(),
        'platformOverride': platform,
        'selectedPlatform': selected_os.Platform.operatingSystem,
        'timeline': timeline,
        'methodWire': methodWire,
        'nativeRows': native.rawRows,
        'nativeEvents': native.events,
        'decodedPcmEvents': audioEvents,
        'snapshots': snapshots,
        'readyGates': readyGates.values.map((gate) => gate.record()).toList(),
        'openGate': openGate?.record(),
        'previews': previews.map((preview) => preview.record()).toList(),
        'toggleReturns': toggleReturns,
        'onError': errors,
        'readyCalls': readyCalls,
        'encodedRequests': encodedRequests,
        'httpClients': [
          for (final client in httpClients) {'requests': client.requests, 'listening': client.listening, 'eofRequested': client.eofRequested, 'bodyOnCancelObserved': client.bodyOnCancelObserved, 'closeCalls': client.closeCalls},
        ],
        'nativeStderr': native.stderr.toString(),
      })}',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'speech_voice_v1': jsonEncode({'source': 'system'}),
    });
    selected_os.Platform.operatingSystem = 'ohos';
  });
  void scenario(
    String name,
    Future<void> Function(Rig) run, {
    String? platform = 'ohos',
    Map<String, Object?> nativeOptions = const {},
  }) {
    test('1391 $name', () async {
      final native = await Native.start();
      await native.ask('configure', nativeOptions);
      final rig = Rig(native, platform: platform);
      String? failure;
      try {
        await rig.initialize();
        await run(rig);
        expect(rig.encodedRequests, 0);
        rig.snapshots['beforeCleanup'] = await native.snapshot();
        if (!rig.disposed) rig.snapshots['stateBeforeCleanup'] = rig.state();
      } catch (error) {
        failure = error.toString();
        rethrow;
      } finally {
        try {
          await rig.close();
        } finally {
          rig.record(name, failure);
        }
      }
    }, timeout: const Timeout(Duration(seconds: 75)));
  }

  scenario('OH no pending preview: actual direct resolver completes normally', (rig) async {
    await rig.beginDeepSeek();
    rig.snapshots['written'] = await rig.startWrittenPcm();
    expect(ttsTexts(rig.snapshots['written'] as Map), isEmpty);
    await rig.finishNatural('normal-control');
    expect(rig.errors, isEmpty);
    expect(rig.readyCalls, 0);
    expect(rig.httpClients, hasLength(1));
  });

  for (final readyValue in [true, false]) {
    scenario('OH pending actual ready $readyValue: new DeepSeek creation retires old preview', (rig) async {
      final gate = rig.holdReady(1, readyValue);
      final preview = rig.beginPreview();
      await gate.entered.future.timeout(const Duration(seconds: 10));
      final stopsBefore = rig.phoneStops();
      rig.snapshots['beforeNewRead'] = await rig.native.snapshot();
      await rig.beginDeepSeek();
      final written = rig.snapshots['writtenBeforeRelease'] = await rig.startWrittenPcm();
      rig.expectCurrentUnfinished(written as Map, rig.pcmId!);
      expect(rig.phoneStops(), stopsBefore, reason: 'Logical retirement sends no additional phone stop');
      final settled = await rig.releaseAndSettle(gate, preview, 'new-read-created-and-written');
      expect(gate.settlement, 'explicit');
      expect(preview.value, 'cancelled');
      expect(preview.thrown, isNull);
      expect(ttsTexts(settled), isEmpty);
      rig.expectCurrentUnfinished(settled, rig.pcmId!);
      expect(rig.errors, isEmpty);
      if (readyValue) {
        expect((settled['engines'] as List).single['shutdowns'], 0, reason: 'Pure prewarm is not shut down');
      }
      await rig.finishNatural('target-after-policy-observation');
    }, nativeOptions: {'createError': !readyValue});
  }

  scenario('OH new PCM open rejects: original read error remains and old preview does not revive', (rig) async {
    final gate = rig.holdReady(1, true);
    final preview = rig.beginPreview();
    await gate.entered.future.timeout(const Duration(seconds: 10));
    final stopsBefore = rig.phoneStops();
    await rig.beginDeepSeek();
    final failed = await rig.until(
      (value) =>
          (value['trace'] as List).contains('pcm.open.reject') &&
          rig.errors.length == 1 &&
          rig.container.read(readAloudProvider).phase == ReadAloudPhase.idle,
      'actual SpeechPlugin rejects Backend open and read-aloud reports error',
    );
    rig.snapshots['newPcmRejected'] = failed;
    expect(rig.httpClients, isEmpty, reason: 'Actual OH output rejects before resolver/synthesis');
    expect(rig.phoneStops(), stopsBefore, reason: 'Original PCM stop cleanup is a different channel');
    final settled = await rig.releaseAndSettle(gate, preview, 'new-read-failed-after-creation');
    expect(gate.settlement, 'explicit');
    expect(preview.value, 'cancelled');
    expect(ttsTexts(settled), isEmpty);
    expect(rig.errors, hasLength(1));
    expect(rig.state()['phase'], 'idle');
  }, nativeOptions: {'pcmOpenReject': true});

  scenario('OH old ready finally preserves later pending preview marker through a second real read', (rig) async {
    final aGate = rig.holdReady(1, true);
    final a = rig.beginPreview('旧试听 A。');
    await aGate.entered.future.timeout(const Duration(seconds: 10));
    await rig.beginDeepSeek('read-B');
    rig.snapshots['B-written'] = await rig.startWrittenPcm();
    final cGate = rig.holdReady(2, true);
    final c = rig.beginPreview('后续试听 C。');
    await cGate.entered.future.timeout(const Duration(seconds: 10));
    await rig.releaseAndSettle(aGate, a, 'A-late-after-C-ready-held');
    expect(a.value, 'cancelled');
    expect(c.completed, isFalse);
    expect(cGate.outstanding, isTrue);
    final stopsBeforeD = rig.phoneStops();
    await rig.beginDeepSeek('read-D');
    rig.snapshots['D-written-before-C-release'] = await rig.startWrittenPcm();
    expect(rig.phoneStops(), stopsBeforeD);
    final settled = await rig.releaseAndSettle(cGate, c, 'D-creation-after-A-finally');
    expect(cGate.settlement, 'explicit');
    expect(c.value, 'cancelled', reason: 'Public behavior proves old A finally did not erase C pending marker');
    expect(ttsTexts(settled), isEmpty);
    rig.expectCurrentUnfinished(settled, rig.pcmId!);
    expect(rig.httpClients, hasLength(2));
    expect(identical(rig.httpClients.first, rig.httpClients.last), isFalse);
    expect(rig.errors, isEmpty);
    await rig.finishNatural('D-normal-completion');
  });

  scenario('OH already submitted preview: create point itself leaves it alone before real PCM claim', (rig) async {
    final preview = rig.beginPreview();
    await rig.until((value) => ttsTexts(value).contains(oldText), 'actual system speak already submitted');
    await rig.native.ask('tts-sdk', {'text': oldText, 'event': 'start'});
    expect(preview.completed, isFalse);
    final gate = rig.openGate = DeliveryGate('PCM-open-before-native-handler', rig.mark);
    final stopsBefore = rig.phoneStops();
    await rig.beginDeepSeek();
    await gate.entered.future.timeout(const Duration(seconds: 10));
    await rig.quiet();
    rig.snapshots['createdButNativePcmNotClaimed'] = await rig.native.snapshot();
    expect(preview.completed, isFalse, reason: 'Only still-awaiting-ready preview is logically retired');
    expect(rig.phoneStops(), stopsBefore);
    gate.release('allow-original-native-PCM-claim');
    rig.snapshots['writtenAfterNativeClaim'] = await rig.startWrittenPcm();
    await preview.observed.timeout(const Duration(seconds: 10));
    expect(preview.value, 'cancelled', reason: 'The original Native PCM claim retires already-submitted TTS');
    expect(ttsTexts(rig.snapshots['writtenAfterNativeClaim'] as Map), [oldText]);
    expect(gate.settlement, 'explicit');
    expect(rig.errors, isEmpty);
    await rig.finishNatural('submitted-preview-control');
  });

  for (final dispose in [false, true]) {
    scenario('OH explicit ${dispose ? 'container dispose' : 'speaker stop'} preserves pending cancellation', (
      rig,
    ) async {
      final gate = rig.holdReady(1, true);
      final preview = rig.beginPreview();
      await gate.entered.future.timeout(const Duration(seconds: 10));
      if (dispose) {
        rig.disposeContainer();
      } else {
        rig.mark('public-speaker-stop');
        rig.speaker.stop();
      }
      final settled = await rig.releaseAndSettle(gate, preview, 'after-explicit-retirement');
      expect(gate.settlement, 'explicit');
      expect(preview.value, 'cancelled');
      expect(ttsTexts(settled), isEmpty);
      expect(rig.httpClients, isEmpty);
      expect(rig.errors, isEmpty);
    });
  }

  for (final platform in <String?>['android', null]) {
    scenario('${platform ?? 'default Linux'} original provider: mixed output behavior remains unchanged', (rig) async {
      final gate = rig.holdReady(1, true);
      final preview = rig.beginPreview();
      await gate.entered.future.timeout(const Duration(seconds: 10));
      await rig.beginDeepSeek();
      rig.snapshots['writtenBeforeOldReady'] = await rig.startWrittenPcm();
      final settled = await rig.releaseAndSettle(gate, preview, 'non-OH-original-behavior');
      expect(gate.settlement, 'explicit');
      expect(preview.value, isNull);
      expect(ttsTexts(settled), [oldText]);
      expect(rig.errors, isEmpty);
      expect(rig.audioEvents.any((e) => e['id'] == rig.pcmId && e['phase'] == 'stopped'), isTrue);
      expect(rig.state()['phase'], 'idle');
    }, platform: platform);
  }

  scenario('OH actual SDK create pending: PCM starts before Native computes ready and late true stays cancelled', (
    rig,
  ) async {
    final preview = rig.beginPreview();
    final pending = await rig.until(
      (value) =>
          (value['trace'] as List).contains('tts.create') && (value['engines'] as List).isEmpty && rig.readyCalls == 1,
      'actual Native initialization still awaits finite SDK create',
    );
    rig.snapshots['actualSdkCreatePending'] = pending;
    expect(rig.methodWire.where((row) => row['method'] == 'ready').single.containsKey('nativeReply'), isFalse);
    final stopsBefore = rig.phoneStops();
    await rig.beginDeepSeek();
    final written = rig.snapshots['writtenBeforeSdkCreateCompletion'] = await rig.startWrittenPcm();
    rig.expectCurrentUnfinished(written as Map, rig.pcmId!);
    expect(preview.completed, isFalse);
    expect(rig.phoneStops(), stopsBefore);
    await rig.native.ask('release-create');
    final settled = await rig.settlePreview(preview);
    expect(rig.methodWire.where((row) => row['method'] == 'ready').single['nativeReply'], {'value': true});
    expect(preview.value, 'cancelled');
    expect(ttsTexts(settled), isEmpty);
    rig.expectCurrentUnfinished(settled, rig.pcmId!);
    expect(rig.errors, isEmpty);
    expect((settled['engines'] as List).single['shutdowns'], 0);
    await rig.finishNatural('SDK-create-pending-control');
  }, nativeOptions: {'createDeferred': true});
}
