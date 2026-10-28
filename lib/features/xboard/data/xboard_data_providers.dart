import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/features/xboard/config/xboard_config.dart';
import 'package:hiddify/features/xboard/data/xboard_api_client.dart';
import 'package:hiddify/features/xboard/data/xboard_profile_bridge.dart';
import 'package:hiddify/features/xboard/data/xboard_session_store.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final xboardClientConfigProvider = Provider<XboardClientConfig>((ref) {
  return XboardClientConfig.fromEnvironment();
});

final xboardApiProvider = Provider<XboardApi>((ref) {
  final config = ref.watch(xboardClientConfigProvider);
  final appInfo = ref.watch(appInfoProvider).valueOrNull;
  final userAgent = appInfo?.userAgent ?? 'HiddifyNext/5.0.0';
  final client = XboardApiClient(config: config, userAgent: userAgent);
  ref.onDispose(client.close);
  return client;
});

final xboardSessionStoreProvider = Provider<XboardSessionStore>((ref) {
  return SecureXboardSessionStore();
});

final xboardProfileBridgeProvider = Provider<XboardProfileBridge>((ref) {
  return RiverpodXboardProfileBridge(ref);
});
