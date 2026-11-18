// Effective OH companion settings, using the production providers and their
// real asynchronous preference loader. Only the OS and storage are boundaries;
// no voice, HTTP, platform synthesis or UI implementation is substituted here.
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dsh_app/companion/companion_voice_source.dart';
import 'package:dsh_app/speech/speech_settings.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _secure = FlutterSecureStorage();

Map<String, Object> _preferences(
  CompanionVoiceSettings own, {
  CompanionVoiceSettings? shared,
}) => {
  companionVoiceKeys.on: own.on,
  companionVoiceKeys.plain: jsonEncode(own.plain()),
  if (shared != null) speechVoiceKeys.on: shared.on,
  if (shared != null) speechVoiceKeys.plain: jsonEncode(shared.plain()),
};

Map<String, String> _secrets(
  CompanionVoiceSettings own, {
  CompanionVoiceSettings? shared,
}) => {
  companionVoiceKeys.openaiKey: own.openaiKey,
  companionVoiceKeys.headers: own.customHeaders,
  companionVoiceKeys.presetKeys: jsonEncode(own.presetKeys),
  if (shared != null) speechVoiceKeys.openaiKey: shared.openaiKey,
  if (shared != null) speechVoiceKeys.headers: shared.customHeaders,
  if (shared != null) speechVoiceKeys.presetKeys: jsonEncode(shared.presetKeys),
};

ProviderContainer _container({String? os}) {
  final container = ProviderContainer(
    overrides: [if (os != null) operatingSystemProvider.overrideWithValue(os)],
  );
  addTearDown(container.dispose);
  return container;
}

void _save(CompanionVoiceSettings own, {CompanionVoiceSettings? shared}) {
  SharedPreferences.setMockInitialValues(_preferences(own, shared: shared));
  FlutterSecureStorage.setMockInitialValues(_secrets(own, shared: shared));
}

