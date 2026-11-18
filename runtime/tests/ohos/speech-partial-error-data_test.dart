import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/companion/companion_voice.dart';
import 'package:dsh_app/speech/call/voice_call.dart';
import 'package:dsh_app/speech/read_aloud.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/speech_out.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/test/speech/speech_fakes.dart';
import 'read-aloud-preflight-data_test.dart' as previous;

final pieces = ['第一段${'甲' * 61}。', '第二段${'乙' * 61}。', '第三段${'丙' * 61}。'];

bool failedAt(String mode, int index) => mode == 'all-error' || mode == 'mixed' && index == 1;

SpeechOut actualOut(previous.Rig rig, {SpeechAudio? audio, bool call = false}) => speechOutFor(
  previous.system,
  deepseek: () async => null,
  audio: audio ?? rig.container.read(speechAudioProvider),
  speaker: rig.speaker,
  call: call,
);

Future<void> callbacks(previous.Rig rig, String mode, {int base = 0}) async {
  for (var index = 0; index < pieces.length; index++) {
    await rig.native.ask('sdk', {'index': base + index, 'event': 'start'});
    await rig.quiet();
    await rig.native.ask('sdk', {'index': base + index,
      'event': failedAt(mode, index) ? 'error' : 'complete'});
    await rig.quiet();
  }
}

Future<void> record(String name, previous.Rig rig, SpeechOut out,
    List<SpeechOutEvent> events, {Map<String, Object?> extra = const {}}) async {
  final state = rig.container.read(readAloudProvider);
  debugPrint('SPEECH_PARTIAL_ERROR_1376 ${jsonEncode({
    'case': name, 'nativeSnapshot': await rig.native.snapshot(),
    'wire': rig.wire, 'audioWire': rig.audioWire, 'nativeEvents': rig.native.events,
    'outputEvents': events.map((event) => event.runtimeType.toString()).toList(),
    'ended': out.ended, 'heard': out.heard,
    'readAloudState': {'id': state.id, 'phase': state.phase.name},
    'onErrors': rig.errors.map((error) => '$error').toList(),
    'externalCalls': rig.externalCalls, 'resolverCalls': rig.resolverCalls,
    ...extra,
  })}');
}

