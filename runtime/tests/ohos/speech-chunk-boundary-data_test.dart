import 'dart:async';
import 'dart:convert';
import 'dart:io' as host;
import 'dart:typed_data';

import 'package:dsh_app/companion/companion_voice_source.dart';
import 'package:dsh_app/platform_boundary.dart' as selected_os;
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/speech_out.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Reuse the existing transport/SDK boundary, not a copy of a business class.
import 'read-aloud-preflight-data_test.dart' as previous;

bool validPairs(String text) {
  for (var index = 0; index < text.length; index++) {
    final unit = text.codeUnitAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index >= text.length) return false;
      final low = text.codeUnitAt(index);
      if (low < 0xdc00 || low > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

Future<void> until(bool Function() predicate) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!predicate()) {
    if (DateTime.now().isAfter(end))
      throw StateError('finite boundary timed out');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class RecordingSpeech implements DeepSeekSpeech {
  final asked = <String>[];
  int closes = 0;
  @override
  DeepSeekSpeechRoute get route => DeepSeekSpeechRoute.apiKey;
  @override
  Stream<Uint8List> synthesize(String text, {String voice = 'stella'}) async* {
    asked.add(text);
    // A finite synthesis boundary, not HTTP, a model, or real speech samples.
    yield Uint8List(16);
  }

  @override
  Future<String> transcribe(Uint8List wav) async =>
      throw StateError('not used');
  @override
  void close() => closes++;
}

void record(String name, Map<String, Object?> values) {
  debugPrint('SPEECH_CHUNK_1373 ${jsonEncode({'case': name, ...values})}');
}

Future<void> systemCase(
  String name,
  String input, {
  int? splitAt,
  int firstCalls = 1,
}) async {
  final rig = previous.Rig(await previous.Native.start(), holdReady: 0);
  SpeechOut? stream;
  var beforeContinuation = <String>[];
  try {
    if (splitAt == null) {
      await rig.controller.toggle(
        'unicode-content',
        input,
        onError: rig.errors.add,
      );
    } else {
      expect(await rig.speaker.ready(previous.system), isTrue);
      stream = speechOutFor(
        previous.system,
        deepseek: () async => null,
        audio: rig.container.read(speechAudioProvider),
        speaker: rig.speaker,
      );
      stream.add(input.substring(0, splitAt));
      beforeContinuation = previous.texts(await rig.untilTexts(firstCalls));
      await rig.quiet();
      beforeContinuation = previous.texts(await rig.native.snapshot());
      stream
        ..add(input.substring(splitAt))
        ..finish();
    }
    await rig.untilTexts(1);
    await rig.quiet();
    final snapshot = await rig.native.snapshot();
    final texts = previous.texts(snapshot);
    record(name, {
      'kind': 'actual-OH-system-consumer-codec-ETS',
      'inputCodeUnits': input.codeUnits,
      'beforeContinuation': beforeContinuation,
      'sdkTexts': texts,
      'wire': rig.wire,
      'nativeSnapshot': snapshot,
      'controllerErrors': rig.errors.map((value) => value.toString()).toList(),
    });
    expect(rig.errors, isEmpty);
    expect(rig.externalCalls, 0);
    expect(rig.resolverCalls, 0);
    expect(texts.every((text) => text.length <= 200), isTrue);
    expect(texts.join(), input);
    expect(texts.join(), isNot(contains('\ufffd')));
    if (splitAt != null) {
      expect(
        beforeContinuation.join(),
        input.substring(0, splitAt - 1),
        reason: 'a trailing high surrogate waits; preceding complete text is released',
      );
    }
  } finally {
    stream?.stop();
    await rig.quiet();
    await rig.close();
  }
}

Future<void> deepSeekCase(String name, String input, {int? splitAt}) async {
  final rig = previous.Rig(await previous.Native.start(), holdReady: 0);
  final speech = RecordingSpeech();
  final out = speechOutFor(
    const CompanionVoiceSettings(source: CompanionVoiceSource.deepseek),
    deepseek: () async => speech,
    audio: rig.container.read(speechAudioProvider),
    speaker: rig.speaker,
  );
  final beforeContinuation = <List<int>>[];
  try {
    expect(out.runtimeType.toString(), '_OhosDeepSeekOut');
    if (splitAt == null) {
      out.add(input);
    } else {
      out.add(input.substring(0, splitAt));
      await until(() => speech.asked.isNotEmpty);
      beforeContinuation.addAll(speech.asked.map((text) => text.codeUnits));
      out.add(input.substring(splitAt));
    }
    out.finish();
    await until(
      () => rig.audioWire.any(
        (row) => row['method'] == 'end' && row.containsKey('nativeReply'),
      ),
    );
    await rig.quiet();
    record(name, {
      'kind': 'actual-OH-DeepSeekOut-synthesis-input-boundary',
      'inputCodeUnits': input.codeUnits,
      'beforeContinuationCodeUnits': beforeContinuation,
      'synthesizeInputCodeUnits': speech.asked
          .map((text) => text.codeUnits)
          .toList(),
      'allSynthesisInputsHavePairedSurrogates': speech.asked.every(validPairs),
      'audioWire': rig.audioWire,
      'nativeSnapshot': await rig.native.snapshot(),
      'HTTPRequests': 0,
    });
    expect(speech.asked.every((text) => text.length <= 300), isTrue);
    expect(speech.asked.join(), input);
    expect(
      speech.asked.every(validPairs),
      isTrue,
      reason: 'each actual synthesize input must keep complete input pairs',
    );
    if (splitAt != null) {
      expect(
        beforeContinuation.expand((units) => units).toList(),
        input.substring(0, splitAt - 1).codeUnits,
      );
    }
  } finally {
    out.stop();
    await rig.quiet();
    await rig.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    // Every case selects its platform before constructing/taking a chunker.
    selected_os.Platform.operatingSystem = 'ohos';
    SharedPreferences.setMockInitialValues({
      'speech_voice_v1': jsonEncode({'source': 'system'}),
    });
  });

  for (final item in <({String name, String text})>[
    (name: 'OH system BMP long text', text: '中' * 600),
    (
      name: 'OH system intact pair before max200',
      text: '${'中' * 198}𠮷${'文' * 199}',
    ),
    (
      name: 'OH system supplementary Chinese across max200',
      text: '${'中' * 199}𠮷${'文' * 199}',
    ),
    (
      name: 'OH system emoji between Chinese across max200',
      text: '${'中' * 199}😀${'文' * 199}',
    ),
  ]) {
    test(item.name, () => systemCase(item.name, item.text));
  }
  test(
    'OH system nonfinal high surrogate waits for the next delta',
    () =>
        systemCase('system-delta', '${'中' * 199}𠮷${'文' * 199}', splitAt: 200),
  );
  test(
    'OH system complete sentence is released before a trailing high surrogate',
    () {
      const prefix = '这是一句完整的话。';
      return systemCase(
        'system-sentence-before-delta',
        '$prefix${'中' * 199}𠮷文文文文文',
        splitAt: prefix.length + 200,
        firstCalls: 2,
      );
    },
  );

  for (final item in <({String name, String text, int? split})>[
    (name: 'OH DeepSeek BMP max300 control', text: '中' * 600, split: null),
    (
      name: 'OH DeepSeek intact pair before max300',
      text: '${'中' * 298}𠮷${'文' * 299}',
      split: null,
    ),
    (
      name: 'OH DeepSeek supplementary Chinese across max300',
      text: '${'中' * 299}𠮷${'文' * 299}',
      split: null,
    ),
    (
      name: 'OH DeepSeek nonfinal high surrogate waits for next delta',
      text: '${'中' * 299}𠮷${'文' * 299}',
      split: 300,
    ),
  ]) {
    test(
      item.name,
      () => deepSeekCase(item.name, item.text, splitAt: item.split),
    );
  }

  test('OH first pause and later target retain existing grouping', () {
    final out = SpeechChunker(first: 8, target: 20, max: 60);
    out.add('好的，这周末北京以晴为主，周六最高二十度');
    expect(out.take(), ['好的，这周末北京以晴为主，']);
    out.add('，周日有小雨。');
    expect(out.take(), isEmpty);
    expect(out.take(final_: true), ['周六最高二十度，周日有小雨。']);
  });
  test('OH numbers and time preserve the existing comma rules', () {
    final out = SpeechChunker(first: 4);
    out.add('门票是1,000元，3:30开门');
    expect(out.take(), ['门票是1,000元，']);
    expect(out.take(final_: true), ['3:30开门']);
  });
  test(
    'OH whitespace trim and no-letter-or-digit filtering stay unchanged',
    () {
      final out = SpeechChunker(first: 1);
      out.add('  😀……\n好。  ');
      expect(out.take(final_: true), ['好。']);
      expect(speakable('```\ncode\n```'), isEmpty);
    },
  );
  test('OH final short valid supplementary text is emitted once', () {
    final out = SpeechChunker(first: 8, target: 60, max: 200);
    out.add('𠮷的短句');
    expect(out.take(), isEmpty);
    expect(out.take(final_: true), ['𠮷的短句']);
    expect(out.take(final_: true), isEmpty);
  });

  for (final platform in ['android', host.Platform.operatingSystem]) {
    for (final max in [200, 300]) {
      test('$platform max$max preserves the exact existing non-OH cut', () {
        expect(platform, isNot('ohos'));
        selected_os.Platform.operatingSystem = platform;
        final input = '${'中' * (max - 1)}𠮷${'文' * (max - 1)}';
        final out = SpeechChunker(first: 8, target: 60, max: max)..add(input);
        final pieces = out.take(final_: true);
        expect(pieces.map((text) => text.codeUnits).toList(), [
          input.substring(0, max).codeUnits,
          input.substring(max).codeUnits,
        ]);
        const codec = StandardMethodCodec();
        final received = pieces
            .map(
              (text) =>
                  (codec
                              .decodeMethodCall(
                                codec.encodeMethodCall(
                                  MethodCall('speak', {'text': text}),
                                ),
                              )
                              .arguments
                          as Map)['text']
                      as String,
            )
            .join();
        expect(
          received.runes.where((unit) => unit == 0xfffd).length,
          2,
          reason:
              'this OH fix does not rewrite the existing Android/host contract',
        );
        record('$platform-$max', {
          'kind': 'non-OH-old-cut-control',
          'pieceCodeUnits': pieces.map((text) => text.codeUnits).toList(),
          'codecReplacementCharacters': 2,
        });
      });
    }
  }
}