Future<void> _unchanged(
  CompanionVoiceSettings own, {
  CompanionVoiceSettings? shared,
}) async {
  final preferences = await SharedPreferences.getInstance();
  expect({
    for (final key in preferences.getKeys()) key: preferences.get(key),
  }, _preferences(own, shared: shared));
  expect(await _secure.readAll(), _secrets(own, shared: shared));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('OH remains null while its own real settings have not loaded', () async {
    const own = CompanionVoiceSettings(
      on: true,
      source: CompanionVoiceSource.custom,
    );
    _save(own);
    final container = _container(os: 'ohos');
    expect(container.read(companionEffectiveVoiceProvider), isNull);
    await container.read(companionVoiceSettingsProvider.notifier).ready();
    await _unchanged(own);
  });

  test(
    'OH own external settings resolve to system without rewriting saved data',
    () async {
      for (final source in [
        CompanionVoiceSource.deepseek,
        CompanionVoiceSource.preset,
        CompanionVoiceSource.openai,
        CompanionVoiceSource.custom,
      ]) {
        final own = CompanionVoiceSettings(
          on: true,
          source: source,
          deepseekVoice: 'tide',
          presetKeys: const {'mimo': 'local-test-preset-key'},
          presetVoices: const {'mimo': '茉莉'},
          presetStyle: 'saved style',
          cloneOn: true,
          cloneSample: '/saved/sample.wav',
          openaiKey: 'local-test-openai-key',
          customUrl: 'https://unused.invalid/speech',
          customHeaders: 'Authorization: local-test-header',
        );
        _save(own);
        final container = _container(os: 'ohos');
        final stored = await container
            .read(companionVoiceSettingsProvider.notifier)
            .ready();
        final effective = container.read(companionEffectiveVoiceProvider)!;
        expect(
          effective.source,
          CompanionVoiceSource.system,
          reason: source.name,
        );
        expect(effective.on, isTrue);
        expect(effective.follow, isFalse);
        expect(effective.cloneOn, isFalse);
        expect(effective.plain(), {
          ...stored.plain(),
          'source': 'system',
          'follow': false,
          'cloneOn': false,
        });
        expect(effective.openaiKey, stored.openaiKey);
        expect(effective.customHeaders, stored.customHeaders);
        expect(effective.presetKeys, stored.presetKeys);
        expect(container.read(companionVoiceSettingsProvider), same(stored));
        await _unchanged(own);
      }
    },
  );

  test(
    'OH follows no unloaded shared provider and keeps the own enabled value',
    () async {
      const own = CompanionVoiceSettings(
        on: true,
        follow: true,
        source: CompanionVoiceSource.preset,
      );
      _save(own);
      final container = _container(os: 'ohos');
      await container.read(companionVoiceSettingsProvider.notifier).ready();
      expect(container.exists(speechVoiceSettingsProvider), isFalse);
      final effective = container.read(companionEffectiveVoiceProvider);
      expect(effective, isNotNull);
      expect(effective!.source, CompanionVoiceSource.system);
      expect(effective.on, isTrue);
      expect(effective.follow, isFalse);
      expect(container.exists(speechVoiceSettingsProvider), isFalse);
      await _unchanged(own);
    },
  );

  test(
    'OH already-system settings do not enable a disabled companion',
    () async {
      const own = CompanionVoiceSettings(on: false);
      _save(own);
      final container = _container(os: 'ohos');
      final stored = await container
          .read(companionVoiceSettingsProvider.notifier)
          .ready();
      final effective = container.read(companionEffectiveVoiceProvider)!;
      expect(effective.source, CompanionVoiceSource.system);
      expect(effective.on, isFalse);
      expect(effective.plain(), stored.plain());
      await _unchanged(own);
    },
  );

  test('OH unconfigured external and cloning preferences stay saved while effective voice is system', () async {
    const own = CompanionVoiceSettings(
      on: false,
      source: CompanionVoiceSource.custom,
      cloneOn: true,
      cloneSample: '/saved/sample-only.wav',
    );
    _save(own);
    final container = _container(os: 'ohos');
    final stored = await container
        .read(companionVoiceSettingsProvider.notifier)
        .ready();
    expect(stored.configured, isFalse);
    final effective = container.read(companionEffectiveVoiceProvider)!;
    expect(effective.source, CompanionVoiceSource.system);
    expect(effective.configured, isTrue);
    expect(effective.on, isFalse);
    expect(effective.cloneOn, isFalse);
    expect(effective.cloneSample, own.cloneSample);
    expect(stored.cloneOn, isTrue);
    await _unchanged(own);
  });

  test(
    'OH ignores a loaded shared voice and leaves read-aloud settings untouched',
    () async {
      const own = CompanionVoiceSettings(
        on: false,
        follow: true,
        deepseekVoice: 'tide',
      );
      const shared = CompanionVoiceSettings(
        on: true,
        source: CompanionVoiceSource.openai,
        openaiKey: 'shared-local-key',
      );
      _save(own, shared: shared);
      final container = _container(os: 'ohos');
      await container.read(companionVoiceSettingsProvider.notifier).ready();
      final readAloud = await container
          .read(speechVoiceSettingsProvider.notifier)
          .ready();
      final effective = container.read(companionEffectiveVoiceProvider)!;
      expect(effective.source, CompanionVoiceSource.system);
      expect(effective.on, isFalse);
      expect(effective.follow, isFalse);
      expect(effective.deepseekVoice, own.deepseekVoice);
      expect(container.read(speechVoiceSettingsProvider), same(readAloud));
      expect(readAloud.source, CompanionVoiceSource.openai);
      await _unchanged(own, shared: shared);
    },
  );

  test(
    'Android own voice keeps the original object and cloning choices',
    () async {
      const own = CompanionVoiceSettings(
        on: true,
        source: CompanionVoiceSource.preset,
        cloneOn: true,
        cloneSample: '/saved/android.wav',
      );
      _save(own);
      final container = _container(os: 'android');
      final stored = await container
          .read(companionVoiceSettingsProvider.notifier)
          .ready();
      expect(container.read(companionEffectiveVoiceProvider), same(stored));
      expect(stored.source, CompanionVoiceSource.preset);
      expect(stored.cloneOn, isTrue);
      await _unchanged(own);
    },
  );

  test('Android follow still waits for shared settings and preserves the own off switch', () async {
    const own = CompanionVoiceSettings(on: false, follow: true);
    const shared = CompanionVoiceSettings(
      on: true,
      source: CompanionVoiceSource.preset,
      cloneOn: true,
    );
    _save(own, shared: shared);
    final container = _container(os: 'android');
    await container.read(companionVoiceSettingsProvider.notifier).ready();
    expect(container.read(companionEffectiveVoiceProvider), isNull);
    final readAloud = await container
        .read(speechVoiceSettingsProvider.notifier)
        .ready();
    final effective = container.read(companionEffectiveVoiceProvider)!;
    expect(effective.plain(), {
      ...readAloud.plain(),
      'follow': true,
      'cloneOn': false,
    });
    expect(effective.on, isFalse);
    await _unchanged(own, shared: shared);
  });

  test('default host provider retains the original shared voice and own on semantics', () async {
    const own = CompanionVoiceSettings(on: true, follow: true);
    const shared = CompanionVoiceSettings(
      source: CompanionVoiceSource.openai,
      openaiVoice: 'nova',
    );
    _save(own, shared: shared);
    final container = _container();
    expect(container.read(operatingSystemProvider), Platform.operatingSystem);
    expect(
      Platform.operatingSystem,
      isNot('ohos'),
      reason: 'This is the unchanged Linux host control, not an OH device.',
    );
    await container.read(companionVoiceSettingsProvider.notifier).ready();
    final readAloud = await container
        .read(speechVoiceSettingsProvider.notifier)
        .ready();
    final effective = container.read(companionEffectiveVoiceProvider)!;
    expect(effective.source, CompanionVoiceSource.openai);
    expect(effective.openaiVoice, readAloud.openaiVoice);
    expect(effective.follow, isTrue);
    expect(effective.cloneOn, isFalse);
    expect(effective.on, isTrue);
    await _unchanged(own, shared: shared);
  });
}
