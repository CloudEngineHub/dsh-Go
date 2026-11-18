import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/platform_boundary.dart' as boundary;
import 'package:dsh_app/state/workspace_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workspace-read-retirement-fixture.dart';

enum _Lifetime { retained, keepAlive, expired }

Future<void> _scenario(
  WidgetTester tester, {
  required String name,
  required String operatingSystem,
  required _Lifetime lifetime,
  required int expectedLists,
  bool publicRefresh = false,
}) async {
  boundary.Platform.operatingSystem = operatingSystem;
  final carrier = WorkspaceCarrier();
  final client = DshClient.withCarrier(carrier);
  final provider = workspaceDirProvider(('s1', 'lib'));
  final observer = WorkspaceObserver(provider, carrier);
  final container = ProviderContainer(
    observers: [observer],
    overrides: [
      workspaceSourceProvider('s1').overrideWithValue(ClientWorkspaceSource(client, 's1')),
      workspaceRootProvider('s1').overrideWithValue('/work'),
    ],
  );
  final subscription = container.listen(provider, (_, _) {});
  var refreshCompletions = 0;
  final refreshErrors = <Object>[];
  try {
    await client.mux.start();
    await drainWorkspace(tester);
    expect(carrier.lists, 1);
    expect(container.read(provider).loaded, isTrue);
    expect(container.read(provider).entries.single.name, 'snapshot-1');
    final link = carrier.links.single;
    final watchId = link.watchId!;

    // A public listener close starts the real product's 30-second keep-alive.
    // This model clock selects a finite order; it is not a phone measurement.
    // The public-refresh case queues while still listened to, then leaves.
    if (!publicRefresh) {
      carrier.phase = lifetime == _Lifetime.retained ? 'listener-kept' : 'listener-closed';
      if (lifetime != _Lifetime.retained) subscription.close();
      await tester.pump(const Duration(seconds: 29));
    }
    expect(observer.disposals, 0);

    carrier.phase = 'first-change';
    link.change('v2');
    await drainWorkspace(tester);
    await tester.pump(const Duration(milliseconds: 250));
    await drainWorkspace(tester);
    expect(carrier.lists, 2);
    expect(carrier.held.isCompleted, isFalse);

    if (publicRefresh) {
      carrier.phase = 'public-refresh-queued';
      final pending = container.read(provider.notifier).refresh();
      unawaited(
        pending.then<void>(
          (_) {
            refreshCompletions++;
            carrier.note('public-refresh-completed');
          },
          onError: (Object error, StackTrace stack) {
            refreshErrors.add(error);
            carrier.note('public-refresh-error', {'error': error.toString()});
          },
        ),
      );
      await drainWorkspace(tester);
      expect(refreshCompletions, 0);
      expect(refreshErrors, isEmpty);
      carrier.phase = 'listener-closed';
      subscription.close();
      await tester.pump(const Duration(milliseconds: 30100));
    } else {
      carrier.phase = 'second-change';
      link.change('v3');
      await drainWorkspace(tester);
      await tester.pump(const Duration(milliseconds: 250));
      await drainWorkspace(tester);
      expect(carrier.lists, 2, reason: 'The second invalidation queues behind finite A.');
      if (lifetime != _Lifetime.keepAlive) {
        carrier.phase = 'keep-alive-expiry';
        await tester.pump(const Duration(milliseconds: 600));
      }
    }
    await drainWorkspace(tester);
    final expired = lifetime == _Lifetime.expired;
    expect(observer.disposals, expired ? 1 : 0);
    expect(observer.unmounts, expired ? 1 : 0);
    final existsBeforeReply = container.exists(provider);
    expect(existsBeforeReply, !expired);
    // watch.cancel() is unawaited by the product. Only local disposal is the
    // ownership prerequisite; no transport cancellation ACK ordering is assumed.
    final watchCancelledBeforeReply = link.cancelled.contains(watchId);
    final updatesBeforeReply = observer.labels.length;

    carrier.phase = 'finite-A-reply';
    carrier.held.complete(carrier.answer(2));
    await drainWorkspace(tester);
    final lateLabels = observer.labels.skip(updatesBeforeReply).toList();
    final facts = <String, Object?>{
      'case': name,
      'operatingSystem': operatingSystem,
      'lifetime': lifetime.name,
      'publicRefresh': publicRefresh,
      'refreshCompletions': refreshCompletions,
      'refreshErrors': refreshErrors.map((error) => error.toString()).toList(),
      'listRequests': carrier.lists,
      'completedListRequests': carrier.completedLists,
      'providerDisposalsBeforeCleanup': observer.disposals,
      'providerUnmountsBeforeCleanup': observer.unmounts,
      'providerExistsBeforeReply': existsBeforeReply,
      'watchCancelledBeforeReply': watchCancelledBeforeReply,
      'watchCancelledAfterReply': link.cancelled.contains(watchId),
      'latePublishedLabels': lateLabels,
      'trace': carrier.trace,
    };
    print('WORKSPACE_1386 ${jsonEncode(facts)}');
    expect(carrier.completedLists, carrier.lists, reason: 'Every finite carrier request completes.');
    for (final row in carrier.trace.where((row) => row['kind'] == 'rpc')) {
      expect(row['args'], {'workspaceFileScopeId': 's1', 'path': '/work/lib'});
    }
    if (publicRefresh) {
      expect(refreshErrors, isEmpty);
      expect(refreshCompletions, 1, reason: 'The public refresh Future must settle even when queued B retires.');
    }
    if (expired) {
      expect(lateLabels, isEmpty, reason: 'Neither finite reply may publish into an expired provider.');
    } else {
      expect(lateLabels, containsAllInOrder(['snapshot-2', 'snapshot-3']));
      expect(container.read(provider).entries.single.name, 'snapshot-3');
    }
    expect(carrier.lists, expectedLists, reason: 'Only a still-owned OH directory may start queued B.');
  } finally {
    subscription.close();
    container.dispose();
    if (!carrier.held.isCompleted) carrier.held.complete(carrier.answer(2));
    await drainWorkspace(tester);
    await client.close();
    await drainWorkspace(tester);
  }
}

