import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/app_notes.dart';
import 'package:flutter_test/flutter_test.dart';

import 'call-cut-note-fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppLocale.use(AppLocale.zhCN);
  final yi29 = List.filled(29, '乙').join();
  final yi28 = List.filled(28, '乙').join();
  final yi30 = List.filled(30, '乙').join();
  final bing30 = List.filled(30, '丙').join();
  final oldSplitSuffix = '…${String.fromCharCode(0xdfb7)}$yi29';
  final cases =
      <
        ({
          String name,
          String platform,
          String prefix,
          String expected,
          bool validTail,
        })
      >[
        (
          name: 'OH BMP keeps the original last30 suffix',
          platform: 'ohos',
          prefix: '甲乙$bing30',
          expected: '…$bing30',
          validTail: true,
        ),
        (
          name:
              'OH supplementary Chinese crossing the suffix start stays whole',
          platform: 'ohos',
          prefix: '甲𠮷$yi29',
          expected: '…$yi29',
          validTail: true,
        ),
        (
          name: 'OH emoji crossing the suffix start stays whole',
          platform: 'ohos',
          prefix: '甲😀$yi29',
          expected: '…$yi29',
          validTail: true,
        ),
        (
          name: 'OH pair exactly at the suffix start remains included',
          platform: 'ohos',
          prefix: '甲乙𠮷$yi28',
          expected: '…𠮷$yi28',
          validTail: true,
        ),
        (
          name: 'OH pair ending before the suffix start remains excluded',
          platform: 'ohos',
          prefix: '𠮷$yi30',
          expected: '…$yi30',
          validTail: true,
        ),
        (
          name: 'OH short heard keeps its complete supplementary character',
          platform: 'ohos',
          prefix: '短𠮷文',
          expected: '短𠮷文',
          validTail: true,
        ),
        (
          name: 'OH exactly30 units keeps the whole original heard without ellipsis',
          platform: 'ohos',
          prefix: '𠮷$yi28',
          expected: '𠮷$yi28',
          validTail: true,
        ),
        (
          name: 'Android keeps its existing UTF16 suffix behavior',
          platform: 'android',
          prefix: '甲𠮷$yi29',
          expected: oldSplitSuffix,
          validTail: false,
        ),
        (
          name: 'Default host keeps its existing UTF16 suffix behavior',
          platform: 'linux',
          prefix: '甲𠮷$yi29',
          expected: oldSplitSuffix,
          validTail: false,
        ),
      ];

  for (final entry in cases) {
    test(entry.name, () async {
      // A finite single-span closed PCM response and one real progress event
      // produce exactly this valid prefix. No heard or cutNote algorithm is
      // supplied by the fixture. The suffix expectations above are explicit.
      final text =
          '${entry.prefix}${List.filled(entry.prefix.length, '丁').join()}';
      expect(utf8.decode(utf8.encode(text)), text);
      final rig = HeardRig(text, platform: entry.platform);
      try {
        await rig.start();
        final heard = await rig.tick();
        final caption = rig.call.caption;
        expect(heard, entry.prefix);
        expect(caption, entry.prefix);
        expect(utf8.decode(utf8.encode(heard)), heard);
        await rig.utterance(true);
        await until(() => rig.conversation.sent.length == 2);
        expect(rig.call.turns.first.cut, isTrue);
        expect(rig.call.turns.first.her, entry.prefix);
        expect(rig.noteArgs, hasLength(1));
        final argument = rig.noteArgs.single;
        final sent = rig.conversation.sent.last;
        final actualNote = appNote(appL10n.speechCallCutNote(argument));
        final expectedNote = appNote(appL10n.speechCallCutNote(entry.expected));
        rig.record(entry.name, {
          'beforeCutHeard': heard.codeUnits,
          'beforeCutCaption': caption.codeUnits,
          'expectedNoteArgument': entry.expected.codeUnits,
          'actualProductionNoteCodeUnits': actualNote.codeUnits,
          'expectedSendCodeUnits': '$expectedNote\n换个话题吧'.codeUnits,
          'noteRoundTrip': utf8.decode(utf8.encode(argument)).codeUnits,
          'sentRoundTrip': utf8.decode(utf8.encode(sent)).codeUnits,
          'locale': AppLocale.current.toLanguageTag(),
          'callbackScope': 'Unchanged production page expression with actual appNote and appL10n; no Widget or ChatCall transport execution',
        });
        expect(sent, '$actualNote\n换个话题吧');
        expect(argument.codeUnits, entry.expected.codeUnits);
        expect(sent.codeUnits, '$expectedNote\n换个话题吧'.codeUnits);
        if (entry.prefix.length > 30) {
          expect(argument.startsWith('…'), isTrue);
          expect(argument.length - 1, lessThanOrEqualTo(30));
        } else {
          expect(argument, entry.prefix);
        }
        if (entry.validTail) {
          expect(utf8.decode(utf8.encode(argument)), argument);
          expect(utf8.decode(utf8.encode(sent)), sent);
        } else {
          // This is an explicit unchanged default/Android policy control,
          // not a claim that its old split is valid or tested on a phone.
          expect(utf8.decode(utf8.encode(argument)), isNot(argument));
        }
      } finally {
        await rig.close();
      }
    });
  }
}
