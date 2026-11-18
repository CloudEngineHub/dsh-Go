import 'dart:async';

import 'package:dsh_app/state/workspace_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// Only the Host carrier is a finite boundary. The directory notifier, its
// keep-alive timer, Riverpod disposal, ClientWorkspaceSource, RPC and mux are real.
class WorkspaceCarrier extends DshCarrier {
  final trace = <Map<String, Object?>>[];
  final held = Completer<RpcResult>();
  final links = <WorkspaceLink>[];
  int lists = 0;
  int completedLists = 0;
  String phase = 'initial';

  void note(String kind, [Map<String, Object?> extra = const {}]) {
    trace.add({'sequence': trace.length, 'phase': phase, 'kind': kind, ...extra});
  }

  RpcResult answer(int ordinal) => RpcOk({
    'path': '/work/lib',
    'entries': [
      {'name': 'snapshot-$ordinal', 'type': 'directory'},
    ],
    'truncated': false,
  });

  @override
  String get kind => 'finite-workspace-boundary';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint != 'workspaceFiles/list') {
      throw StateError('Unexpected unary request: $endpoint');
    }
    final ordinal = ++lists;
    note('rpc', {'endpoint': endpoint, 'args': args, 'ordinal': ordinal});
    final result = ordinal == 2 ? await held.future : answer(ordinal);
    completedLists++;
    note('rpc-reply', {'ordinal': ordinal});
    return result;
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final link = WorkspaceLink(this);
    links.add(link);
    return link;
  }

  @override
  Future<void> close() async {
    note('carrier-close');
  }
}

class WorkspaceLink implements DshMuxLink {
  WorkspaceLink(this.carrier);

  final WorkspaceCarrier carrier;
  DshMuxFrameHandler? _onFrame;
  String? watchId;
  final cancelled = <String>[];

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) {
    _onFrame = onFrame;
  }

  void item(String id, Object value) {
    carrier.note('mux-item', {'id': id, 'value': value});
    _onFrame?.call({'type': 'item', 'streamId': id, 'value': value});
  }

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    carrier.note('mux-open', {'id': streamId, 'endpoint': endpoint, 'payload': payload});
    if (endpoint == r'$events') {
      scheduleMicrotask(
        () => item(streamId, {
          'type': 'ready',
          'clientId': 'finite-client',
          'host': {'home': '/work'},
        }),
      );
    } else if (endpoint == 'workspaceFiles/changes') {
      watchId = streamId;
      scheduleMicrotask(() => item(streamId, {'kind': 'ready'}));
    } else {
      throw StateError('Unexpected stream: $endpoint');
    }
  }

  void change(String version) => item(watchId!, {
    'kind': 'change',
    'change': {'absolutePath': '/work/lib', 'version': version},
  });

  @override
  void cancel(String streamId) {
    cancelled.add(streamId);
    carrier.note('mux-cancel', {'id': streamId});
  }

  @override
  void sendItem(String streamId, Object? value) {}

  @override
  void endUplink(String streamId) {}

  @override
  Future<void> close(int code, String reason) async {
    carrier.note('link-close', {'code': code, 'reason': reason});
  }
}

final class WorkspaceObserver extends ProviderObserver {
  WorkspaceObserver(this.target, this.carrier);

  final Object target;
  final WorkspaceCarrier carrier;
  int disposals = 0;
  int unmounts = 0;
  final labels = <String>[];

  @override
  void didDisposeProvider(ProviderObserverContext context) {
    if (context.provider != target) return;
    disposals++;
    carrier.note('provider-dispose');
  }

  @override
  void didUnmountProvider(ProviderObserverContext context) {
    if (context.provider != target) return;
    unmounts++;
    carrier.note('provider-unmount');
  }

  @override
  void didUpdateProvider(ProviderObserverContext context, Object? previousValue, Object? newValue) {
    if (context.provider != target || newValue is! WorkspaceDir) return;
    final names = newValue.entries.map((entry) => entry.name).toList();
    labels.addAll(names);
    carrier.note('provider-update', {'loaded': newValue.loaded, 'names': names});
  }
}

Future<void> drainWorkspace(WidgetTester tester) async {
  for (var turn = 0; turn < 6; turn++) {
    await tester.pump();
  }
}
