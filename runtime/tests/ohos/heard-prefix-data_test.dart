import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'heard-prefix-fixture.dart';

void expectValidPrefix(String original, String value) {
  expect(original.startsWith(value), isTrue);
  expect(utf8.decode(utf8.encode(value)), value,
      reason: 'valid original text must yield a prefix of complete Unicode scalars');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('OH pair boundary before inside and after advances monotonically', () async {
    final rig = HeardRig('甲𠮷乙', pcmBytes: 7680);
    try {
      await rig.start();
      final prefixes = [await rig.tick(), await rig.tick(), await rig.tick()];
      rig.record('paired-progress', {'prefixes': prefixes.map((s) => s.codeUnits).toList()});
      expect(prefixes, ['甲', '甲', '甲𠮷']);
      for (final text in prefixes) {
        expectValidPrefix(rig.text, text);
      }
    } finally {
      await rig.close();
    }
  });

  test('OH first supplementary character waits until its low surrogate', () async {
    final rig = HeardRig('𠮷乙甲', pcmBytes: 7680);
    try {
      await rig.start();
      final prefixes = [await rig.tick(), await rig.tick()];
      rig.record('leading-pair', {'prefixes': prefixes.map((s) => s.codeUnits).toList()});
      expect(prefixes, ['', '𠮷']);
      for (final text in prefixes) {
        expectValidPrefix(rig.text, text);
      }
    } finally {
      await rig.close();
    }
  });

  test('OH done still returns the complete original text', () async {
    final rig = HeardRig('甲𠮷乙');
    try {
      await rig.start();
      final half = await rig.tick();
      await rig.done();
      rig.record('done-full', {'intermediateCodeUnits': half.codeUnits});
      expect(rig.output.heard, rig.text);
      expect(rig.call.caption, rig.text);
      expect(rig.call.turns.single.her, rig.text);
      expectValidPrefix(rig.text, rig.output.heard);
    } finally {
      await rig.close();
    }
  });

  test('OH BMP proportional prefixes keep their existing values', () async {
    final rig = HeardRig('甲乙丙丁', pcmBytes: 7680);
    try {
      await rig.start();
      final prefixes = [await rig.tick(), await rig.tick(), await rig.tick()];
      rig.record('bmp-progress', {'prefixes': prefixes.map((s) => s.codeUnits).toList()});
      expect(prefixes, ['甲', '甲乙', '甲乙丙']);
    } finally {
      await rig.close();
    }
  });

  test('OH actual VoiceCall cut keeps caption turn and next note valid', () async {
    final rig = HeardRig('甲𠮷乙');
    try {
      await rig.start();
      final heard = await rig.tick();
      final caption = rig.call.caption;
      await rig.utterance(true);
      await until(() => rig.conversation.sent.length == 2);
      rig.record('actual-cut-in', {'beforeCutHeard': heard.codeUnits, 'beforeCutCaption': caption.codeUnits});
      expect(heard, '甲');
      expect(caption, heard);
      expect(rig.call.turns.first.cut, isTrue);
      expect(rig.call.turns.first.her, heard);
      expect(rig.noteArgs, [heard]);
      expect(rig.conversation.sent.last, '（被打断在：甲）\n换个话题吧');
      expectValidPrefix(rig.text, heard);
      for (final text in rig.noteArgs.followedBy(rig.conversation.sent)) {
        expect(utf8.decode(utf8.encode(text)), text);
      }
    } finally {
      await rig.close();
    }
  });

  for (final platform in ['android', 'linux']) {
    test('$platform factory preserves the existing non-OH substring behavior', () async {
      final rig = HeardRig('甲𠮷乙', platform: platform);
      try {
        await rig.start();
        final heard = await rig.tick();
        rig.record('legacy-$platform', {'observedCodeUnits': heard.codeUnits});
        // This is an unchanged-branch control, not a claim that malformed
        // legacy prefixes are desirable or that Android hardware was tested.
        expect(heard.codeUnits, [0x7532, 0xd842]);
        await rig.done();
        expect(rig.output.heard, rig.text);
      } finally {
        await rig.close();
      }
    });
  }
}
