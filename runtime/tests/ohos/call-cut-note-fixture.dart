import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/companion/companion_voice.dart';
import 'package:dsh_app/companion/companion_voice_source.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/app_notes.dart';
import 'package:dsh_app/platform_boundary.dart' as selected_os;
import 'package:dsh_app/speech/call/voice_call.dart';
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/speech_out.dart';
import 'package:dsh_app/speech/voice_cloud.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Finite service boundaries. No heard/progress calculation is implemented here.
class FiniteSpeech implements DeepSeekSpeech {
  FiniteSpeech(this.bytes);
  final int bytes;
  final asked = <String>[];
  int closes = 0;
  @override
  DeepSeekSpeechRoute get route => DeepSeekSpeechRoute.apiKey;
  @override
  Stream<Uint8List> synthesize(String text, {String voice = 'stella'}) async* {
    asked.add(text);
    yield Uint8List(bytes);
  }

  @override
  Future<String> transcribe(Uint8List wav) async =>
      throw StateError('not used');
  @override
  void close() => closes++;
}

class FiniteRecognizer implements VoiceCloud {
  int calls = 0;
  @override
  int get maxSeconds => 118;
  @override
  Future<String> transcribe(Uint8List wav) async =>
      ++calls == 1 ? '请说一句话' : '换个话题吧';
}

class RecordingConversation implements CallConversation {
  final sent = <String>[];
  final repliesController = StreamController<CallReply>.broadcast(sync: true);
  @override
  Future<bool> send(String text) async {
    sent.add(text);
    return true;
  }

  @override
  Stream<CallReply> get replies => repliesController.stream;
  @override
  Future<void> interrupt() async {}
  @override
  bool get waiting => false;
  @override
  void dispose() {}
}