void terminalIs(List<SpeechOutEvent> events, {required bool failed}) {
  expect(events.where((event) => event is SpeechOutDone || event is SpeechOutFailed), hasLength(1));
  expect(events.whereType<SpeechOutFailed>(), hasLength(failed ? 1 : 0));
  expect(events.whereType<SpeechOutDone>(), hasLength(failed ? 0 : 1));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'speech_voice_v1': jsonEncode({'source': 'system'}),
    });
  });

  for (final beforeFinish in [false, true]) {
    for (final mode in ['all-done', 'all-error', 'mixed']) {
      test('OH $mode with terminals ${beforeFinish ? "before" : "after"} finish has one natural terminal', () async {
        final rig = previous.Rig(await previous.Native.start(), holdReady: 0);
        SpeechOut? out;
        StreamSubscription<SpeechOutEvent>? sub;
        final events = <SpeechOutEvent>[];
        try {
          expect(rig.speaker, isA<OhosSpeechSpeaker>());
          if (beforeFinish) {
            expect(await rig.speaker.ready(previous.system), isTrue);
            out = actualOut(rig);
            sub = out.events.listen(events.add);
            out.add(pieces.join());
          } else {
            await rig.controller.toggle('three-sentences', pieces.join(), onError: rig.errors.add);
            out = (rig.speaker as OhosSpeechSpeaker).systemOutput as SpeechOut;
            sub = out.events.listen(events.add);
          }
          final accepted = await rig.untilTexts(3);
          expect(previous.texts(accepted), pieces);
          await callbacks(rig, mode);
          if (beforeFinish) {
            expect(out.ended, isFalse);
            expect(events.where((event) => event is SpeechOutDone || event is SpeechOutFailed), isEmpty);
            out.finish();
            await rig.quiet();
          }
          await record('$mode-${beforeFinish ? "terminals-first" : "finish-first"}', rig, out, events,
              extra: {'consumer': beforeFinish ? 'actual speechOutFor streaming lifecycle' : 'actual ReadAloudController.toggle'});
          terminalIs(events, failed: mode != 'all-done');
          expect(out.ended, isTrue);
          expect(out.heard, [for (var index = 0; index < 3; index++) if (!failedAt(mode, index)) pieces[index]].join());
          expect((rig.speaker as OhosSpeechSpeaker).systemOutput, isNull);
          if (!beforeFinish) {
            expect(rig.errors, hasLength(mode == 'all-done' ? 0 : 1));
            expect(rig.container.read(readAloudProvider).phase, ReadAloudPhase.idle);
          }
        } finally {
          out?.stop();
          await sub?.cancel();
          await rig.close();
        }
      });
    }
  }

  test('OH empty system output still finishes as Done', () async {
    final rig = previous.Rig(await previous.Native.start(), holdReady: 0);
    SpeechOut? out;
    StreamSubscription<SpeechOutEvent>? sub;
    final events = <SpeechOutEvent>[];
    try {
      out = actualOut(rig);
      sub = out.events.listen(events.add);
      out.finish();
      await rig.quiet();
      await record('empty', rig, out, events);
      terminalIs(events, failed: false);
      expect(out.ended, isTrue);
      expect(previous.texts(await rig.native.snapshot()), isEmpty);
      expect((rig.speaker as OhosSpeechSpeaker).systemOutput, isNull);
    } finally {
      await sub?.cancel();
      await rig.close();
    }
  });

  for (final preview in [false, true]) {
    test('OH partial error then ${preview ? "shared preview" : "user stop and new read-aloud"} remains cancellation', () async {
      final rig = previous.Rig(await previous.Native.start(), holdReady: 0);
      final events = <SpeechOutEvent>[];
      final nextEvents = <SpeechOutEvent>[];
      StreamSubscription<SpeechOutEvent>? sub, nextSub;
      try {
        await rig.controller.toggle('old', pieces.join(), onError: rig.errors.add);
        final out = (rig.speaker as OhosSpeechSpeaker).systemOutput as SpeechOut;
        sub = out.events.listen(events.add);
        await rig.untilTexts(3);
        await rig.native.ask('sdk', {'index': 0, 'event': 'start'});
        await rig.native.ask('sdk', {'index': 0, 'event': 'error'});
        await rig.quiet();
        expect(out.ended, isFalse);
        expect(rig.errors, isEmpty);
        Future<String?>? sample;
        SpeechOut? nextOut;
        if (preview) {
          sample = rig.speaker.preview(previous.system, '替代试听完整完成。');
        } else {
          rig.controller.stop();
          await rig.controller.toggle('new', '下一次朗读完整完成。', onError: rig.errors.add);
          nextOut = (rig.speaker as OhosSpeechSpeaker).systemOutput as SpeechOut;
          nextSub = nextOut.events.listen(nextEvents.add);
        }
        await rig.untilTexts(4);
        await rig.native.ask('sdk', {'index': 3, 'event': 'start'});
        await rig.quiet();
        final stops = rig.wire.where((row) => row['method'] == 'stop').length;
        // A late callback uses an old SDK-accepted request, already retired
        // by stop/replacement. It must not become the new owner's failure.
        await rig.native.ask('sdk', {'index': 1, 'event': 'error'});
        await rig.quiet();
        await rig.native.ask('sdk', {'index': 3, 'event': 'complete'});
        await rig.quiet();
        final previewResult = sample == null ? null : await sample;
        await record(preview ? 'cancel-to-preview' : 'cancel-to-new-read-aloud', rig, out, events,
            extra: {'previewResult': previewResult,
              'nextOutputEvents': nextEvents.map((event) => event.runtimeType.toString()).toList()});
        terminalIs(events, failed: false);
        if (nextOut != null) terminalIs(nextEvents, failed: false);
        expect(previewResult, isNull);
        expect(out.ended, isTrue);
        expect(rig.errors, isEmpty);
        expect(rig.wire.where((row) => row['method'] == 'stop').length, stops);
        expect(rig.container.read(readAloudProvider).phase, ReadAloudPhase.idle);
      } finally {
        await sub?.cancel();
        await nextSub?.cancel();
        await rig.close();
      }
    });
  }

  for (final platform in ['android', null]) {
    test('${platform ?? "default host"} mixed terminals retain the original aggregate Done', () async {
      final rig = previous.Rig(await previous.Native.start(), platform: platform, holdReady: 0);
      SpeechOut? out;
      StreamSubscription<SpeechOutEvent>? sub;
      final events = <SpeechOutEvent>[];
      try {
        expect(rig.speaker.runtimeType, CompanionSpeaker);
        expect(await rig.speaker.ready(previous.system), isTrue);
        out = actualOut(rig);
        expect(out.runtimeType, SpeakerOut);
        sub = out.events.listen(events.add);
        out..add(pieces.join())..finish();
        await rig.untilTexts(3);
        await callbacks(rig, 'mixed');
        await record('${platform ?? "default"}-original-mixed', rig, out, events,
            extra: {'boundary': 'Original Dart branch with the finite OH native channel fixture; no Android device claim'});
        terminalIs(events, failed: false);
        expect(out.ended, isTrue);
        expect(out.heard, pieces[0] + pieces[2]);
      } finally {
        out?.stop();
        await sub?.cancel();
        await rig.close();
      }
    });
  }

  test('actual VoiceCall consumes OH mixed failure and the next turn has no retained error', () async {
    final rig = previous.Rig(await previous.Native.start(), holdReady: 0);
    // Existing finite capture/recognition/conversation boundaries only. The
    // VoiceCall controller and all created output objects are actual products.
    final audio = FakeAudio();
    final conversation = FakeConversation();
    final cloud = FakeCloud();
    final outs = <SpeechOut>[];
    final eventGroups = <List<SpeechOutEvent>>[];
    final subscriptions = <StreamSubscription<SpeechOutEvent>>[];
    final call = VoiceCallController(
      audio: audio,
      conversation: conversation,
      recognizer: () async => cloud,
      choices: () async => (bargeIn: true, speaker: true, spokenHint: null, pause: CallPause.normal),
      voice: () {
        final out = actualOut(rig, audio: audio, call: true);
        outs.add(out);
        final events = <SpeechOutEvent>[];
        eventGroups.add(events);
        subscriptions.add(out.events.listen(events.add));
        return out;
      },
    );
    Future<void> utterance() async {
      audio.emit(const SpeechStart(over: false));
      audio.emit(Utterance(Uint8List(44 + 32000), const Duration(seconds: 1)));
      await pumpEventQueue();
    }
    try {
      expect(await rig.speaker.ready(previous.system), isTrue);
      await call.start();
      expect(call.phase, CallPhase.listening);
      await utterance();
      expect(call.phase, CallPhase.thinking);
      conversation.reply(pieces.join(), done: true);
      await rig.untilTexts(3);
      await callbacks(rig, 'mixed');
      final firstError = call.error;
      final firstPhase = call.phase;
      final firstOwnerCleared = (rig.speaker as OhosSpeechSpeaker).systemOutput == null;
      await utterance();
      conversation.reply('后续通话回复完整完成。', done: true);
      await rig.untilTexts(4);
      await rig.native.ask('sdk', {'index': 3, 'event': 'start'});
      await rig.native.ask('sdk', {'index': 3, 'event': 'complete'});
      await rig.quiet();
      await record('actual-VoiceCall-mixed', rig, outs.first, eventGroups.first,
          extra: {'firstCallError': firstError?.toString(), 'firstCallPhase': firstPhase.name,
            'firstOwnerCleared': firstOwnerCleared, 'finalCallError': call.error?.toString(),
            'finalCallPhase': call.phase.name, 'captureBoundaryCalls': audio.calls,
            'sentMessages': conversation.sent,
            'nextOutputEvents': eventGroups.last.map((event) => event.runtimeType.toString()).toList()});
      terminalIs(eventGroups.first, failed: true);
      expect(firstError, isNotNull);
      expect(firstPhase, CallPhase.listening);
      expect(firstOwnerCleared, isTrue);
      expect(call.ended, isNull);
      expect(call.error, isNull);
      expect(call.phase, CallPhase.listening);
      terminalIs(eventGroups.last, failed: false);
      expect((rig.speaker as OhosSpeechSpeaker).systemOutput, isNull);
      expect(rig.wire.where((row) => row['method'] == 'speak').every((row) =>
          (row['arguments'] as Map)['call'] == true), isTrue);
    } finally {
      call.dispose();
      for (final sub in subscriptions) { await sub.cancel(); }
      await rig.close();
    }
  });
}
