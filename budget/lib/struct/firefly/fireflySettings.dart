// The settings of the Firefly III integration.
//
// The Personal Access Token is not in appStateSettings or in sharedPreferences
// (see updateSettings() in lib/struct/settings.dart). That JSON block goes
// into the database backup and into the Google Drive sync, thus a token in it
// goes into a portable .sqlite backup and to each other device. The token is
// in flutter_secure_storage, which uses the key store of the operating system
// on iOS, Android, macOS, Windows and Linux. The web gives less protection;
// see FIREFLY_SYNC_FUTURE_SCOPE.md.
//
// The other values (the enabled flag, the host URL, the time of the last sync)
// are not secret and use the usual settings of the application. After a
// restore the integration is off, because the token does not come back.

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

String get fireflyHostUrl =>
    appStateSettings["fireflyHostUrl"]?.toString() ?? "";

Future<void> setFireflyEnabled(bool enabled) {
  return updateSettings("fireflyEnabled", enabled, updateGlobalState: false);
}

Future<void> setFireflyHostUrl(String url) {
  return updateSettings("fireflyHostUrl", url, updateGlobalState: false);
}

// How far back the routine sync reads.
//
// Firefly is the system of record. This application keeps a recent window of
// it, thus a routine sync stays cheap on a server that holds many years of
// data. It reads an older record on demand (a search, a filter, or an open
// account) and keeps it from then on. A balance anchor carries the balance of
// each account, thus the totals and the net worth stay correct.
const int kFireflyDefaultSyncWindowDays = 30;

// The limits of the value that the user sets.
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

// The first day of the routine sync window. The value goes to midnight
// because the start and end parameters of Firefly hold a date only. A time in
// this value makes the limit different in the request and in the local
// tests.
DateTime fireflySyncWindowStart({DateTime? now}) {
  DateTime reference = now ?? DateTime.now();
  DateTime start = reference.subtract(Duration(days: fireflySyncWindowDays));
  return DateTime(start.year, start.month, start.day);
}

DateTime? get fireflyLastSyncedAt {
  String? iso = appStateSettings["fireflyLastSyncedAt"]?.toString();
  if (iso == null || iso.isEmpty) return null;
  return DateTime.tryParse(iso);
}

Future<void> setFireflyLastSyncedAt(DateTime dateTime) {
  return updateSettings("fireflyLastSyncedAt", dateTime.toIso8601String(),
      updateGlobalState: false);
}

Future<void> clearFireflyLastSyncedAt() {
  return updateSettings("fireflyLastSyncedAt", "", updateGlobalState: false);
}

// The moment of the link to the Firefly host. The routine push sends each
// row that changed after the push watermark. "Push unsynced changes" sends
// each row that changed after this moment and that Firefly does not hold
// yet, thus it does not depend on the watermark. A row from before the link
// is local history, which the user uploads on purpose only (see
// pushExistingLocalHistory in fireflySyncNow).
DateTime? get fireflyLinkedAt {
  String? iso = appStateSettings["fireflyLinkedAt"]?.toString();
  if (iso == null || iso.isEmpty) return null;
  return DateTime.tryParse(iso);
}

Future<void> setFireflyLinkedAt(DateTime dateTime) {
  return updateSettings("fireflyLinkedAt", dateTime.toIso8601String(),
      updateGlobalState: false);
}

Future<void> clearFireflyLinkedAt() {
  return updateSettings("fireflyLinkedAt", "", updateGlobalState: false);
}

// The lower limit of "Push unsynced changes". An installation from before
// the fireflyLinkedAt setting has a watermark only; that watermark never
// moves past a row that a cycle did not push, thus it is a safe limit.
DateTime fireflyUnsyncedSince() {
  return fireflyLinkedAt ?? fireflyLastSyncedAt ?? DateTime(2000);
}

// How a push names the other side of a withdrawal or a deposit.
//
// Firefly books every withdrawal into an expense account and every deposit
// out of a revenue account. This application has no such account: it has a
// description and a category. The push used to send the description as the
// account name, and Firefly then made one account per description ("Lunch",
// "3500", "Atm Withdrawal", "Chocolate for Jannatul Mawa"), which is noise
// that the user has to clean up by hand.
//
// generic:  one account for all of them, the built-in cash account of the
//           Firefly instance. The default.
// category: the account carries the name of the category of the row, so the
//           Firefly expense and revenue accounts mirror the categories.
//
// An account that the row is already linked to, or an account whose name is
// the description or the category, is used in both modes. This decides only
// what happens when there is no such account.
const String kFireflyCounterpartyNamingGeneric = "generic";
const String kFireflyCounterpartyNamingCategory = "category";

String get fireflyCounterpartyNaming {
  return appStateSettings["fireflyCounterpartyNaming"]?.toString() ==
          kFireflyCounterpartyNamingCategory
      ? kFireflyCounterpartyNamingCategory
      : kFireflyCounterpartyNamingGeneric;
}

Future<void> setFireflyCounterpartyNaming(String naming) {
  return updateSettings(
      "fireflyCounterpartyNaming",
      naming == kFireflyCounterpartyNamingCategory
          ? kFireflyCounterpartyNamingCategory
          : kFireflyCounterpartyNamingGeneric,
      updateGlobalState: false);
}
