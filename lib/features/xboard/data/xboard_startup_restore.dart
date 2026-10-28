import 'package:hiddify/features/xboard/notifier/xboard_session_controller.dart';

/// Restore only after the panel has validated the saved account and applied
/// its managed subscription. Call this in the background so a slow panel does
/// not hold the desktop window behind the splash screen.
Future<void> restoreXboardConnectionOnStartup({
  required XboardSessionController session,
  required bool Function() connectionAllowed,
  required Future<String?> Function() activeProfileId,
  required Future<void> Function() restoreConnection,
}) async {
  await session.initialize();
  final managedId = session.managedProfileId;
  if (managedId == null || !connectionAllowed()) return;

  final activeId = await activeProfileId();
  // Reading the profile is asynchronous: logout or account switching may
  // have happened while it was pending.
  if (activeId != managedId || session.managedProfileId != managedId || !connectionAllowed()) {
    return;
  }
  await restoreConnection();
}