Future<void> until(bool Function() condition) async {
  final limit = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(limit)) {
      throw StateError('finite boundary timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

class HeardRig {
  HeardRig(this.text, {this.pcmBytes = 3840, this.platform = 'ohos'});
  final String text;
  final int pcmBytes;
  final String platform;
  static const channel = MethodChannel('dsh/speech');
  static const diagnostics = MethodChannel('dsh/diagnostics');
  static const unusedPhone = MethodChannel('test/heard-prefix-unused-phone');
  static const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final wire = <Map<String, Object?>>[];
  final events = <Map<String, Object?>>[];
  final noteArgs = <String>[];
  final conversation = RecordingConversation();
  final recognition = FiniteRecognizer();
  late final synthesis = FiniteSpeech(pcmBytes);
  late final SpeechAudio audio;
  late final CompanionVoice phone;
  late final CompanionSpeaker speaker;
  late final VoiceCallController call;
  late SpeechOut output;
  String streamId = '';
  int written = 0;
  bool eof = false;

  Future<void> start() async {
    selected_os.Platform.operatingSystem = platform;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map? ?? const {};
      wire.add({
        'method': call.method,
        'args': {
          for (final key in args.keys)
            key.toString(): args[key] is Uint8List
                ? {'bytes': (args[key] as Uint8List).length}
                : args[key],
        },
      });
      switch (call.method) {
        case 'callStart':
          return 'ok';
        case 'callSpeaker':
          return args['on'];
        case 'open':
          streamId = args['id'] as String;
          return true;
        case 'write':
          written += (args['bytes'] as Uint8List).length;
          return 0;
        case 'waiting':
          return 0;
        case 'end':
          eof = true;
          return null;
        case 'duck':
        case 'stop':
        case 'callStop':
        case 'callPlaying':
          return null;
        default:
          throw StateError('unexpected platform method ${call.method}');
      }
    });
    messenger.setMockMethodCallHandler(diagnostics, (_) async => null);
    messenger.setMockMethodCallHandler(unusedPhone, (_) async => null);
    audio = platform == 'ohos'
        ? SpeechAudio.ohos(channel)
        : SpeechAudio(channel);
    phone = CompanionVoice(unusedPhone);
    speaker = CompanionSpeaker(
      phone,
      () => throw StateError('HTTP forbidden in this test'),
      () async => throw StateError('file output unused in this test'),
    );
    call = VoiceCallController(
      audio: audio,
      conversation: conversation,
      recognizer: () async => recognition,
      voice: () => output = speechOutFor(
        const CompanionVoiceSettings(source: CompanionVoiceSource.deepseek),
        deepseek: () async => synthesis,
        audio: audio,
        speaker: speaker,
        call: true,
        levels: true,
      ),
      choices: () async => (
        bargeIn: true,
        speaker: true,
        spokenHint: null,
        pause: CallPause.normal,
      ),
      cutNote: (heard) {
        noteArgs.add(heard);
        return appNote(
          heard.isEmpty
              ? appL10n.speechCallCutEarly
              : appL10n.speechCallCutNote(heard),
        );
      },
    );
    expect(utf8.decode(utf8.encode(text)), text);
    await call.start();
    expect(call.phase, CallPhase.listening);
    await utterance(false);
    await until(() => conversation.sent.length == 1);
    conversation.repliesController.add(CallReply(text, done: true));
    await until(() => eof);
    expect(written, pcmBytes);
    expect(synthesis.asked, [text]);
    expect(
      output.runtimeType.toString(),
      platform == 'ohos' ? '_OhosDeepSeekOut' : 'DeepSeekOut',
    );
    await event({'type': 'play', 'id': streamId, 'what': 'start'});
  }

  Future<void> event(Map<String, Object?> value) async {
    events.add({
      for (final entry in value.entries)
        entry.key: entry.value is Uint8List
            ? {'bytes': (entry.value as Uint8List).length}
            : entry.value,
    });
    final ack = Completer<void>();
    // Real codec and SpeechAudio handler, with the platform as an explicit
    // boundary. No ETS/renderer/phone or acoustic-progress assertion.
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall('event', value)),
      (_) => ack.complete(),
    );
    await ack.future;
    await pumpEventQueue();
  }

  Future<void> utterance(bool over) async {
    await event({'type': 'speechStart', 'over': over});
    await event({'type': 'utterance', 'wav': Uint8List(32044), 'ms': 600});
  }

  Future<String> tick() async {
    await event({'type': 'playLevel', 'id': streamId, 'value': 0.0});
    return output.heard;
  }

  Future<void> done() async {
    await event({'type': 'play', 'id': streamId, 'what': 'done'});
    await until(() => output.ended && call.phase == CallPhase.listening);
  }

  void record(String name, Map<String, Object?> values) {
    debugPrint(
      'CUT_NOTE_1380 ${jsonEncode({
        'case': name,
        'platformSelection': platform,
        'inputCodeUnits': text.codeUnits,
        'factoryType': output.runtimeType.toString(),
        'synthesisAskedCodeUnits': synthesis.asked.map((s) => s.codeUnits).toList(),
        'writtenBytes': written,
        'eofBeforeProgress': eof,
        'heardCodeUnits': output.heard.codeUnits,
        'captionCodeUnits': call.caption.codeUnits,
        'turns': call.turns.map((t) => {'herCodeUnits': t.her.codeUnits, 'cut': t.cut}).toList(),
        'noteArguments': noteArgs.map((s) => s.codeUnits).toList(),
        'sendArguments': conversation.sent.map((s) => s.codeUnits).toList(),
        'wire': wire,
        'events': events,
        ...values,
      })}',
    );
  }

  Future<void> close() async {
    call.hangUp();
    await pumpEventQueue();
    call.dispose();
    audio.dispose();
    speaker.dispose();
    phone.dispose();
    await conversation.repliesController.close();
    await pumpEventQueue();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(diagnostics, null);
    messenger.setMockMethodCallHandler(unusedPhone, null);
    selected_os.Platform.operatingSystem = 'ohos';
  }
}