void main() {
  testWidgets(
    'OH expired directory drops queued B after finite A',
    (tester) =>
        _scenario(tester, name: 'ohos-expired', operatingSystem: 'ohos', lifetime: _Lifetime.expired, expectedLists: 2),
  );
  testWidgets(
    'OH retained listener still reads necessary B',
    (tester) => _scenario(
      tester,
      name: 'ohos-retained',
      operatingSystem: 'ohos',
      lifetime: _Lifetime.retained,
      expectedLists: 3,
    ),
  );
  testWidgets(
    'OH unlistened directory still reads B during keep-alive',
    (tester) => _scenario(
      tester,
      name: 'ohos-keep-alive',
      operatingSystem: 'ohos',
      lifetime: _Lifetime.keepAlive,
      expectedLists: 3,
    ),
  );
  testWidgets(
    'OH queued public refresh settles after owner disposal',
    (tester) => _scenario(
      tester,
      name: 'ohos-refresh-expired',
      operatingSystem: 'ohos',
      lifetime: _Lifetime.expired,
      expectedLists: 2,
      publicRefresh: true,
    ),
  );
  testWidgets(
    'Android expired directory retains original queued B',
    (tester) => _scenario(
      tester,
      name: 'android-expired',
      operatingSystem: 'android',
      lifetime: _Lifetime.expired,
      expectedLists: 3,
    ),
  );
  testWidgets(
    'default host expired directory retains original queued B',
    (tester) => _scenario(
      tester,
      name: 'linux-expired',
      operatingSystem: 'linux',
      lifetime: _Lifetime.expired,
      expectedLists: 3,
    ),
  );
}
