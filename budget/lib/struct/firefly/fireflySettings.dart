// Settings access for the Firefly III integration.
//
// The Personal Access Token is deliberately kept OUT of appStateSettings/
// sharedPreferences (lib/struct/settings.dart's updateSettings()) because
// that JSON blob round-trips through database backup/restore and the
// existing Google Drive sync - a PAT must never end up embedded in a
// portable .sqlite backup or silently synced to another device. It lives in
// flutter_secure_storage instead (OS keychain/keystore backed on
// iOS/Android/macOS/Windows/Linux; reduced protection on web, a known,
// accepted tradeoff - see FIREFLY_SYNC_FUTURE_SCOPE.md).
//
// Everything else (enabled flag, host url, last synced time) is not
// sensitive and follows the app's normal settings pattern so it shows up
// correctly after a restore (as "off", since the PAT won't have restored).

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:budget/struct/settings.dart';

const String _kFireflyPatSecureStorageKey = "fireflyPersonalAccessToken";

const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

Future<String?> getFireflyPat() {
  return _secureStorage.read(key: _kFireflyPatSecureStorageKey);
}

Future<void> setFireflyPat(String token) {
  return _secureStorage.write(key: _kFireflyPatSecureStorageKey, value: token);
}

Future<void> clearFireflyPat() {
  return _secureStorage.delete(key: _kFireflyPatSecureStorageKey);
}

bool get fireflyEnabled => appStateSettings["fireflyEnabled"] == true;

String get fireflyHostUrl => appStateSettings["fireflyHostUrl"]?.toString() ?? "";

Future<void> setFireflyEnabled(bool enabled) {
  return updateSettings("fireflyEnabled", enabled, updateGlobalState: false);
}

Future<void> setFireflyHostUrl(String url) {
  return updateSettings("fireflyHostUrl", url, updateGlobalState: false);
}

// How far back the routine automatic sync reaches.
//
// Firefly is the system of record; Cashew keeps a rolling recent window of it
// locally so that a routine sync stays cheap regardless of how many years of
// history the server holds. Anything older is fetched on demand (searching,
// filtering, or opening an account) and cached from then on, and each
// account's true balance is carried by a balance anchor so that totals and
// net worth stay correct even though most history is not stored locally.
const int kFireflyDefaultSyncWindowDays = 30;

// Guard rails for the user-configurable value.
const int kFireflyMinSyncWindowDays = 7;
const int kFireflyMaxSyncWindowDays = 3650;

int get fireflySyncWindowDays {
  Object? raw = appStateSettings["fireflySyncWindowDays"];
  int? parsed = raw is int ? raw : int.tryParse(raw?.toString() ?? "");
  if (parsed == null) return kFireflyDefaultSyncWindowDays;
  if (parsed < kFireflyMinSyncWindowDays) return kFireflyMinSyncWindowDays;
  if (parsed > kFireflyMaxSyncWindowDays) return kFireflyMaxSyncWindowDays;
  return parsed;
}

Future<void> setFireflySyncWindowDays(int days) {
  return updateSettings("fireflySyncWindowDays", days,
      updateGlobalState: false);
}

// Start of the routine sync window. Dates are truncated to midnight because
// Firefly's start/end query parameters are date-only - keeping a time
// component here would make the boundary ambiguous between the request we
// send and the comparisons we make locally.
DateTime fireflySyncWindowStart({DateTime? now}) {
  DateTime reference = now ?? DateTime.now();
  DateTime start =
      reference.subtract(Duration(days: fireflySyncWindowDays));
  return DateTime(start.year, start.month, start.day);
}

DateTime? get fireflyLastSyncedAt {
  String? iso = appStateSettings["fireflyLastSyncedAt"]?.toString();
  if (iso == null || iso.isEmpty) return null;
  return DateTime.tryParse(iso);
}

Future<void> setFireflyLastSyncedAt(DateTime dateTime) {
  return updateSettings(
      "fireflyLastSyncedAt", dateTime.toIso8601String(),
      updateGlobalState: false);
}
