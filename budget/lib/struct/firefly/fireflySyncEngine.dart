// Two-way sync between the local database and a self-hosted Firefly III
// server. Firefly sync and Google Drive sync are mutually exclusive on one
// installation; the settings page keeps that rule.
//
// Each cycle pulls the categories, the accounts, the counterparties and the
// transactions, applies the remote deletes, refreshes the balance anchors,
// then pushes the categories, the accounts, the transactions and the local
// deletes. The pull is first, thus a remote change is visible before a push
// can write over it.
//
// WINDOW
//
// Firefly is the system of record and can hold many years of data. A routine
// sync reads only a recent range of booking dates (fireflySyncWindowDays,
// default 30 days). The local database gets an older record only when the
// user asks for it: a search, a filter or an open account calls the on-demand
// functions at the end of this file, which read that range and keep it.
//
// The rest of this file must obey two rules:
//
//  1. The local database is an incomplete copy of the remote one. Do not read
//     "not in the local database" as "deleted on the server", or "not on the
//     server" as "deleted in this application", outside of the range that the
//     sync read. See _applyRemoteDeletes.
//  2. The sum of the local rows of a wallet is not its balance. Each synced
//     wallet has a balance anchor row (see fireflyMapper.dart) that holds the
//     total of the data before the window. The value comes from the
//     current_balance field of Firefly. Wallet totals and net worth stay
//     correct because of the anchor. See _refreshBalanceAnchors.
//
// The start and end filters of Firefly apply to the booking date, not to
// updated_at. Thus a change that the user makes today to an old transaction
// is not visible until an on-demand fetch reads that record. The "Sync all
// history" action makes the window larger.

import 'package:drift/drift.dart'
    show
        Value,
        InsertMode,
        BooleanExpressionOperators,
        StringExpressionOperators;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/pages/addWalletPage.dart'
    show initializeBalanceCorrectionCategory;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/firefly/fireflyApiClient.dart';
import 'package:budget/struct/firefly/fireflyMapper.dart';
import 'package:budget/struct/firefly/fireflyModels.dart';
import 'package:budget/struct/firefly/fireflySettings.dart';
import 'package:budget/widgets/util/debouncer.dart';

enum FireflySyncStatus { neverSynced, idle, syncing, error }

class FireflySyncReport {
  int pulledCategories = 0;
  int pulledWallets = 0;
  int pulledTransactions = 0;
  int pushedCategories = 0;
  int pushedWallets = 0;
  int pushedTransactions = 0;
  int deletedLocal = 0;
  int deletedRemote = 0;
  int skippedUnsupported = 0;
  int skippedSubcategories = 0;
  int skippedUnmappedWallet = 0;
  int skippedAmbiguousSplits = 0;
  // Rows that a push held back because their Firefly account is inactive.
  // Each such row has a warning, and the watermark stays at the row.
  int skippedInactiveAccount = 0;
  // Rows that a push held back because the Firefly record they point at sits
  // on another Firefly account. See _pushBlockedByMovedRemoteRow.
  int skippedMovedRemoteRow = 0;
  // Rows that a push held back because the wallet and the Firefly account it
  // is linked to keep different currencies. See _pushBlockedByAccountState.
  int skippedCurrencyMismatch = 0;
  // Rows that were booked before this device was linked to Firefly and that
  // no link points at. They are local history; Firefly may well hold them
  // already under another record. See _pushIsPreLinkHistory.
  int skippedPreLinkHistory = 0;
  // Records of a create whose answer never arrived, found again by their
  // external id and linked instead of imported a second time.
  int recoveredCreates = 0;
  // Rows that a push tried and that Firefly or the network refused. Each one
  // has a warning, and the next cycle tries it again.
  int failedCategories = 0;
  int failedWallets = 0;
  int failedTransactions = 0;
  final List<String> warnings = [];

  int get failedTotal => failedCategories + failedWallets + failedTransactions;

  String summary() {
    List<String> parts = [];
    if (pulledTransactions > 0 || pulledWallets > 0 || pulledCategories > 0) {
      parts.add(
          "pulled $pulledWallets accounts, $pulledCategories categories, $pulledTransactions transactions");
    }
    if (pushedTransactions > 0 || pushedWallets > 0 || pushedCategories > 0) {
      parts.add(
          "pushed $pushedWallets accounts, $pushedCategories categories, $pushedTransactions transactions");
    }
    if (deletedLocal > 0 || deletedRemote > 0) {
      parts.add("deleted $deletedLocal local, $deletedRemote remote");
    }
    if (skippedUnsupported > 0) {
      parts.add("$skippedUnsupported unsupported transactions skipped");
    }
    if (skippedSubcategories > 0) {
      parts.add("$skippedSubcategories subcategories not synced");
    }
    if (skippedUnmappedWallet > 0) {
      parts.add(
          "$skippedUnmappedWallet transactions skipped (wallet not linked)");
    }
    if (skippedAmbiguousSplits > 0) {
      parts.add("$skippedAmbiguousSplits splits skipped (record not known)");
    }
    if (skippedInactiveAccount > 0) {
      parts.add(
          "$skippedInactiveAccount transactions held back (Firefly account "
          "inactive)");
    }
    if (skippedMovedRemoteRow > 0) {
      parts.add("$skippedMovedRemoteRow transactions held back (they belong to "
          "another Firefly account)");
    }
    if (skippedCurrencyMismatch > 0) {
      parts.add("$skippedCurrencyMismatch transactions held back (the account "
          "and the Firefly account have different currencies)");
    }
    if (skippedPreLinkHistory > 0) {
      parts.add("$skippedPreLinkHistory transactions dated before the Firefly "
          "link were not uploaded");
    }
    if (recoveredCreates > 0) {
      parts.add("$recoveredCreates transactions relinked instead of copied");
    }
    if (failedTotal > 0) {
      parts.add("$failedTotal not pushed (see warnings)");
    }
    if (warnings.isNotEmpty) {
      parts.add("${warnings.length} warning(s)");
    }
    return parts.isEmpty ? "Nothing to sync" : parts.join(". ");
  }
}

final ValueNotifier<FireflySyncStatus> fireflySyncStatusNotifier =
    ValueNotifier(FireflySyncStatus.neverSynced);
final ValueNotifier<String?> fireflySyncErrorNotifier = ValueNotifier(null);
final ValueNotifier<FireflySyncReport?> fireflySyncReportNotifier =
    ValueNotifier(null);

bool _canSyncFirefly = true;

// True while a cycle runs. fireflySyncNow returns false for a second call
// during that cycle, and that is not a failure: the caller shows a different
// message for it.
bool get fireflySyncIsRunning => !_canSyncFirefly;
// A depth counter, not a flag. An on-demand fetch can start and stop while a
// sync is in operation. A flag that the fetch clears would make the remaining
// writes of that sync look like user edits, which starts one more push each
// cycle.
int _applyingFireflyWriteDepth = 0;
bool get _applyingFireflyWrites => _applyingFireflyWriteDepth > 0;
bool _userEditDuringSync = false;
final Debouncer fireflyPushDebouncer = Debouncer(milliseconds: 5000);

// Makes each piece of engine work that reads Firefly and writes to the local
// database run in sequence: the routine sync and each on-demand fetch at the
// end of this file.
//
// _canSyncFirefly stops only a second sync. It does not stop an on-demand
// fetch. Without this queue a fetch and a sync can be in _pullTransactions for
// the same Firefly group together, read the sync map before either one writes
// to it, and each insert its own local copy of that remote transaction.
Future<void> _fireflyEngineQueue = Future<void>.value();

Future<T> _withFireflyEngineLock<T>(Future<T> Function() body) {
  Future<T> result = _fireflyEngineQueue.then((_) => body());
  // The queue must continue after a failure, or one exception stops the
  // engine for the remaining life of the application. The caller that awaits
  // result still gets the error.
  _fireflyEngineQueue = result.then<void>((_) {}, onError: (Object _) {});
  return result;
}

// An edit that arrives while the engine works sets _userEditDuringSync (see
// scheduleFireflyPush). Each piece of engine work calls this at its end, thus
// the edit gets its push. A cycle that is still running consumes the flag in
// its own finally block: _canSyncFirefly is false until then.
void _reschedulePushIfEditedDuringWork() {
  if (!_userEditDuringSync) return;
  if (!_canSyncFirefly) return;
  _userEditDuringSync = false;
  fireflyPushDebouncer.run(() {
    fireflySyncNow(pushOnly: true);
  });
}

void scheduleFireflyPush() {
  if (!fireflyEnabled) return;
  if (_applyingFireflyWrites) {
    // This is true for the writes of the engine, but a user edit in the same
    // period looks the same here. To return and record nothing loses that
    // edit, because the watermark moves in each case. Record it, thus one more
    // cycle runs when this one stops. A wrong guess costs one empty sync.
    _userEditDuringSync = true;
    return;
  }
  if (!_canSyncFirefly) {
    _userEditDuringSync = true;
    return;
  }
  fireflyPushDebouncer.run(() {
    fireflySyncNow();
  });
}

Future<T> _withFireflyWrites<T>(Future<T> Function() action) async {
  _applyingFireflyWriteDepth++;
  try {
    return await action();
  } finally {
    _applyingFireflyWriteDepth--;
  }
}

Future<FireflyAbout> testFireflyConnection(
    String hostUrl, String personalAccessToken) async {
  FireflyApiClient client = FireflyApiClient(
    baseUrl: hostUrl,
    personalAccessToken: personalAccessToken,
  );
  try {
    return await client.getAbout();
  } finally {
    client.close();
  }
}

Future<bool> fireflySyncNow({
  // Ignore the rolling window and pull the instance's entire history. The
  // escape hatch for "my older transactions are missing"; expensive on a
  // populated instance, so it is only ever user-initiated.
  bool fullResync = false,
  // Push the local changes, but do not pull. A cycle that ran while the user
  // made a change uses this for the second cycle: the change is already behind
  // the watermark of the first cycle, and a pull is not necessary because each
  // push reads the live remote record before it writes.
  bool pushOnly = false,
  // Push local transactions that predate the link to Firefly.
  //
  // Off by default and deliberately so. On a first link both sides are
  // typically already populated, and transactions cannot be safely matched by
  // content, so blind-pushing local history would upload a duplicate of every
  // record the pull just brought down. Firefly is the system of record: local
  // history stays local unless the user explicitly asks to upload it.
  bool pushExistingLocalHistory = false,
  // Push each local change since the link that Firefly does not hold yet,
  // and do not pull. The user starts this from the settings page after the
  // routine cycles failed for a while. The push loops skip each row that is
  // linked and unchanged, thus the only difference to a routine push is the
  // lower limit: the link moment instead of the watermark.
  bool pushUnsynced = false,
}) async {
  if (!fireflyEnabled) return false;
  if (!_canSyncFirefly) return false;
  _canSyncFirefly = false;
  fireflySyncStatusNotifier.value = FireflySyncStatus.syncing;
  fireflySyncErrorNotifier.value = null;
  FireflySyncReport report = FireflySyncReport();

  FireflyApiClient? client;
  try {
    String hostUrl = fireflyHostUrl;
    String? pat = await getFireflyPat();
    if (hostUrl.isEmpty || pat == null || pat.isEmpty) {
      // The enabled flag and the host are in the settings, which a backup
      // carries. The token is in the key store of the device, which it does
      // not. A restore therefore leaves the integration reading as on with
      // no way to reach the server, and every cycle from then on fails with
      // an error that does not say why. Switch it off and say what to do.
      await setFireflyEnabled(false);
      throw FireflyAuthException(hostUrl.isEmpty
          ? "Firefly host or access token not set"
          : "The Firefly access token is not on this device. A backup does "
              "not carry it. Firefly sync is off; enter the token again in "
              "the Firefly settings to switch it back on.");
    }
    client = FireflyApiClient(baseUrl: hostUrl, personalAccessToken: pat);

    DateTime syncStartedAt = DateTime.now();

    // The link moment, for "Push unsynced changes". An installation that
    // linked before this setting existed gets its watermark: no row from
    // before the watermark waits for a push.
    if (fireflyLinkedAt == null) {
      await setFireflyLinkedAt(fireflyLastSyncedAt ?? syncStartedAt);
    }

    // A local row booked before the link and linked to nothing is history
    // and is not created on the server. See _pushIsPreLinkHistory. The
    // setter above ran, thus this is null only when writing it failed, and
    // the old behaviour - upload it - is then what happens.
    DateTime? preLinkCutoff = pushExistingLocalHistory ? null : fireflyLinkedAt;

    // The push watermark. On a first link this is the link moment rather than
    // the epoch, so pre-existing local rows are not treated as "changed since
    // last sync" and mass-uploaded - see pushExistingLocalHistory above.
    DateTime lastSynced = pushExistingLocalHistory
        ? DateTime(2000)
        : pushUnsynced
            ? fireflyUnsyncedSince()
            : (fireflyLastSyncedAt ?? syncStartedAt);
    bool skipPull = pushOnly || pushUnsynced;

    // Booking-date window for the pull. null means "no lower bound".
    DateTime? windowStart =
        fullResync ? null : fireflySyncWindowStart(now: syncStartedAt);

    // Pulled rows land in the reserved balance-correction category "0"
    // (uncategorized remote rows, both legs of a transfer, and the balance
    // anchors). Cashew only creates that category lazily, the first time the
    // user makes a balance correction, and createOrUpdateTransaction throws
    // "category-no-longer-exists" when it is missing - which on a fresh
    // install would abort the very first sync. Make sure it exists first.
    await _ensureFireflySystemCategories();

    _FireflyPushBacklog backlog = _FireflyPushBacklog();

    await _withFireflyEngineLock(() => _withFireflyWrites(() async {
          // A local copy that cannot be null. The closure captures the outer
          // variable, thus Dart does not keep the result of the null test.
          FireflyApiClient api = client!;
          _FireflyCounterpartyIndex counterparties;
          _FireflyAssetIndex assets = _FireflyAssetIndex();
          if (skipPull) {
            counterparties = await _loadCounterparties(api);
            assets.load(await api.getAccounts(type: kFireflyAssetAccountType));
          } else {
            Set<int> remoteCategoryIds = await _pullCategories(api, report);
            Set<int> remoteWalletIds =
                await _pullAccounts(api, report, assets: assets);
            counterparties = await _loadCounterparties(api);
            Set<int> remoteTransactionIds = await _pullTransactions(api, report,
                windowStart: windowStart, healUnchanged: fullResync);
            await _applyRemoteDeletes(
              client: api,
              remoteCategoryIds: remoteCategoryIds,
              remoteWalletIds: remoteWalletIds,
              remoteTransactionIds: remoteTransactionIds,
              windowStart: windowStart,
              report: report,
            );
          }
          await _pushCategories(api, lastSynced, report, backlog,
              includeUnmodifiedRows: pushExistingLocalHistory);
          await _pushAccounts(api, lastSynced, assets, report, backlog,
              includeUnmodifiedRows: pushExistingLocalHistory);
          await _pushTransactions(
              api, lastSynced, counterparties, assets, report, backlog,
              includeUnmodifiedRows: pushExistingLocalHistory,
              preLinkCutoff: preLinkCutoff);
          await _pushDeletes(api, lastSynced, assets, report, backlog);
          // Last, because the push changes the remote balances that this
          // reads. A balance from before the push would make each wallet that
          // the cycle pushed to wrong by the amount that it pushed.
          if (!skipPull ||
              report.pushedTransactions > 0 ||
              report.pushedWallets > 0 ||
              report.deletedRemote > 0) {
            await _refreshBalanceAnchors(api, report);
          }
        }));

    // Records that the client could not read. It skipped them rather than
    // ending the cycle; each one is a warning here so that they are not lost.
    for (String malformed in client.takeMalformedRecordWarnings()) {
      report.warnings
          .add("A Firefly record was not read and stays as it is: $malformed");
    }

    await setFireflyLastSyncedAt(backlog.nextWatermark(syncStartedAt));
    fireflySyncReportNotifier.value = report;
    fireflySyncStatusNotifier.value = FireflySyncStatus.idle;
    return true;
  } catch (e) {
    print("Firefly sync error: " + e.toString());
    fireflySyncErrorNotifier.value = e.toString();
    fireflySyncReportNotifier.value = report;
    fireflySyncStatusNotifier.value = FireflySyncStatus.error;
    return false;
  } finally {
    client?.close();
    _canSyncFirefly = true;
    _reschedulePushIfEditedDuringWork();
  }
}

// Holds the modification time of the oldest local row that a cycle did not
// push. The cycle then moves the push watermark back to that time, thus the
// next cycle finds the row again. Without this the watermark moves past each
// row that a warning or a conflict stopped, and the app never pushes it.
class _FireflyPushBacklog {
  DateTime? oldestNotPushed;

  void recordNotPushed(DateTime? localModified) {
    if (localModified == null) return;
    if (oldestNotPushed == null || localModified.isBefore(oldestNotPushed!)) {
      oldestNotPushed = localModified;
    }
  }

  // getAllNew*() selects each row with a time equal to or later than the
  // watermark, thus the time of the row itself is the correct watermark.
  DateTime nextWatermark(DateTime syncStartedAt) {
    DateTime? oldest = oldestNotPushed;
    if (oldest == null || oldest.isAfter(syncStartedAt)) return syncStartedAt;
    return oldest;
  }
}

class _FireflyCounterpartyIndex {
  final Map<int, FireflyAccount> byId;
  final Map<String, FireflyAccount> expenseByName;
  final Map<String, FireflyAccount> revenueByName;
  // The built-in cash account of the instance, when it has one. The default
  // naming mode books every withdrawal and deposit that has no account of
  // its own into it. See fireflyCounterpartyNaming.
  final FireflyAccount? cashAccount;

  _FireflyCounterpartyIndex({
    required this.byId,
    required this.expenseByName,
    required this.revenueByName,
    this.cashAccount,
  });
}

// The account that the other side of a withdrawal or a deposit names, and
// the name to send when there is no account for it.
//
// resolvePushCounterparty finds an account when the row is already linked to
// one, or when an account carries the name of the row or of its category.
// This decides what a request says when it finds none. The description used
// to stand in, and Firefly then made one expense account per description.
(int?, String?) _pushCounterparty({
  required FireflyAccount? resolved,
  required _FireflyCounterpartyIndex counterparties,
  required String? categoryName,
}) {
  if (resolved != null) return (resolved.id, null);
  if (fireflyCounterpartyNaming == kFireflyCounterpartyNamingCategory) {
    String name = (categoryName ?? "").trim();
    return (null, name.isEmpty ? null : name);
  }
  FireflyAccount? cash = counterparties.cashAccount;
  if (cash != null) return (cash.id, null);
  // An instance that has no cash account yet. Firefly matches the name to
  // the account it makes for it, thus this still ends in one account and not
  // in one per description.
  return (null, kFireflyCashAccountName);
}

Future<_FireflyCounterpartyIndex> _loadCounterparties(
    FireflyApiClient client) async {
  List<FireflyAccount> expense =
      await client.getAccounts(type: kFireflyExpenseAccountType);
  List<FireflyAccount> revenue =
      await client.getAccounts(type: kFireflyRevenueAccountType);
  List<FireflyAccount> cash =
      await client.getAccounts(type: kFireflyCashAccountType);
  Map<int, FireflyAccount> byId = {};
  Map<String, FireflyAccount> expenseByName = {};
  Map<String, FireflyAccount> revenueByName = {};
  for (FireflyAccount account in [...expense, ...cash]) {
    byId[account.id] = account;
    expenseByName[account.name.trim().toLowerCase()] = account;
  }
  for (FireflyAccount account in revenue) {
    byId[account.id] = account;
    revenueByName[account.name.trim().toLowerCase()] = account;
  }
  return _FireflyCounterpartyIndex(
    byId: byId,
    expenseByName: expenseByName,
    revenueByName: revenueByName,
    cashAccount: cash.isEmpty ? null : cash.first,
  );
}

// The asset accounts of the server, by id, for one cycle. The push reads the
// active flag from it: a push must not write into an account that the user
// deactivated on Firefly. The pull of the accounts fills it, or a push-only
// cycle reads the list once.
class _FireflyAssetIndex {
  final Map<int, FireflyAccount> byId = {};
  // The accounts that already have a warning in this cycle. One warning per
  // account, not one per row.
  final Set<int> warnedInactive = {};
  // The Firefly transactions that already have a warning in this cycle.
  final Set<int> warnedMoved = {};
  // The accounts whose currency already has a warning in this cycle.
  final Set<int> warnedCurrency = {};
  // True once the cycle read the list. Before that a missing id says nothing;
  // after it a missing id means that a link points at a record that the
  // server does not give as an asset account.
  bool loaded = false;

  void load(List<FireflyAccount> accounts) {
    for (FireflyAccount account in accounts) {
      byId[account.id] = account;
    }
    loaded = true;
  }
}

// True if the wallet of a local row is linked to a Firefly account of
// another currency.
//
// Firefly does not book a withdrawal or a deposit in the currency that the
// request names. TransactionJournalFactory::getCurrency takes the currency
// preference of the asset account first and falls back to the submitted code
// only when the account has none. A wallet in BDT linked to an account in USD
// therefore books 1,200 BDT as 1,200 USD, and no field of the request can
// stop it. The only thing the app can do is refuse to send the row.
//
// The row is held back rather than dropped: the watermark stays at it, thus
// it goes as soon as the user fixes the currency on either side or links the
// account to another Firefly account.
Future<bool> _pushBlockedByCurrencyMismatch({
  required _FireflyAssetIndex assets,
  required String walletPk,
  required FireflyAccount account,
  required DateTime? localModified,
  required FireflySyncReport report,
  required _FireflyPushBacklog backlog,
}) async {
  String remote = (account.currencyCode ?? "").trim().toUpperCase();
  if (remote.isEmpty) return false;
  TransactionWallet? wallet = await database.getWalletInstanceOrNull(walletPk);
  String local = (wallet?.currency ?? "").trim().toUpperCase();
  // A wallet with no currency of its own follows the account. Only two codes
  // that are both set and different are a mismatch.
  if (local.isEmpty || local == remote) return false;
  report.skippedCurrencyMismatch++;
  backlog.recordNotPushed(localModified);
  if (assets.warnedCurrency.add(account.id)) {
    report.warnings.add(
        "The account \"${wallet?.name ?? walletPk}\" is in $local and the "
        "Firefly account \"${account.name}\" it is linked to is in $remote. "
        "Firefly books every amount in the currency of its own account, so "
        "nothing was pushed. Give both the same currency, or link the account "
        "to another Firefly account in the Firefly settings.");
  }
  return true;
}

// True if the wallet of a local row is linked to an inactive Firefly
// account. The push then holds the row back: a warning names the account,
// the counter goes up, and the watermark stays at the row, thus a later
// cycle sends it once the user activated the account or linked the wallet to
// another account. A wallet with no link is not this case; the caller has
// its own test for that.
Future<bool> _pushBlockedByAccountState({
  required _FireflyAssetIndex assets,
  required String walletPk,
  required DateTime? localModified,
  required FireflySyncReport report,
  required _FireflyPushBacklog backlog,
}) async {
  FireflySyncMapEntry? walletMap =
      await _syncMapByLocalPk(FireflySyncEntityType.wallet, walletPk);
  if (walletMap == null) return false;
  FireflyAccount? account = assets.byId[walletMap.fireflyId];
  // The cycle has not read the list: nothing is known about the account, and
  // a push that the app cannot judge goes on as before.
  if (account == null && !assets.loaded) return false;
  if (account != null && account.active) {
    return await _pushBlockedByCurrencyMismatch(
      assets: assets,
      walletPk: walletPk,
      account: account,
      localModified: localModified,
      report: report,
      backlog: backlog,
    );
  }
  report.skippedInactiveAccount++;
  backlog.recordNotPushed(localModified);
  if (assets.warnedInactive.add(walletMap.fireflyId)) {
    TransactionWallet? wallet =
        await database.getWalletInstanceOrNull(walletPk);
    String walletName = wallet?.name ?? walletPk;
    report.warnings.add(account == null
        // The id is not in the asset accounts of the server. A push would
        // fail on each cycle, and it must not create the record somewhere
        // else, thus the row waits for the user.
        ? "The account \"$walletName\" is linked to a Firefly account that "
            "the server no longer gives as an asset account. Nothing was "
            "pushed to it. Link the account to another Firefly account in the "
            "Firefly settings."
        : "The account \"$walletName\" is linked to the Firefly "
            "account \"${account.name}\", which is inactive. Nothing was "
            "pushed to it. Activate it on Firefly, or link the account to "
            "another Firefly account in the Firefly settings.");
  }
  return true;
}

// The split of a group that a sync-map row points at. The journal id names
// it; a group with one split is that split.
// Two money amounts that differ by more than half a cent. A comparison with
// != makes a push out of the rounding of a double.
bool _fireflyAmountDiffers(double a, double b) {
  return (a - b).abs() > 0.005;
}

FireflyTransactionSplit? _splitOfRemoteGroup(
    FireflyTransactionGroup group, int? journalId) {
  if (journalId != null) {
    for (FireflyTransactionSplit split in group.splits) {
      if (split.transactionJournalId == journalId) return split;
    }
  }
  if (group.splits.length == 1) return group.splits.first;
  return null;
}

// True when the Firefly split that a local row points at sits on an asset
// account that no account of this app is linked to, and that is not the
// account of the wallet of that row.
//
// A push builds the split from the account that the wallet is linked to now
// and sends it to the group that the sync map names. If a wallet is linked to
// another Firefly account while its rows still point at the groups of the old
// one, that request moves those groups into the new account, and the ledger
// of the old account loses them. That is the failure of 2026-09-10, and the
// manual link picker can reach it again.
//
// A row whose remote account is the account of another wallet of this app is
// a row that the user moved from that wallet to this one. Firefly must follow
// that move, thus the push goes on.
Future<bool> _pushBlockedByMovedRemoteRow({
  required _FireflyAssetIndex assets,
  required FireflyTransactionSplit? split,
  required Set<int> walletAccountIds,
  required int fireflyId,
  required DateTime? localModified,
  required FireflySyncReport report,
  required _FireflyPushBacklog backlog,
}) async {
  // The app cannot say which split the row is. _splitsForPartialGroupUpdate
  // stops such a request on its own.
  if (split == null) return false;
  Set<int> foreign = {
    for (int? id in [split.sourceId, split.destinationId])
      if (id != null &&
          assets.byId.containsKey(id) &&
          !walletAccountIds.contains(id))
        id
  };
  if (foreign.isEmpty) return false;
  int? orphan;
  for (int id in foreign) {
    if ((await _syncMapsByFireflyId(FireflySyncEntityType.wallet, id))
        .isNotEmpty) {
      continue;
    }
    orphan = id;
    break;
  }
  if (orphan == null) return false;
  report.skippedMovedRemoteRow++;
  backlog.recordNotPushed(localModified);
  if (assets.warnedMoved.add(fireflyId)) {
    report.warnings.add(
        "Did not change a transaction on Firefly: it belongs to the Firefly "
        "account \"${assets.byId[orphan]?.name ?? orphan}\", which no account "
        "of this app is linked to. To write it would move it into the account "
        "that holds the record here. Link an account of this app to that "
        "Firefly account, or remove the record here.");
  }
  return true;
}

Future<List<FireflySyncMapEntry>> _syncMapEntriesForType(
    FireflySyncEntityType type,
    {bool includeTombstones = false}) {
  return (database.select(database.fireflySyncMap)
        ..where((tbl) => includeTombstones
            ? tbl.entityType.equalsValue(type)
            : tbl.entityType.equalsValue(type) & tbl.isTombstone.equals(false)))
      .get();
}

Future<FireflySyncMapEntry?> _syncMapByLocalPk(
    FireflySyncEntityType type, String localPk,
    {bool includeTombstones = false}) {
  return (database.select(database.fireflySyncMap)
        ..where((tbl) => includeTombstones
            ? tbl.entityType.equalsValue(type) & tbl.localPk.equals(localPk)
            : tbl.entityType.equalsValue(type) &
                tbl.localPk.equals(localPk) &
                tbl.isTombstone.equals(false)))
      .getSingleOrNull();
}

Future<List<FireflySyncMapEntry>> _syncMapsByFireflyId(
    FireflySyncEntityType type, int fireflyId,
    {bool includeTombstones = false}) {
  return (database.select(database.fireflySyncMap)
        ..where((tbl) => includeTombstones
            ? tbl.entityType.equalsValue(type) & tbl.fireflyId.equals(fireflyId)
            : tbl.entityType.equalsValue(type) &
                tbl.fireflyId.equals(fireflyId) &
                tbl.isTombstone.equals(false)))
      .get();
}

Future<void> _upsertSyncMap({
  String? syncMapPk,
  required FireflySyncEntityType type,
  required String localPk,
  required int fireflyId,
  DateTime? fireflyUpdatedAt,
  DateTime? lastSyncedLocalModified,
  bool isTombstone = false,
  int? counterpartyFireflyId,
  int fireflySplitIndex = 0,
  int? fireflyJournalId,
}) async {
  await database.into(database.fireflySyncMap).insert(
        FireflySyncMapCompanion(
          syncMapPk:
              syncMapPk == null ? const Value.absent() : Value(syncMapPk),
          entityType: Value(type),
          localPk: Value(localPk),
          fireflyId: Value(fireflyId),
          fireflyUpdatedAt: Value(fireflyUpdatedAt),
          lastSyncedLocalModified: Value(lastSyncedLocalModified),
          isTombstone: Value(isTombstone),
          counterpartyFireflyId: Value(counterpartyFireflyId),
          fireflySplitIndex: Value(fireflySplitIndex),
          fireflyJournalId: Value(fireflyJournalId),
        ),
        mode: InsertMode.insertOrReplace,
      );
}

// Removes the link between a local row and a Firefly record, but keeps the
// local row. A tombstone is not correct here: a tombstone stops each later
// push of that row, and the user can mark the row paid again, which must
// create the Firefly record again.
Future<void> _deleteSyncMapRow(FireflySyncMapEntry map) async {
  await (database.delete(database.fireflySyncMap)
        ..where((tbl) => tbl.syncMapPk.equals(map.syncMapPk)))
      .go();
}

// Removes every link to the Firefly server, and the balance anchors that the
// server balances gave. An id in the map is correct for one server only. If
// the user gives a different host, the same id on that host points to a
// different record, and a push then writes to the wrong record. The local
// rows stay: the next sync links them again.
Future<void> fireflyForgetSyncState() async {
  await database.delete(database.fireflySyncMap).go();
  await (database.delete(database.transactions)
        ..where(
            (tbl) => tbl.transactionPk.like("$kFireflyBalanceAnchorPkPrefix%")))
      .go();
  fireflyClearOnDemandCacheMemory();
  await clearFireflyLastSyncedAt();
}

Future<void> _tombstoneMapRow(FireflySyncMapEntry map) async {
  await _upsertSyncMap(
    syncMapPk: map.syncMapPk,
    type: map.entityType,
    localPk: map.localPk,
    fireflyId: map.fireflyId,
    fireflyUpdatedAt: map.fireflyUpdatedAt,
    lastSyncedLocalModified: map.lastSyncedLocalModified,
    isTombstone: true,
    counterpartyFireflyId: map.counterpartyFireflyId,
    fireflySplitIndex: map.fireflySplitIndex,
    fireflyJournalId: map.fireflyJournalId,
  );
}

Future<Set<int>> _pullCategories(
    FireflyApiClient client, FireflySyncReport report) async {
  List<FireflyCategory> remoteCategories = await client.getCategories();
  Set<int> remoteIds = {for (var remote in remoteCategories) remote.id};
  List<TransactionCategory> localMainCategories =
      (await database.getAllCategories()).toList();
  int nextOrder = localMainCategories.isEmpty
      ? 0
      : localMainCategories
              .map((c) => c.order)
              .reduce((a, b) => a > b ? a : b) +
          1;

  for (FireflyCategory remote in remoteCategories) {
    List<FireflySyncMapEntry> existingForRemote = await _syncMapsByFireflyId(
        FireflySyncEntityType.category, remote.id,
        includeTombstones: true);
    if (existingForRemote.any((m) => m.isTombstone)) continue;

    FireflySyncMapEntry? map =
        existingForRemote.isEmpty ? null : existingForRemote.first;

    if (map == null) {
      TransactionCategory? nameMatch;
      for (TransactionCategory candidate in localMainCategories) {
        if (candidate.mainCategoryPk != null) continue;
        if (candidate.name.trim().toLowerCase() !=
            remote.name.trim().toLowerCase()) continue;
        FireflySyncMapEntry? existingMapForCandidate = await _syncMapByLocalPk(
            FireflySyncEntityType.category, candidate.categoryPk,
            includeTombstones: true);
        if (existingMapForCandidate == null) {
          nameMatch = candidate;
          break;
        }
      }

      if (nameMatch != null) {
        await _upsertSyncMap(
          type: FireflySyncEntityType.category,
          localPk: nameMatch.categoryPk,
          fireflyId: remote.id,
          fireflyUpdatedAt: remote.updatedAt,
          lastSyncedLocalModified: nameMatch.dateTimeModified,
        );
        report.pulledCategories++;
      } else {
        TransactionCategory newCategory =
            fireflyCategoryToCategory(remote, order: nextOrder);
        nextOrder++;
        await database.createOrUpdateCategory(newCategory,
            insert: false, updateSharedEntry: false);
        TransactionCategory? inserted =
            await database.getCategoryInstanceOrNull(newCategory.categoryPk);
        if (inserted == null) continue;
        await _upsertSyncMap(
          type: FireflySyncEntityType.category,
          localPk: inserted.categoryPk,
          fireflyId: remote.id,
          fireflyUpdatedAt: remote.updatedAt,
          lastSyncedLocalModified: inserted.dateTimeModified,
        );
        report.pulledCategories++;
      }
      continue;
    }

    TransactionCategory? local =
        await database.getCategoryInstanceOrNull(map.localPk);
    if (local == null) {
      continue;
    }

    FireflySyncDirection direction = decideSyncDirection(
      localModified: local.dateTimeModified,
      remoteUpdatedAt: remote.updatedAt,
      lastSyncedLocalModified: map.lastSyncedLocalModified,
      lastSyncedRemoteUpdatedAt: map.fireflyUpdatedAt,
    );
    if (direction == FireflySyncDirection.pull) {
      // Write onto the row that is on disk. createOrUpdateCategory saves
      // with insertOrReplace, thus a new object blanks each column that
      // Firefly does not know: the color, the icon, the emoji, the income
      // flag and the link to the parent category.
      TransactionCategory updated = _mergeFireflyCategory(
        local,
        fireflyCategoryToCategory(
          remote,
          order: local.order,
          existingCategoryPk: local.categoryPk,
        ),
      );
      await database.createOrUpdateCategory(updated,
          insert: false, updateSharedEntry: false);
      TransactionCategory? saved =
          await database.getCategoryInstanceOrNull(local.categoryPk);
      await _upsertSyncMap(
        syncMapPk: map.syncMapPk,
        type: FireflySyncEntityType.category,
        localPk: local.categoryPk,
        fireflyId: remote.id,
        fireflyUpdatedAt: remote.updatedAt,
        lastSyncedLocalModified:
            saved?.dateTimeModified ?? updated.dateTimeModified,
      );
      report.pulledCategories++;
    }
  }
  return remoteIds;
}

Future<Set<int>> _pullAccounts(
    FireflyApiClient client, FireflySyncReport report,
    {_FireflyAssetIndex? assets}) async {
  List<FireflyAccount> remoteAccounts =
      await client.getAccounts(type: kFireflyAssetAccountType);
  assets?.load(remoteAccounts);
  Set<int> remoteIds = {for (var remote in remoteAccounts) remote.id};
  List<TransactionWallet> localWallets = await database.getAllWallets();
  int nextOrder = localWallets.isEmpty
      ? 0
      : localWallets.map((w) => w.order).reduce((a, b) => a > b ? a : b) + 1;

  for (FireflyAccount remote in remoteAccounts) {
    List<FireflySyncMapEntry> existingForRemote = await _syncMapsByFireflyId(
        FireflySyncEntityType.wallet, remote.id,
        includeTombstones: true);
    if (existingForRemote.any((m) => m.isTombstone)) continue;

    FireflySyncMapEntry? map =
        existingForRemote.isEmpty ? null : existingForRemote.first;

    if (map == null) {
      TransactionWallet? nameMatch;
      for (TransactionWallet candidate in localWallets) {
        if (candidate.name.trim().toLowerCase() !=
            remote.name.trim().toLowerCase()) continue;
        FireflySyncMapEntry? existingMapForCandidate = await _syncMapByLocalPk(
            FireflySyncEntityType.wallet, candidate.walletPk,
            includeTombstones: true);
        if (existingMapForCandidate == null) {
          nameMatch = candidate;
          break;
        }
      }

      if (nameMatch != null) {
        await _upsertSyncMap(
          type: FireflySyncEntityType.wallet,
          localPk: nameMatch.walletPk,
          fireflyId: remote.id,
          fireflyUpdatedAt: remote.updatedAt,
          lastSyncedLocalModified: nameMatch.dateTimeModified,
        );
        report.pulledWallets++;
      } else {
        TransactionWallet newWallet =
            fireflyAccountToWallet(remote, order: nextOrder);
        nextOrder++;
        await database.createOrUpdateWallet(newWallet, insert: false);
        TransactionWallet? inserted =
            await database.getWalletInstanceOrNull(newWallet.walletPk);
        if (inserted == null) continue;
        await _upsertSyncMap(
          type: FireflySyncEntityType.wallet,
          localPk: inserted.walletPk,
          fireflyId: remote.id,
          fireflyUpdatedAt: remote.updatedAt,
          lastSyncedLocalModified: inserted.dateTimeModified,
        );
        report.pulledWallets++;
      }
      continue;
    }

    TransactionWallet? local =
        await database.getWalletInstanceOrNull(map.localPk);
    if (local == null) {
      continue;
    }

    FireflySyncDirection direction = decideSyncDirection(
      localModified: local.dateTimeModified,
      remoteUpdatedAt: remote.updatedAt,
      lastSyncedLocalModified: map.lastSyncedLocalModified,
      lastSyncedRemoteUpdatedAt: map.fireflyUpdatedAt,
    );
    if (direction == FireflySyncDirection.pull) {
      // The same reason as in _mergeFireflyCategory: createOrUpdateWallet
      // saves with insertOrReplace. A wallet that is built from the Firefly
      // account alone loses its color, icon, currency format, decimal count
      // and home screen position at each remote rename.
      TransactionWallet updated = _mergeFireflyWallet(
        local,
        fireflyAccountToWallet(
          remote,
          order: local.order,
          existingWalletPk: local.walletPk,
        ),
      );
      await database.createOrUpdateWallet(updated, insert: false);
      TransactionWallet? saved =
          await database.getWalletInstanceOrNull(local.walletPk);
      await _upsertSyncMap(
        syncMapPk: map.syncMapPk,
        type: FireflySyncEntityType.wallet,
        localPk: local.walletPk,
        fireflyId: remote.id,
        fireflyUpdatedAt: remote.updatedAt,
        lastSyncedLocalModified:
            saved?.dateTimeModified ?? updated.dateTimeModified,
      );
      report.pulledWallets++;
    }
  }
  return remoteIds;
}

// Creates the two local categories that the Firefly integration needs. The
// function does nothing if they are there.
Future<void> _ensureFireflySystemCategories() async {
  await initializeBalanceCorrectionCategory();
  if (await database
          .getCategoryInstanceOrNull(kFireflyUncategorizedCategoryPk) !=
      null) {
    return;
  }
  int numberOfCategories = (await database.getTotalCountOfCategories())[0] ?? 0;
  await database.createOrUpdateCategory(
    insert: false,
    updateSharedEntry: false,
    TransactionCategory(
      categoryPk: kFireflyUncategorizedCategoryPk,
      name: "firefly-uncategorized".tr(),
      colour: null,
      iconName: "price-tag.png",
      dateCreated: DateTime.now(),
      dateTimeModified: null,
      order: numberOfCategories,
      income: false,
      methodAdded: MethodAdded.firefly,
    ),
  );
}

Future<Set<int>> _pullTransactions(
  FireflyApiClient client,
  FireflySyncReport report, {
  // The first booking date to read. null reads the full history.
  DateTime? windowStart,
  // Write the remote record onto a local row that neither side changed. Only
  // a full resync does this; see healUnchanged in decideSyncDirection.
  bool healUnchanged = false,
  // Groups that the caller read before, to apply in place of a new list. The
  // on-demand fetches give them, thus they use this same apply code.
  List<FireflyTransactionGroup>? preFetchedGroups,
}) async {
  List<FireflyTransactionGroup> groups =
      preFetchedGroups ?? await client.getTransactions(start: windowStart);
  Set<int> remoteIds = {for (var group in groups) group.id};

  List<FireflySyncMapEntry> walletMaps =
      await _syncMapEntriesForType(FireflySyncEntityType.wallet);
  Map<int, String> walletFireflyIdToLocalPk = {
    for (var m in walletMaps) m.fireflyId: m.localPk
  };
  Set<int> assetFireflyIds = walletFireflyIdToLocalPk.keys.toSet();
  List<FireflySyncMapEntry> categoryMaps =
      await _syncMapEntriesForType(FireflySyncEntityType.category);
  Map<int, String> categoryFireflyIdToLocalPk = {
    for (var m in categoryMaps) m.fireflyId: m.localPk
  };

  for (FireflyTransactionGroup group in groups) {
    if (group.splits.isEmpty) continue;
    bool groupIsReported = false;

    for (int splitIndex = 0; splitIndex < group.splits.length; splitIndex++) {
      FireflyTransactionSplit split = group.splits[splitIndex];
      int? journalId = split.transactionJournalId;

      // The rows are read for each split: this loop writes rows, thus a list
      // that it reads one time for the group goes stale inside the loop.
      List<FireflySyncMapEntry> liveMaps = [];
      Set<int> liveJournalIds = {};
      Set<int> tombstonedJournalIds = {};
      Set<int> tombstonedPositions = {};
      for (FireflySyncMapEntry map in await _syncMapsByFireflyId(
          FireflySyncEntityType.transaction, group.id,
          includeTombstones: true)) {
        if (map.isTombstone) {
          if (map.fireflyJournalId != null) {
            tombstonedJournalIds.add(map.fireflyJournalId!);
          } else {
            tombstonedPositions.add(map.fireflySplitIndex);
          }
          continue;
        }
        liveMaps.add(map);
        if (map.fireflyJournalId != null) {
          liveJournalIds.add(map.fireflyJournalId!);
        }
      }
      bool positionMatchIsSafe =
          fireflyPositionMatchIsSafe(groupMaps: liveMaps, splits: group.splits);

      // A tombstone is for one split, not for the full group. To skip the
      // group when one split has a tombstone stopped each other split of it:
      // they kept their links but got no more remote changes.
      //
      // A tombstone that the app wrote before the journal-id column was there
      // holds a position only, and Firefly moves the positions when it deletes
      // a split. Such a tombstone thus counts only while no live row claims
      // this split and while the positions are safe.
      bool splitIsTombstoned;
      if (journalId != null && tombstonedJournalIds.contains(journalId)) {
        splitIsTombstoned = true;
      } else if (journalId != null) {
        // The split has an id, and no tombstone names that id. A tombstone
        // that holds a position only is thus for a split that the app removed
        // before, and Firefly moved a later split into that position. To let
        // the position count here hides this split for ever: the app makes no
        // record for it, and it gives no message.
        splitIsTombstoned = false;
      } else {
        splitIsTombstoned =
            positionMatchIsSafe && tombstonedPositions.contains(splitIndex);
      }
      if (splitIsTombstoned) continue;

      List<FireflySyncMapEntry> splitMaps = matchSplitToSyncMaps(
        groupMaps: liveMaps,
        splitJournalId: journalId,
        splitIndex: splitIndex,
        matchByPosition: positionMatchIsSafe,
      );

      // Give the id to each matched row here, before a test below can end
      // this split. A row that keeps a null id stays matched by position, and
      // the next split that Firefly deletes then moves it onto a neighbour.
      if (journalId != null) {
        for (int i = 0; i < splitMaps.length; i++) {
          if (splitMaps[i].fireflyJournalId != null) continue;
          splitMaps[i] = await _writeSplitJournalId(splitMaps[i], journalId);
        }
      }

      FireflyPulledSplitKind kind = classifySplitType(split.type);
      if (kind == FireflyPulledSplitKind.skip) {
        report.skippedUnsupported++;
        continue;
      }

      // The opening balance and the reconciliation journals are bookkeeping
      // entries of Firefly. They come from the setup of the account, not from
      // an action of the user. To import them as usual transactions is unsafe:
      // the first local change sends such a row back as a usual withdrawal or
      // deposit and makes the opening balance of the remote account wrong.
      // Their amounts are already in the current_balance value that gives the
      // balance anchor, thus this skip loses nothing.
      if (splitKindIsBalanceCorrection(kind)) {
        report.skippedUnsupported++;
        continue;
      }

      // The group holds a row that no id identifies, and the positions are
      // not safe. To match by position can put the remote change on the wrong
      // local row, and to make a new row makes a second copy of a row that is
      // already here. The app does neither, and it names the group.
      if (splitMaps.isEmpty &&
          !positionMatchIsSafe &&
          liveMaps.any((map) => map.fireflyJournalId == null)) {
        if (!groupIsReported) {
          groupIsReported = true;
          report.warnings.add(
              "A Firefly transaction with several splits changed, and this "
              "app cannot say which of its records is which split. The "
              "records stay as they are. To repair them, use \"Reset Firefly "
              "links\" in the Firefly settings.");
        }
        report.skippedAmbiguousSplits++;
        continue;
      }

      if (kind == FireflyPulledSplitKind.transfer) {
        await _pullTransferSplit(
          group: group,
          split: split,
          splitIndex: splitIndex,
          splitMaps: splitMaps,
          walletFireflyIdToLocalPk: walletFireflyIdToLocalPk,
          report: report,
          healUnchanged: healUnchanged,
        );
        continue;
      }

      int? assetId = assetFireflyIdForSplit(split, assetFireflyIds);
      if (assetId == null) {
        report.skippedUnmappedWallet++;
        continue;
      }
      String? walletPk = walletFireflyIdToLocalPk[assetId];
      if (walletPk == null) {
        report.skippedUnmappedWallet++;
        continue;
      }

      bool isIncome = splitIsIncomeForAsset(split, assetId);
      String categoryPk = split.categoryId == null
          ? kFireflyUncategorizedCategoryPk
          : (categoryFireflyIdToLocalPk[split.categoryId] ??
              kFireflyUncategorizedCategoryPk);
      int? counterpartyId = counterpartyFireflyIdForSplit(split, assetId);

      FireflySyncMapEntry? existingMap =
          splitMaps.isEmpty ? null : splitMaps.first;

      if (existingMap == null) {
        if (await _adoptLostCreate(
          group: group,
          split: split,
          splitIndex: splitIndex,
          report: report,
          counterpartyFireflyId: counterpartyId,
        )) {
          continue;
        }
        Transaction newTransaction = fireflySplitToTransaction(
          split,
          walletPk: walletPk,
          categoryPk: categoryPk,
          isIncome: isIncome,
        );
        // The new row and its map row must commit together. If the row
        // commits and the map row does not, the next pull finds no link and
        // inserts a second copy, and the push finds a local row with no link
        // and creates a second remote record.
        bool inserted = await database.transaction(() async {
          await database.createOrUpdateTransaction(newTransaction,
              insert: false, updateSharedEntry: false, fireflySync: true);
          Transaction? saved = await database
              .tryGetTransactionFromPk(newTransaction.transactionPk);
          if (saved == null) return false;
          await _upsertSyncMap(
            type: FireflySyncEntityType.transaction,
            localPk: saved.transactionPk,
            fireflyId: group.id,
            fireflyUpdatedAt: group.updatedAt,
            lastSyncedLocalModified: saved.dateTimeModified,
            counterpartyFireflyId: counterpartyId,
            fireflySplitIndex: splitIndex,
            fireflyJournalId: split.transactionJournalId,
          );
          return true;
        });
        if (!inserted) continue;
        report.pulledTransactions++;
      } else {
        Transaction? local =
            await database.tryGetTransactionFromPk(existingMap.localPk);
        if (local == null) continue;
        FireflySyncDirection direction = decideSyncDirection(
          localModified: local.dateTimeModified,
          remoteUpdatedAt: group.updatedAt,
          lastSyncedLocalModified: existingMap.lastSyncedLocalModified,
          lastSyncedRemoteUpdatedAt: existingMap.fireflyUpdatedAt,
          healUnchanged: healUnchanged,
        );
        if (direction == FireflySyncDirection.pull) {
          Transaction updated = fireflyApplySplitToExisting(
            local,
            split,
            walletPk: walletPk,
            categoryPk: categoryPk,
            isIncome: isIncome,
          );
          await database.createOrUpdateTransaction(updated,
              insert: false, updateSharedEntry: false, fireflySync: true);
          Transaction? saved =
              await database.tryGetTransactionFromPk(local.transactionPk);
          await _upsertSyncMap(
            syncMapPk: existingMap.syncMapPk,
            type: FireflySyncEntityType.transaction,
            localPk: local.transactionPk,
            fireflyId: group.id,
            fireflyUpdatedAt: group.updatedAt,
            lastSyncedLocalModified:
                saved?.dateTimeModified ?? updated.dateTimeModified,
            counterpartyFireflyId: counterpartyId,
            fireflySplitIndex: splitIndex,
            fireflyJournalId:
                split.transactionJournalId ?? existingMap.fireflyJournalId,
          );
          report.pulledTransactions++;
        }
      }
    }

    await _unlinkRowsOfRemovedSplits(group, report);
  }
  return remoteIds;
}

// Removes the local row of a split that Firefly no longer holds.
//
// _applyRemoteDeletes asks whether a GROUP is on the server. It thus cannot
// see a split that Firefly removed from a group that stays. Such a split
// leaves a local row that keeps its link for ever, and a remote change that
// puts a new split in its place makes a second local row next to it.
//
// The group here comes from the server, thus it holds each split that is
// there. A row that names a journal id that the group does not hold is for a
// split that is gone.
Future<void> _unlinkRowsOfRemovedSplits(
    FireflyTransactionGroup group, FireflySyncReport report) async {
  Set<int> liveJournalIds = {
    for (FireflyTransactionSplit split in group.splits)
      if (split.transactionJournalId != null) split.transactionJournalId!
  };
  // One split with no id makes the set too small, and each row would then look
  // removed. Do nothing until the server names each split.
  if (liveJournalIds.length != group.splits.length) return;

  for (FireflySyncMapEntry map in await _syncMapsByFireflyId(
      FireflySyncEntityType.transaction, group.id)) {
    // A row with no journal id gives no proof: its position can point at
    // another split. The quarantine in the pull loop names such a group.
    if (map.fireflyJournalId == null) continue;
    if (liveJournalIds.contains(map.fireflyJournalId)) continue;
    await _deleteLocalTransactionFromRemote(map, report);
  }
}

// Writes the journal id on a map row and gives the row with that id. The
// upsert replaces the row, thus each other field must go with the write.
Future<FireflySyncMapEntry> _writeSplitJournalId(
    FireflySyncMapEntry map, int journalId) async {
  await _upsertSyncMap(
    syncMapPk: map.syncMapPk,
    type: FireflySyncEntityType.transaction,
    localPk: map.localPk,
    fireflyId: map.fireflyId,
    fireflyUpdatedAt: map.fireflyUpdatedAt,
    lastSyncedLocalModified: map.lastSyncedLocalModified,
    counterpartyFireflyId: map.counterpartyFireflyId,
    fireflySplitIndex: map.fireflySplitIndex,
    fireflyJournalId: journalId,
  );
  return map.copyWith(fireflyJournalId: Value(journalId));
}

// Links the local row that made a Firefly record to that record.
//
// A create is two steps that cannot be one: the request to Firefly, and the
// row of the sync map that keeps the answer. Between them the app can be
// killed. Firefly then holds a record that no local row points at, and both
// halves of the sync make a copy of it: the pull imports it as a new local
// row, and the push sends the local row again as a new remote record.
//
// Every create carries the key of its local row in external_id. This reads
// it back. A row that is already linked is not this case, and neither is a
// key that names no row.
//
// The link is written with no local watermark, so the next push sends the
// current content of the local row onto the record as an update. That is
// right whether or not the row changed after the lost create.
Future<bool> _adoptLostCreate({
  required FireflyTransactionGroup group,
  required FireflyTransactionSplit split,
  required int splitIndex,
  required FireflySyncReport report,
  int? counterpartyFireflyId,
  // The transfer path links both legs of the pair, not the source row alone.
  bool linkPairedRow = false,
}) async {
  String externalId = (split.externalId ?? "").trim();
  if (externalId.isEmpty) return false;
  Transaction? local = await database.tryGetTransactionFromPk(externalId);
  if (local == null) return false;
  List<Transaction> rows = [local];
  if (linkPairedRow) {
    if (local.pairedTransactionFk == null) return false;
    Transaction? paired =
        await database.tryGetTransactionFromPk(local.pairedTransactionFk!);
    if (paired == null) return false;
    rows.add(paired);
  }
  // Any existing entry, tombstone included, means the app already decided
  // what this row points at. Adoption must not overwrite that decision.
  for (Transaction row in rows) {
    if (await _syncMapByLocalPk(
            FireflySyncEntityType.transaction, row.transactionPk,
            includeTombstones: true) !=
        null) {
      return false;
    }
  }
  await database.transaction(() async {
    for (Transaction row in rows) {
      await _upsertSyncMap(
        type: FireflySyncEntityType.transaction,
        localPk: row.transactionPk,
        fireflyId: group.id,
        fireflyUpdatedAt: group.updatedAt,
        lastSyncedLocalModified: null,
        counterpartyFireflyId: counterpartyFireflyId,
        fireflySplitIndex: splitIndex,
        fireflyJournalId: split.transactionJournalId,
      );
    }
  });
  report.recoveredCreates += rows.length;
  return true;
}

Future<void> _pullTransferSplit({
  required FireflyTransactionGroup group,
  required FireflyTransactionSplit split,
  required int splitIndex,
  // The rows that hold this split. The caller matched them and gave them the
  // journal id of the split.
  required List<FireflySyncMapEntry> splitMaps,
  required Map<int, String> walletFireflyIdToLocalPk,
  required FireflySyncReport report,
  // See healUnchanged in decideSyncDirection. A stale destination leg of a
  // cross-currency transfer is exactly the row this repairs.
  bool healUnchanged = false,
}) async {
  String? sourcePk =
      split.sourceId == null ? null : walletFireflyIdToLocalPk[split.sourceId];
  String? destPk = split.destinationId == null
      ? null
      : walletFireflyIdToLocalPk[split.destinationId];
  if (sourcePk == null || destPk == null) {
    report.skippedUnmappedWallet++;
    return;
  }

  // The currency of the destination wallet decides which amount of the
  // split its row gets. See fireflySplitToTransferPair.
  String? destCurrency =
      (await database.getWalletInstanceOrNull(destPk))?.currency;

  if (splitMaps.isEmpty) {
    if (await _adoptLostCreate(
      group: group,
      split: split,
      splitIndex: splitIndex,
      report: report,
      linkPairedRow: true,
    )) {
      return;
    }
    (Transaction, Transaction) pair = fireflySplitToTransferPair(
      split,
      sourceWalletPk: sourcePk,
      destWalletPk: destPk,
      destCurrency: destCurrency,
    );
    // The two legs and the two map rows commit together. A part commit
    // leaves one half of a transfer, or a pair with no link that the next
    // cycle imports again and also sends back as a new remote transfer.
    await database.transaction(() async {
      await database.createOrUpdateTransaction(pair.$1,
          insert: false, updateSharedEntry: false, fireflySync: true);
      await database.createOrUpdateTransaction(pair.$2,
          insert: false, updateSharedEntry: false, fireflySync: true);
      Transaction? savedFrom =
          await database.tryGetTransactionFromPk(pair.$1.transactionPk);
      Transaction? savedTo =
          await database.tryGetTransactionFromPk(pair.$2.transactionPk);
      await _upsertSyncMap(
        type: FireflySyncEntityType.transaction,
        localPk: pair.$1.transactionPk,
        fireflyId: group.id,
        fireflyUpdatedAt: group.updatedAt,
        lastSyncedLocalModified: savedFrom?.dateTimeModified,
        fireflySplitIndex: splitIndex,
        fireflyJournalId: split.transactionJournalId,
      );
      await _upsertSyncMap(
        type: FireflySyncEntityType.transaction,
        localPk: pair.$2.transactionPk,
        fireflyId: group.id,
        fireflyUpdatedAt: group.updatedAt,
        lastSyncedLocalModified: savedTo?.dateTimeModified,
        fireflySplitIndex: splitIndex,
        fireflyJournalId: split.transactionJournalId,
      );
    });
    report.pulledTransactions += 2;
    return;
  }

  Transaction? first =
      await database.tryGetTransactionFromPk(splitMaps.first.localPk);
  if (first == null) return;
  DateTime? newestLocal = first.dateTimeModified;
  DateTime? newestWatermark = splitMaps.first.lastSyncedLocalModified;
  for (FireflySyncMapEntry map in splitMaps) {
    Transaction? local = await database.tryGetTransactionFromPk(map.localPk);
    // Kept in a local variable: Dart does not make `local` non-null from a
    // test of `local?.field`, thus the field needs one read and one test.
    DateTime? localModified = local?.dateTimeModified;
    if (localModified != null &&
        (newestLocal == null || localModified.isAfter(newestLocal))) {
      newestLocal = localModified;
    }
    if (map.lastSyncedLocalModified != null &&
        (newestWatermark == null ||
            map.lastSyncedLocalModified!.isAfter(newestWatermark))) {
      newestWatermark = map.lastSyncedLocalModified;
    }
  }
  FireflySyncDirection direction = decideSyncDirection(
    localModified: newestLocal,
    remoteUpdatedAt: group.updatedAt,
    lastSyncedLocalModified: newestWatermark,
    lastSyncedRemoteUpdatedAt: splitMaps.first.fireflyUpdatedAt,
    healUnchanged: healUnchanged,
  );
  if (direction != FireflySyncDirection.pull) return;

  String? existingSourcePk;
  String? existingDestPk;
  for (FireflySyncMapEntry map in splitMaps) {
    Transaction? local = await database.tryGetTransactionFromPk(map.localPk);
    if (local == null) continue;
    if (local.amount < 0) {
      existingSourcePk = local.transactionPk;
    } else {
      existingDestPk = local.transactionPk;
    }
  }
  (Transaction, Transaction) rebuilt = fireflySplitToTransferPair(
    split,
    sourceWalletPk: sourcePk,
    destWalletPk: destPk,
    destCurrency: destCurrency,
    existingSourceTransactionPk: existingSourcePk,
    existingDestTransactionPk: existingDestPk,
  );
  // Write onto the rows that are on disk. createOrUpdateTransaction saves
  // with insertOrReplace, thus each column that the companion does not hold
  // gets its default value, and each local-only field of the transfer is lost
  // at every remote change.
  (Transaction, Transaction) pair = (
    _mergeFireflyTransferSide(
        existingSourcePk == null
            ? null
            : await database.tryGetTransactionFromPk(existingSourcePk),
        rebuilt.$1),
    _mergeFireflyTransferSide(
        existingDestPk == null
            ? null
            : await database.tryGetTransactionFromPk(existingDestPk),
        rebuilt.$2),
  );
  // The two legs and their two map rows commit together, as they do on the
  // insert path above. A part commit leaves one leg at the new amount and the
  // other at the old one, and the balance of the two accounts no longer
  // matches the one transfer they hold.
  await database.transaction(() async {
    await database.createOrUpdateTransaction(pair.$1,
        insert: false, updateSharedEntry: false, fireflySync: true);
    await database.createOrUpdateTransaction(pair.$2,
        insert: false, updateSharedEntry: false, fireflySync: true);
    Transaction? savedFrom =
        await database.tryGetTransactionFromPk(pair.$1.transactionPk);
    Transaction? savedTo =
        await database.tryGetTransactionFromPk(pair.$2.transactionPk);
    FireflySyncMapEntry? fromMap = splitMaps
        .cast<FireflySyncMapEntry?>()
        .firstWhere((m) => m?.localPk == pair.$1.transactionPk,
            orElse: () => null);
    FireflySyncMapEntry? toMap = splitMaps
        .cast<FireflySyncMapEntry?>()
        .firstWhere((m) => m?.localPk == pair.$2.transactionPk,
            orElse: () => null);
    await _upsertSyncMap(
      syncMapPk: fromMap?.syncMapPk,
      type: FireflySyncEntityType.transaction,
      localPk: pair.$1.transactionPk,
      fireflyId: group.id,
      fireflyUpdatedAt: group.updatedAt,
      lastSyncedLocalModified: savedFrom?.dateTimeModified,
      // The link of a transfer leg names the account on the other side, and
      // an upsert with no value for it drops that. It is written back here.
      counterpartyFireflyId: fromMap?.counterpartyFireflyId,
      fireflySplitIndex: splitIndex,
      fireflyJournalId: split.transactionJournalId ?? fromMap?.fireflyJournalId,
    );
    await _upsertSyncMap(
      syncMapPk: toMap?.syncMapPk,
      type: FireflySyncEntityType.transaction,
      localPk: pair.$2.transactionPk,
      fireflyId: group.id,
      fireflyUpdatedAt: group.updatedAt,
      lastSyncedLocalModified: savedTo?.dateTimeModified,
      counterpartyFireflyId: toMap?.counterpartyFireflyId,
      fireflySplitIndex: splitIndex,
      fireflyJournalId: split.transactionJournalId ?? toMap?.fireflyJournalId,
    );
  });
  report.pulledTransactions += 2;
}

// Firefly knows only the name of a category. Thus a pull writes only the name
// onto a local category that is there.
TransactionCategory _mergeFireflyCategory(
    TransactionCategory existing, TransactionCategory rebuilt) {
  return existing.copyWith(
    name: rebuilt.name,
    dateTimeModified: Value(rebuilt.dateTimeModified),
  );
}

// The same for accounts: the name and the currency are from Firefly. The
// other fields of the wallet belong to this application.
TransactionWallet _mergeFireflyWallet(
    TransactionWallet existing, TransactionWallet rebuilt) {
  return existing.copyWith(
    name: rebuilt.name,
    currency: Value(rebuilt.currency),
    dateTimeModified: Value(rebuilt.dateTimeModified),
  );
}

// Writes the Firefly fields of a rebuilt transfer leg onto the stored row and
// keeps each field that this application owns.
Transaction _mergeFireflyTransferSide(
    Transaction? existing, Transaction rebuilt) {
  if (existing == null) return rebuilt;
  return existing.copyWith(
    pairedTransactionFk: Value(rebuilt.pairedTransactionFk),
    name: rebuilt.name,
    amount: rebuilt.amount,
    note: rebuilt.note,
    categoryFk: rebuilt.categoryFk,
    walletFk: rebuilt.walletFk,
    dateCreated: rebuilt.dateCreated,
    dateTimeModified: Value(rebuilt.dateTimeModified),
    income: rebuilt.income,
    paid: rebuilt.paid,
  );
}

// Removes the local rows of records that are no longer on the Firefly server.
//
// This is the most destructive operation of the engine. It is correct only if
// the caller gives a COMPLETE set of remote ids for the scope. Two rules keep
// that true:
//
//  * The API client does not return a part of a paged list. It throws, thus a
//    short read stops the sync and does not look like "each other record is
//    deleted".
//  * The code compares transactions only in the range of booking dates that
//    the sync read. It did not ask for an older record, thus the absence of
//    that record from remoteTransactionIds gives no information. To compare it
//    deletes the full history of the user before the window.
//
// Accounts and categories have no window. Each cycle reads the complete
// lists, thus the code compares all of them.
Future<void> _applyRemoteDeletes({
  required FireflyApiClient client,
  required Set<int> remoteCategoryIds,
  required Set<int> remoteWalletIds,
  required Set<int> remoteTransactionIds,
  // The first booking date of the window that gave remoteTransactionIds. null
  // means that the sync read the full history and each record is in scope.
  required DateTime? windowStart,
  required FireflySyncReport report,
}) async {
  // The Firefly groups that this pass asked about: true = on the server,
  // false = gone. A group can hold more than one mapped split, thus the code
  // asks about each group one time only.
  Map<int, bool> stillOnFirefly = {};

  for (FireflySyncMapEntry map
      in await _syncMapEntriesForType(FireflySyncEntityType.transaction)) {
    if (remoteTransactionIds.contains(map.fireflyId)) continue;

    if (windowStart != null) {
      Transaction? local = await database.tryGetTransactionFromPk(map.localPk);
      // No local row. Nothing to delete, thus close the link only.
      if (local == null) {
        await _tombstoneMapRow(map);
        continue;
      }
      // The date is before the window, thus the sync did not ask Firefly
      // about this record. Keep it.
      if (local.dateCreated.isBefore(windowStart)) continue;

      // The local row is in the window, but the record did not come back.
      // This is not proof of a delete: a new date before windowStart moves the
      // remote record out of the window and keeps it complete, while the local
      // copy keeps the old date. An error here is permanent, because the code
      // deletes the row and writes a tombstone, and a tombstone stops even
      // "Sync all history". Thus ask the server about this one record first.
      bool? known = stillOnFirefly[map.fireflyId];
      if (known == null) {
        try {
          FireflyTransactionGroup remote =
              await client.getTransaction(map.fireflyId);
          known = true;
          // Apply it again, thus the local copy gets the new date. When
          // dateCreated agrees with the remote booking date, the test above
          // skips this row in each later cycle.
          await _pullTransactions(client, report, preFetchedGroups: [remote]);
        } on FireflyNotFoundException {
          known = false;
        } catch (_) {
          // A network error or a server error is not proof of a delete. Keep
          // the row and try again in the next cycle.
          report.warnings
              .add("Could not confirm with Firefly whether a transaction was "
                  "deleted, so it was kept locally.");
          continue;
        }
        stillOnFirefly[map.fireflyId] = known;
      }
      if (known == true) continue;
    }

    await _deleteLocalTransactionFromRemote(map, report);
  }

  for (FireflySyncMapEntry map
      in await _syncMapEntriesForType(FireflySyncEntityType.category)) {
    if (remoteCategoryIds.contains(map.fireflyId)) continue;
    await _deleteLocalCategoryFromRemote(map, report);
  }

  for (FireflySyncMapEntry map
      in await _syncMapEntriesForType(FireflySyncEntityType.wallet)) {
    if (remoteWalletIds.contains(map.fireflyId)) continue;
    await _deleteLocalWalletFromRemote(map, report);
  }
}

Future<void> _deleteLocalTransactionFromRemote(
    FireflySyncMapEntry map, FireflySyncReport report) async {
  Transaction? local = await database.tryGetTransactionFromPk(map.localPk);
  if (local != null) {
    await database.deleteTransaction(map.localPk, updateSharedEntry: false);
    report.deletedLocal++;
  }
  await _tombstoneMapRow(map);
}

Future<void> _deleteLocalCategoryFromRemote(
    FireflySyncMapEntry map, FireflySyncReport report) async {
  TransactionCategory? local =
      await database.getCategoryInstanceOrNull(map.localPk);
  if (local != null) {
    List<Transaction> inCategory =
        await database.getAllTransactionsFromCategory(local.categoryPk);
    for (Transaction transaction in inCategory) {
      await database.createOrUpdateTransaction(
        transaction.copyWith(categoryFk: kFireflyUncategorizedCategoryPk),
        insert: false,
        updateSharedEntry: false,
        fireflySync: true,
      );
    }
    // database.deleteCategory() also removes the subcategories, the
    // associated titles and the budget limits of this category, and it writes
    // the delete log. A plain delete of the row leaves a subcategory that
    // points at a parent that is gone. The transactions above no longer point
    // at this category, thus deleteCategory() does not delete a transaction.
    await database.deleteCategory(local.categoryPk, local.order);
    report.deletedLocal++;
  }
  await _tombstoneMapRow(map);
}

Future<void> _deleteLocalWalletFromRemote(
    FireflySyncMapEntry map, FireflySyncReport report) async {
  TransactionWallet? local =
      await database.getWalletInstanceOrNull(map.localPk);
  if (local == null) {
    await _tombstoneMapRow(map);
    return;
  }
  if (local.walletPk == "0") {
    report.warnings.add(
        "Firefly deleted the account for the default wallet; the local wallet was kept.");
    await _tombstoneMapRow(map);
    return;
  }
  List<Transaction> remaining =
      await database.getAllTransactionsFromWallet(local.walletPk);
  if (remaining.isNotEmpty) {
    report.warnings.add(
        "Firefly deleted account \"${local.name}\" but it still has ${remaining.length} local transaction(s); the wallet was kept.");
    await _tombstoneMapRow(map);
    return;
  }
  await database.deleteWallet(local.walletPk, local.order);
  report.deletedLocal++;
  await _tombstoneMapRow(map);
}

Future<void> _pushCategories(FireflyApiClient client, DateTime lastSynced,
    FireflySyncReport report, _FireflyPushBacklog backlog,
    {required bool includeUnmodifiedRows}) async {
  List<TransactionCategory> changed =
      await database.getAllNewCategories(lastSynced);
  for (TransactionCategory category in changed) {
    try {
      await _pushOneCategory(
        client: client,
        category: category,
        report: report,
        backlog: backlog,
        includeUnmodifiedRows: includeUnmodifiedRows,
      );
    } on FireflyAuthException {
      rethrow;
    } on FireflyRateLimitException {
      rethrow;
    } catch (e) {
      report.failedCategories++;
      report.warnings
          .add("The category \"${category.name}\" was not pushed: $e");
      backlog.recordNotPushed(category.dateTimeModified);
      print("Firefly push-category error (will retry): " + e.toString());
    }
  }
}

// One category of the push. A return leaves this category and goes on to
// the next one. The loop in _pushCategories keeps a failure of this function
// as a warning, thus one category cannot stop the cycle.
Future<void> _pushOneCategory({
  required FireflyApiClient client,
  required TransactionCategory category,
  required FireflySyncReport report,
  required _FireflyPushBacklog backlog,
  required bool includeUnmodifiedRows,
}) async {
  // getAllNew*() also returns each row that has no dateTimeModified. Such a
  // row is not a recent change: it is a row from a version before that
  // column, or a row from an old backup. The app sends it only if the user
  // asks for the local history.
  if (category.dateTimeModified == null && !includeUnmodifiedRows) return;
  // The local category for "Firefly has no category". Firefly must not get
  // a category with this name.
  if (category.categoryPk == kFireflyUncategorizedCategoryPk) return;
  // The balance-correction category holds the balance anchors and the
  // manual corrections of the user. It is local only.
  // _ensureFireflySystemCategories writes it with a new dateTimeModified,
  // thus the first cycle finds it as a changed row.
  if (category.categoryPk == kBalanceCorrectionCategoryPk) return;
  // A subcategory has no Firefly form, thus no later cycle can send it.
  // recordNotPushed is for a row that a next cycle can still send: to hold
  // the watermark at a row that never goes keeps it there for ever.
  if (category.mainCategoryPk != null) {
    report.skippedSubcategories++;
    return;
  }
  FireflyCategory? remoteShape = categoryToFireflyCategory(category);
  if (remoteShape == null) return;

  FireflySyncMapEntry? tombstone = await _syncMapByLocalPk(
      FireflySyncEntityType.category, category.categoryPk,
      includeTombstones: true);
  if (tombstone != null && tombstone.isTombstone) return;

  FireflySyncMapEntry? map = await _syncMapByLocalPk(
      FireflySyncEntityType.category, category.categoryPk);
  if (map == null) {
    FireflyCategory created;
    try {
      created = await client.createCategory(remoteShape);
    } on FireflyValidationException catch (e) {
      if (!e.isNameInUse) rethrow;
      await _linkCategoryToExistingRemote(client, category, report);
      return;
    }
    await _upsertSyncMap(
      type: FireflySyncEntityType.category,
      localPk: category.categoryPk,
      fireflyId: created.id,
      fireflyUpdatedAt: created.updatedAt,
      lastSyncedLocalModified: category.dateTimeModified,
    );
    report.pushedCategories++;
  } else {
    if (!fireflyLocalRowChanged(
      localModified: category.dateTimeModified,
      lastSyncedLocalModified: map.lastSyncedLocalModified,
    )) {
      return;
    }
    // Read the live record. map.fireflyUpdatedAt holds the time that the
    // last sync saw. If the two are compared with each other, a change made
    // on Firefly after that sync is invisible and the push destroys it.
    FireflyCategory remote;
    try {
      remote = await client.getCategory(map.fireflyId);
    } on FireflyNotFoundException {
      await _tombstoneMapRow(map);
      return;
    }
    FireflySyncDirection direction = decideSyncDirection(
      localModified: category.dateTimeModified,
      remoteUpdatedAt: remote.updatedAt,
      lastSyncedLocalModified: map.lastSyncedLocalModified,
      lastSyncedRemoteUpdatedAt: map.fireflyUpdatedAt,
    );
    if (direction == FireflySyncDirection.push) {
      FireflyCategory updated =
          await client.updateCategory(map.fireflyId, remoteShape);
      await _upsertSyncMap(
        syncMapPk: map.syncMapPk,
        type: FireflySyncEntityType.category,
        localPk: category.categoryPk,
        fireflyId: map.fireflyId,
        fireflyUpdatedAt: updated.updatedAt,
        lastSyncedLocalModified: category.dateTimeModified,
      );
      report.pushedCategories++;
    }
  }
}

Future<void> _pushAccounts(
    FireflyApiClient client,
    DateTime lastSynced,
    _FireflyAssetIndex assets,
    FireflySyncReport report,
    _FireflyPushBacklog backlog,
    {required bool includeUnmodifiedRows}) async {
  List<TransactionWallet> changed = await database.getAllNewWallets(lastSynced);
  for (TransactionWallet wallet in changed) {
    try {
      await _pushOneAccount(
        client: client,
        wallet: wallet,
        assets: assets,
        report: report,
        backlog: backlog,
        includeUnmodifiedRows: includeUnmodifiedRows,
      );
    } on FireflyAuthException {
      rethrow;
    } on FireflyRateLimitException {
      rethrow;
    } catch (e) {
      report.failedWallets++;
      report.warnings.add("The account \"${wallet.name}\" was not pushed: $e");
      backlog.recordNotPushed(wallet.dateTimeModified);
      print("Firefly push-account error (will retry): " + e.toString());
    }
  }
}

// One account of the push. See _pushOneCategory.
Future<void> _pushOneAccount({
  required FireflyApiClient client,
  required TransactionWallet wallet,
  required _FireflyAssetIndex assets,
  required FireflySyncReport report,
  required _FireflyPushBacklog backlog,
  required bool includeUnmodifiedRows,
}) async {
  // getAllNew*() also returns each row that has no dateTimeModified. Such a
  // row is not a recent change: it is a row from a version before that
  // column, or a row from an old backup. The app sends it only if the user
  // asks for the local history.
  if (wallet.dateTimeModified == null && !includeUnmodifiedRows) return;
  FireflySyncMapEntry? tombstone = await _syncMapByLocalPk(
      FireflySyncEntityType.wallet, wallet.walletPk,
      includeTombstones: true);
  if (tombstone != null && tombstone.isTombstone) return;

  FireflySyncMapEntry? map =
      await _syncMapByLocalPk(FireflySyncEntityType.wallet, wallet.walletPk);
  if (map == null) {
    FireflyAccount created;
    try {
      created = await client.createAccount(walletToFireflyAccount(wallet));
    } on FireflyValidationException catch (e) {
      if (!e.isNameInUse) rethrow;
      await _linkWalletToExistingRemote(client, wallet, report);
      return;
    }
    await _upsertSyncMap(
      type: FireflySyncEntityType.wallet,
      localPk: wallet.walletPk,
      fireflyId: created.id,
      fireflyUpdatedAt: created.updatedAt,
      lastSyncedLocalModified: wallet.dateTimeModified,
    );
    report.pushedWallets++;
  } else {
    if (!fireflyLocalRowChanged(
      localModified: wallet.dateTimeModified,
      lastSyncedLocalModified: map.lastSyncedLocalModified,
    )) {
      return;
    }
    // Read the live record. It gives the time of the last remote change and
    // the account role. The local database has no account role, thus an
    // update that does not send the current role changes a savings account
    // or a credit card into a plain asset account.
    FireflyAccount remote;
    try {
      remote = await client.getAccount(map.fireflyId);
    } on FireflyNotFoundException {
      await _tombstoneMapRow(map);
      return;
    }
    FireflySyncDirection direction = decideSyncDirection(
      localModified: wallet.dateTimeModified,
      remoteUpdatedAt: remote.updatedAt,
      lastSyncedLocalModified: map.lastSyncedLocalModified,
      lastSyncedRemoteUpdatedAt: map.fireflyUpdatedAt,
    );
    if (direction == FireflySyncDirection.push) {
      // An account that the user deactivated on Firefly takes no write at
      // all, thus the report of a cycle that held its transactions back does
      // not also rename it.
      if (!remote.active) {
        report.skippedInactiveAccount++;
        backlog.recordNotPushed(wallet.dateTimeModified);
        if (assets.warnedInactive.add(map.fireflyId)) {
          report.warnings.add(
              "The account \"${wallet.name}\" is linked to the Firefly "
              "account \"${remote.name}\", which is inactive. Nothing was "
              "pushed to it. Activate it on Firefly, or link the account to "
              "another Firefly account in the Firefly settings.");
        }
        return;
      }
      // The local database has no active flag either. An update that sends
      // active: true switches on an account that the user deactivated on
      // Firefly.
      FireflyAccount updated;
      try {
        updated = await client.updateAccount(
          map.fireflyId,
          walletToFireflyAccount(wallet,
              existingAccountRole: remote.accountRole,
              existingActive: remote.active),
        );
      } on FireflyValidationException catch (e) {
        // The new name is the name of another Firefly account. The link
        // stays as it is: a rename that failed is not a reason to write the
        // rows of this wallet anywhere else. No hold on the watermark: the
        // same name fails the same way in each cycle, and an edit of the
        // wallet puts it in front of the watermark again.
        if (!e.isNameInUse) rethrow;
        report.failedWallets++;
        report.warnings.add(
            "Firefly refused to rename the account \"${remote.name}\" to "
            "\"${wallet.name}\": another Firefly account has that name. The "
            "account in this app stays linked to \"${remote.name}\".");
        return;
      }
      await _upsertSyncMap(
        syncMapPk: map.syncMapPk,
        type: FireflySyncEntityType.wallet,
        localPk: wallet.walletPk,
        fireflyId: map.fireflyId,
        fireflyUpdatedAt: updated.updatedAt,
        lastSyncedLocalModified: wallet.dateTimeModified,
      );
      report.pushedWallets++;
    }
  }
}

// Firefly refused a new asset account because one with that name is there.
// _pullAccounts links each Firefly asset account to one local account by
// name. A second local account with the same name gets no link, and a push
// of it cannot create a second Firefly account with that name. This function
// links the local account to the Firefly account when no other local account
// holds that link; otherwise it tells the user what to rename.
//
// The 422 answer means that the whole cycle used to stop here, before the
// transactions, thus nothing reached Firefly and the balances drifted.
Future<void> _linkWalletToExistingRemote(FireflyApiClient client,
    TransactionWallet wallet, FireflySyncReport report) async {
  String wanted = wallet.name.trim().toLowerCase();
  // The list holds the inactive accounts too. An account that the user
  // deactivated on Firefly keeps its name, and it stays inactive: a link
  // does not write to it, and a later update keeps its active flag.
  List<FireflyAccount> assets =
      await client.getAccounts(type: kFireflyAssetAccountType);
  FireflyAccount? existing;
  for (FireflyAccount candidate in assets) {
    if (candidate.name.trim().toLowerCase() == wanted) {
      existing = candidate;
      break;
    }
  }
  if (existing == null) {
    report.failedWallets++;
    report.warnings.add(
        "Firefly already uses the name \"${wallet.name}\" for an account that "
        "is not an asset account. Rename the account in this app; the next "
        "sync then creates it on Firefly.");
    return;
  }
  List<FireflySyncMapEntry> linked =
      await _syncMapsByFireflyId(FireflySyncEntityType.wallet, existing.id);
  if (linked.isNotEmpty) {
    report.failedWallets++;
    report.warnings.add(
        "Two accounts in this app are named \"${wallet.name}\", and Firefly "
        "allows one asset account with that name. It is linked to the other "
        "one. Rename this account; the next sync then creates it on Firefly, "
        "and its transactions go with it.");
    return;
  }
  await _upsertSyncMap(
    type: FireflySyncEntityType.wallet,
    localPk: wallet.walletPk,
    fireflyId: existing.id,
    fireflyUpdatedAt: existing.updatedAt,
    lastSyncedLocalModified: wallet.dateTimeModified,
  );
  report.warnings.add(
      "The account \"${wallet.name}\" was linked to the Firefly account with "
      "that name instead of a new one.");
}

// The same for a category. See _linkWalletToExistingRemote.
Future<void> _linkCategoryToExistingRemote(FireflyApiClient client,
    TransactionCategory category, FireflySyncReport report) async {
  String wanted = category.name.trim().toLowerCase();
  List<FireflyCategory> remoteCategories = await client.getCategories();
  FireflyCategory? existing;
  for (FireflyCategory candidate in remoteCategories) {
    if (candidate.name.trim().toLowerCase() == wanted) {
      existing = candidate;
      break;
    }
  }
  if (existing == null) {
    report.failedCategories++;
    report.warnings.add(
        "Firefly refused the category \"${category.name}\" because the name "
        "is in use, but no category with that name came back. Rename the "
        "category in this app.");
    return;
  }
  List<FireflySyncMapEntry> linked =
      await _syncMapsByFireflyId(FireflySyncEntityType.category, existing.id);
  if (linked.isNotEmpty) {
    report.failedCategories++;
    report.warnings.add(
        "Two categories in this app are named \"${category.name}\", and "
        "Firefly allows one category with that name. It is linked to the other "
        "one. Rename this category; the next sync then creates it on Firefly.");
    return;
  }
  await _upsertSyncMap(
    type: FireflySyncEntityType.category,
    localPk: category.categoryPk,
    fireflyId: existing.id,
    fireflyUpdatedAt: existing.updatedAt,
    lastSyncedLocalModified: category.dateTimeModified,
  );
  report.warnings.add(
      "The category \"${category.name}\" was linked to the Firefly category "
      "with that name instead of a new one.");
}

// Builds the split list for a PUT that changes one split of a group.
//
// Firefly deletes each split that the request does not include, and it creates
// a new split when a changed split has no transaction_journal_id. The request
// therefore holds the changed split with its journal id, and the id alone for
// each other split. Firefly finds a submitted id in this group only. A stale
// id makes Firefly create a new split and delete the old one, thus this
// function first looks for the id in the live group and returns null if it is
// not there.
//
// A group with one split is different: Firefly updates that split and ignores
// the submitted id.
List<FireflyTransactionSplit>? _splitsForPartialGroupUpdate({
  required FireflyTransactionGroup remoteGroup,
  required FireflyTransactionSplit changedSplit,
  required int? changedJournalId,
}) {
  if (remoteGroup.splits.length <= 1) return [changedSplit];
  if (changedJournalId == null) return null;
  if (remoteGroup.splits.any((split) => split.transactionJournalId == null)) {
    return null;
  }
  if (!remoteGroup.splits
      .any((split) => split.transactionJournalId == changedJournalId)) {
    return null;
  }
  return [
    for (FireflyTransactionSplit remote in remoteGroup.splits)
      if (remote.transactionJournalId == changedJournalId)
        changedSplit
      else
        FireflyTransactionSplit.unchangedSplit(remote.transactionJournalId!)
  ];
}

// The journal id to store after an update. Firefly keeps the id of a split
// that the request identifies, thus the stored id stays correct. A group with
// one split has no submitted id, thus the response gives the id.
int? _journalIdAfterUpdate(
    FireflyTransactionGroup updated, int? storedJournalId) {
  if (storedJournalId != null &&
      updated.splits
          .any((split) => split.transactionJournalId == storedJournalId)) {
    return storedJournalId;
  }
  if (updated.splits.length == 1) {
    return updated.splits.first.transactionJournalId ?? storedJournalId;
  }
  return storedJournalId;
}

// The position of a split in the group after an update. The answer of the
// server holds each split in its order, thus the id gives the position. The
// stored position stays if the answer does not name the split.
int _splitIndexAfterUpdate(
    FireflyTransactionGroup updated, int? journalId, int storedIndex) {
  if (journalId == null) return storedIndex;
  for (int i = 0; i < updated.splits.length; i++) {
    if (updated.splits[i].transactionJournalId == journalId) return i;
  }
  return storedIndex;
}

// Deletes the Firefly record of a local row that the user marked as not paid,
// and removes the link rows. Each map row must point at the same Firefly
// group: a transfer has two local rows for one remote split.
Future<void> _removeRemoteRowThatIsNotPaid({
  required FireflyApiClient client,
  required List<FireflySyncMapEntry> maps,
  required _FireflyAssetIndex assets,
  // The wallets of the local rows. A delete is a write: the same rules that
  // hold an update back hold it back too.
  required Set<String> walletPks,
  required FireflySyncReport report,
  required _FireflyPushBacklog backlog,
  required DateTime? localModified,
}) async {
  if (maps.isEmpty) return;
  Set<int> walletAccountIds = {};
  for (String walletPk in walletPks) {
    if (await _pushBlockedByAccountState(
        assets: assets,
        walletPk: walletPk,
        localModified: localModified,
        report: report,
        backlog: backlog)) {
      return;
    }
    FireflySyncMapEntry? walletMap =
        await _syncMapByLocalPk(FireflySyncEntityType.wallet, walletPk);
    if (walletMap != null) walletAccountIds.add(walletMap.fireflyId);
  }
  FireflySyncMapEntry first = maps.first;
  FireflyTransactionGroup remoteGroup;
  try {
    remoteGroup = await client.getTransaction(first.fireflyId);
  } on FireflyNotFoundException {
    for (FireflySyncMapEntry map in maps) {
      await _deleteSyncMapRow(map);
    }
    return;
  }
  if (await _pushBlockedByMovedRemoteRow(
      assets: assets,
      split: _splitOfRemoteGroup(remoteGroup, first.fireflyJournalId),
      walletAccountIds: walletAccountIds,
      fireflyId: first.fireflyId,
      localModified: localModified,
      report: report,
      backlog: backlog)) {
    return;
  }
  try {
    if (remoteGroup.splits.length <= 1) {
      await client.deleteTransaction(first.fireflyId);
    } else if (first.fireflyJournalId != null &&
        remoteGroup.splits.any(
            (split) => split.transactionJournalId == first.fireflyJournalId)) {
      await client.deleteTransactionJournal(first.fireflyJournalId!);
    } else {
      report.warnings.add(
          "Did not remove a transaction from Firefly that is no longer paid: "
          "it is one split of a transaction with "
          "${remoteGroup.splits.length} splits, and the app does not know "
          "which one.");
      backlog.recordNotPushed(localModified);
      return;
    }
  } catch (e) {
    report.warnings.add(
        "Could not remove a transaction from Firefly that is no longer paid: "
        "$e");
    backlog.recordNotPushed(localModified);
    return;
  }
  report.deletedRemote++;
  for (FireflySyncMapEntry map in maps) {
    await _deleteSyncMapRow(map);
  }
}

Future<void> _pushTransactions(
    FireflyApiClient client,
    DateTime lastSynced,
    _FireflyCounterpartyIndex counterparties,
    _FireflyAssetIndex assets,
    FireflySyncReport report,
    _FireflyPushBacklog backlog,
    {required bool includeUnmodifiedRows,
    required DateTime? preLinkCutoff}) async {
  List<Transaction> changed = await database.getAllNewTransactions(lastSynced);
  Set<String> handledThisPass = {};

  for (Transaction transaction in changed) {
    if (handledThisPass.contains(transaction.transactionPk)) continue;
    try {
      await _pushOneTransaction(
        client: client,
        transaction: transaction,
        handledThisPass: handledThisPass,
        counterparties: counterparties,
        assets: assets,
        report: report,
        backlog: backlog,
        includeUnmodifiedRows: includeUnmodifiedRows,
        preLinkCutoff: preLinkCutoff,
      );
    } on FireflyAuthException {
      rethrow;
    } on FireflyRateLimitException {
      rethrow;
    } catch (e) {
      report.failedTransactions++;
      report.warnings
          .add("The transaction \"${transaction.name}\" was not pushed: $e");
      backlog.recordNotPushed(transaction.dateTimeModified);
      // The other side of a transfer is the same remote record. A second
      // attempt in this pass fails the same way and gives one more warning.
      handledThisPass.add(transaction.transactionPk);
      if (transaction.pairedTransactionFk != null) {
        handledThisPass.add(transaction.pairedTransactionFk!);
      }
      print("Firefly push-transaction error (will retry): " + e.toString());
    }
  }
}

// True for a row that was booked before this device was linked to Firefly and
// that no Firefly record is linked to.
//
// Firefly is the system of record. On a link both sides are usually already
// populated, and a transaction cannot be matched by content, thus uploading
// local history makes a second copy of every record the pull just brought
// down. Only "Push local history" does that, and it passes a null cutoff.
//
// The test is on dateCreated, the booking date, and not on dateTimeModified.
// A bulk operation of this app - deleting the primary wallet, which copies
// another wallet onto it and moves its rows - stamps the current time onto
// the modified column of every row it touches. On that column each of those
// rows would read as new and be created a second time on the server, which
// is what happened on 2026-09-10. The cost is a row that the user enters
// today with an old date: it counts as history and waits for the user to
// upload it, and the cycle says so once.
bool _pushIsPreLinkHistory({
  required Transaction transaction,
  required FireflySyncMapEntry? map,
  required DateTime? preLinkCutoff,
}) {
  if (map != null) return false;
  if (preLinkCutoff == null) return false;
  return transaction.dateCreated.isBefore(preLinkCutoff);
}

// The one warning of a cycle that held such rows back.
void _reportPreLinkHistory(FireflySyncReport report) {
  if (report.skippedPreLinkHistory != 1) return;
  report.warnings.add(
      "Some transactions are dated before this device was linked to Firefly "
      "and were not uploaded. Firefly may already hold them under another "
      "record. Use \"Push local history\" in the Firefly settings to upload "
      "all of the local history.");
}

// One transaction of the push. See _pushOneCategory.
Future<void> _pushOneTransaction({
  required FireflyApiClient client,
  required Transaction transaction,
  required Set<String> handledThisPass,
  required _FireflyCounterpartyIndex counterparties,
  required _FireflyAssetIndex assets,
  required FireflySyncReport report,
  required _FireflyPushBacklog backlog,
  required bool includeUnmodifiedRows,
  // The link moment. A row booked before it and linked to nothing is local
  // history and stays local; see _pushIsPreLinkHistory. null uploads it.
  required DateTime? preLinkCutoff,
}) async {
  // getAllNew*() also returns each row that has no dateTimeModified. Such a
  // row is not a recent change: it is a row from a version before that
  // column, or a row from an old backup. The app sends it only if the user
  // asks for the local history.
  if (transaction.dateTimeModified == null && !includeUnmodifiedRows) {
    return;
  }

  // Balance anchors exist only because the local database holds a window
  // rather than the whole ledger. Firefly already knows the balance they
  // stand in for, so pushing one would double-count it on the remote side.
  if (isFireflyBalanceAnchorPk(transaction.transactionPk)) return;

  FireflySyncMapEntry? tombstone = await _syncMapByLocalPk(
      FireflySyncEntityType.transaction, transaction.transactionPk,
      includeTombstones: true);
  if (tombstone != null && tombstone.isTombstone) return;

  if (transaction.pairedTransactionFk != null) {
    await _pushTransfer(
      client: client,
      transaction: transaction,
      handledThisPass: handledThisPass,
      assets: assets,
      report: report,
      backlog: backlog,
      preLinkCutoff: preLinkCutoff,
    );
    return;
  }

  // Firefly has no state for a transaction that is not yet paid. Each
  // transaction that Firefly holds changes the balance of its account. A
  // local row that is not paid is an expected payment, thus the app does not
  // send it. If the user marks the row paid, the next cycle creates it.
  if (transaction.paid == false) {
    FireflySyncMapEntry? paidMap = await _syncMapByLocalPk(
        FireflySyncEntityType.transaction, transaction.transactionPk);
    if (paidMap != null) {
      await _removeRemoteRowThatIsNotPaid(
        client: client,
        maps: [paidMap],
        assets: assets,
        walletPks: {transaction.walletFk},
        report: report,
        backlog: backlog,
        localModified: transaction.dateTimeModified,
      );
    }
    return;
  }

  FireflySyncMapEntry? walletMap = await _syncMapByLocalPk(
      FireflySyncEntityType.wallet, transaction.walletFk);
  if (walletMap == null) {
    report.skippedUnmappedWallet++;
    backlog.recordNotPushed(transaction.dateTimeModified);
    return;
  }

  FireflySyncMapEntry? categoryMap = await _syncMapByLocalPk(
      FireflySyncEntityType.category, transaction.categoryFk);
  TransactionCategory? category;
  try {
    category = await database.getCategoryInstance(transaction.categoryFk);
  } catch (_) {}
  // The row goes back with no category. The app must not make a category on
  // the server for it.
  if (transaction.categoryFk == kFireflyUncategorizedCategoryPk) {
    category = null;
  }

  FireflySyncMapEntry? map = await _syncMapByLocalPk(
      FireflySyncEntityType.transaction, transaction.transactionPk);

  FireflyAccount? counterparty = resolvePushCounterparty(
    isIncome: transaction.amount > 0,
    transactionName: transaction.name,
    categoryName: category?.name,
    storedCounterpartyId: map?.counterpartyFireflyId,
    counterpartiesById: counterparties.byId,
    expenseByName: counterparties.expenseByName,
    revenueByName: counterparties.revenueByName,
  );

  if (map != null) {
    List<FireflySyncMapEntry> groupMaps = await _syncMapsByFireflyId(
        FireflySyncEntityType.transaction, map.fireflyId);
    bool multiSplit =
        groupMaps.any((m) => m.fireflySplitIndex != map.fireflySplitIndex);
    if (multiSplit) {
      // Before the request, not after it. The rows of the group are one
      // request; a request that fails must not run again for each row of
      // the group in the same pass.
      for (FireflySyncMapEntry groupMap in groupMaps) {
        handledThisPass.add(groupMap.localPk);
      }
      await _pushExistingMultiSplitGroup(
        client: client,
        groupMaps: groupMaps,
        counterparties: counterparties,
        assets: assets,
        report: report,
        backlog: backlog,
      );
      return;
    }
  }

  TransactionWallet? pushWallet =
      await database.getWalletInstanceOrNull(transaction.walletFk);
  (int?, String?) otherSide = _pushCounterparty(
    resolved: counterparty,
    counterparties: counterparties,
    categoryName: category?.name,
  );
  FireflyTransactionSplit split = transactionToFireflySplit(
    transaction,
    walletFireflyId: walletMap.fireflyId,
    walletCurrencyCode: pushWallet?.currency,
    categoryFireflyId: categoryMap?.fireflyId,
    categoryName: category?.name,
    counterpartyFireflyId: otherSide.$1,
    counterpartyName: otherSide.$2,
    transactionJournalId: map?.fireflyJournalId,
  );
  FireflyTransactionGroup group =
      FireflyTransactionGroup(id: 0, splits: [split]);

  if (map == null) {
    // No backlog hold: the watermark must move past these rows, or each
    // cycle reads the whole of the local history again.
    if (_pushIsPreLinkHistory(
        transaction: transaction, map: map, preLinkCutoff: preLinkCutoff)) {
      report.skippedPreLinkHistory++;
      _reportPreLinkHistory(report);
      return;
    }
    if (await _pushBlockedByAccountState(
        assets: assets,
        walletPk: transaction.walletFk,
        localModified: transaction.dateTimeModified,
        report: report,
        backlog: backlog)) {
      return;
    }
    FireflyTransactionGroup created = await client.createTransaction(group);
    int? createdCounterpartyId = counterparty?.id;
    if (createdCounterpartyId == null && created.splits.isNotEmpty) {
      createdCounterpartyId = transaction.amount > 0
          ? created.splits.first.sourceId
          : created.splits.first.destinationId;
    }
    await _upsertSyncMap(
      type: FireflySyncEntityType.transaction,
      localPk: transaction.transactionPk,
      fireflyId: created.id,
      fireflyUpdatedAt: created.updatedAt,
      lastSyncedLocalModified: transaction.dateTimeModified,
      counterpartyFireflyId: createdCounterpartyId,
      fireflyJournalId: created.splits.isEmpty
          ? null
          : created.splits.first.transactionJournalId,
    );
    report.pushedTransactions++;
  } else {
    if (!fireflyLocalRowChanged(
      localModified: transaction.dateTimeModified,
      lastSyncedLocalModified: map.lastSyncedLocalModified,
    )) {
      return;
    }
    if (await _pushBlockedByAccountState(
        assets: assets,
        walletPk: transaction.walletFk,
        localModified: transaction.dateTimeModified,
        report: report,
        backlog: backlog)) {
      return;
    }
    // Read the live group. It gives the time of the last remote change, and
    // it shows each split that Firefly holds. The multiSplit test above uses
    // the sync map only, thus it does not know a split on an account that is
    // not linked, or a split outside the window of the sync.
    FireflyTransactionGroup remoteGroup;
    try {
      remoteGroup = await client.getTransaction(map.fireflyId);
    } on FireflyNotFoundException {
      await _tombstoneMapRow(map);
      return;
    }
    FireflySyncDirection direction = decideSyncDirection(
      localModified: transaction.dateTimeModified,
      remoteUpdatedAt: remoteGroup.updatedAt,
      lastSyncedLocalModified: map.lastSyncedLocalModified,
      lastSyncedRemoteUpdatedAt: map.fireflyUpdatedAt,
    );
    if (direction == FireflySyncDirection.push) {
      if (await _pushBlockedByMovedRemoteRow(
          assets: assets,
          split: _splitOfRemoteGroup(remoteGroup, map.fireflyJournalId),
          walletAccountIds: {walletMap.fireflyId},
          fireflyId: map.fireflyId,
          localModified: transaction.dateTimeModified,
          report: report,
          backlog: backlog)) {
        return;
      }
      List<FireflyTransactionSplit>? splits = _splitsForPartialGroupUpdate(
        remoteGroup: remoteGroup,
        changedSplit: split,
        changedJournalId: map.fireflyJournalId,
      );
      if (splits == null) {
        report.warnings
            .add("Did not push a change to a split transaction: it has "
                "${remoteGroup.splits.length} splits on Firefly, and the app "
                "does not know which one belongs to this record.");
        backlog.recordNotPushed(transaction.dateTimeModified);
        return;
      }
      FireflyTransactionGroup updated;
      try {
        updated = await client.updateTransaction(map.fireflyId,
            FireflyTransactionGroup(id: map.fireflyId, splits: splits));
      } on FireflyNotFoundException {
        // Deleted between the read above and this write. Without the
        // tombstone the link stays, and every later cycle takes the same 404
        // for this row for ever.
        await _tombstoneMapRow(map);
        return;
      }
      await _upsertSyncMap(
        syncMapPk: map.syncMapPk,
        type: FireflySyncEntityType.transaction,
        localPk: transaction.transactionPk,
        fireflyId: map.fireflyId,
        fireflyUpdatedAt: updated.updatedAt,
        lastSyncedLocalModified: transaction.dateTimeModified,
        counterpartyFireflyId: counterparty?.id ?? map.counterpartyFireflyId,
        fireflySplitIndex: map.fireflySplitIndex,
        fireflyJournalId: _journalIdAfterUpdate(updated, map.fireflyJournalId),
      );
      report.pushedTransactions++;
    }
  }
}

// Rebuilds the Firefly split of the local row that a sync-map row points at.
// It returns null if the local row is gone or if the wallet of that row is not
// linked.
Future<FireflyTransactionSplit?> _splitForMappedLocalRow({
  required FireflySyncMapEntry map,
  required _FireflyCounterpartyIndex counterparties,
  Transaction? local,
}) async {
  local ??= await database.tryGetTransactionFromPk(map.localPk);
  if (local == null) return null;
  FireflySyncMapEntry? walletMap =
      await _syncMapByLocalPk(FireflySyncEntityType.wallet, local.walletFk);
  if (walletMap == null) return null;
  FireflySyncMapEntry? categoryMap =
      await _syncMapByLocalPk(FireflySyncEntityType.category, local.categoryFk);
  TransactionCategory? category;
  try {
    category = await database.getCategoryInstance(local.categoryFk);
  } catch (_) {}
  if (local.categoryFk == kFireflyUncategorizedCategoryPk) category = null;
  FireflyAccount? counterparty = resolvePushCounterparty(
    isIncome: local.amount > 0,
    transactionName: local.name,
    categoryName: category?.name,
    storedCounterpartyId: map.counterpartyFireflyId,
    counterpartiesById: counterparties.byId,
    expenseByName: counterparties.expenseByName,
    revenueByName: counterparties.revenueByName,
  );
  TransactionWallet? localWallet =
      await database.getWalletInstanceOrNull(local.walletFk);
  (int?, String?) otherSide = _pushCounterparty(
    resolved: counterparty,
    counterparties: counterparties,
    categoryName: category?.name,
  );
  return transactionToFireflySplit(
    local,
    walletFireflyId: walletMap.fireflyId,
    walletCurrencyCode: localWallet?.currency,
    categoryFireflyId: categoryMap?.fireflyId,
    categoryName: category?.name,
    counterpartyFireflyId: otherSide.$1,
    counterpartyName: otherSide.$2,
    transactionJournalId: map.fireflyJournalId,
  );
}

// Pushes the local changes of a group that holds more than one split.
//
// The request holds one entry for each split that Firefly has, in the order
// that Firefly gives. A split with a local row gets the rebuilt content. Each
// other split gets its id alone, which keeps it as it is. If a local row is
// not known as a split of the live group, the app cannot say which split it
// is, and this function makes no request.
Future<void> _pushExistingMultiSplitGroup({
  required FireflyApiClient client,
  required List<FireflySyncMapEntry> groupMaps,
  required _FireflyCounterpartyIndex counterparties,
  required _FireflyAssetIndex assets,
  required FireflySyncReport report,
  required _FireflyPushBacklog backlog,
}) async {
  DateTime? newestLocal;
  DateTime? newestWatermark;
  Set<String> walletPks = {};
  for (FireflySyncMapEntry map in groupMaps) {
    Transaction? local = await database.tryGetTransactionFromPk(map.localPk);
    if (local != null) walletPks.add(local.walletFk);
    if (local?.dateTimeModified != null &&
        (newestLocal == null ||
            local!.dateTimeModified!.isAfter(newestLocal))) {
      newestLocal = local!.dateTimeModified;
    }
    if (map.lastSyncedLocalModified != null &&
        (newestWatermark == null ||
            map.lastSyncedLocalModified!.isAfter(newestWatermark))) {
      newestWatermark = map.lastSyncedLocalModified;
    }
  }
  if (!fireflyLocalRowChanged(
    localModified: newestLocal,
    lastSyncedLocalModified: newestWatermark,
  )) {
    return;
  }
  // The request rewrites each split that has a local row. One of them on an
  // inactive account holds the whole group back.
  for (String walletPk in walletPks) {
    if (await _pushBlockedByAccountState(
        assets: assets,
        walletPk: walletPk,
        localModified: newestLocal,
        report: report,
        backlog: backlog)) {
      return;
    }
  }

  FireflyTransactionGroup remoteGroup;
  try {
    remoteGroup = await client.getTransaction(groupMaps.first.fireflyId);
  } on FireflyNotFoundException {
    for (FireflySyncMapEntry map in groupMaps) {
      await _tombstoneMapRow(map);
    }
    return;
  }

  FireflySyncDirection direction = decideSyncDirection(
    localModified: newestLocal,
    remoteUpdatedAt: remoteGroup.updatedAt,
    lastSyncedLocalModified: newestWatermark,
    lastSyncedRemoteUpdatedAt: groupMaps.first.fireflyUpdatedAt,
  );
  if (direction != FireflySyncDirection.push) return;

  // A row that holds no journal id at all cannot go into the request: the
  // app cannot say which split it is, and a request that does not name it
  // makes Firefly delete that split. The group waits for the next pull, which
  // gives the id.
  if (groupMaps.any((map) => map.fireflyJournalId == null)) {
    report.warnings.add(
        "Did not push a change to a split transaction: the app cannot say "
        "which of its ${remoteGroup.splits.length} splits each local record "
        "belongs to.");
    backlog.recordNotPushed(newestLocal);
    return;
  }

  // A row whose journal id is not in the live group points at a split that
  // the server no longer holds. To stop the full group for that one row stops
  // each other row of it, thus the app unlinks that row and pushes the rest.
  List<FireflySyncMapEntry> mappedGroupMaps = [];
  for (FireflySyncMapEntry map in groupMaps) {
    if (remoteGroup.splits
        .any((split) => split.transactionJournalId == map.fireflyJournalId)) {
      mappedGroupMaps.add(map);
      continue;
    }
    await _tombstoneMapRow(map);
    report.warnings.add(
        "A record of a split transaction is no longer on Firefly. This app "
        "keeps the record and no longer syncs it.");
  }
  if (mappedGroupMaps.isEmpty) return;
  groupMaps = mappedGroupMaps;

  // Each split of the request must already sit on the account of the wallet
  // that holds its local row. One that does not holds the whole group back:
  // the request rewrites every split at once.
  for (FireflySyncMapEntry map in groupMaps) {
    Transaction? local = await database.tryGetTransactionFromPk(map.localPk);
    if (local == null) continue;
    FireflySyncMapEntry? walletMap =
        await _syncMapByLocalPk(FireflySyncEntityType.wallet, local.walletFk);
    if (walletMap == null) continue;
    if (await _pushBlockedByMovedRemoteRow(
        assets: assets,
        split: _splitOfRemoteGroup(remoteGroup, map.fireflyJournalId),
        walletAccountIds: {walletMap.fireflyId},
        fireflyId: map.fireflyId,
        localModified: newestLocal,
        report: report,
        backlog: backlog)) {
      return;
    }
  }

  // A PUT must name each split by its id. A split that comes with no id thus
  // stops the request. To read the id with `!` throws here and stops the full
  // cycle, and each later cycle again.
  if (remoteGroup.splits.any((split) => split.transactionJournalId == null)) {
    report.warnings.add(
        "Did not push a change to a split transaction: Firefly gave a split "
        "with no journal id.");
    backlog.recordNotPushed(newestLocal);
    return;
  }

  List<FireflyTransactionSplit> splits = [];
  Map<int, int> positionByJournalId = {};
  for (int i = 0; i < remoteGroup.splits.length; i++) {
    FireflyTransactionSplit remote = remoteGroup.splits[i];
    int journalId = remote.transactionJournalId!;
    positionByJournalId[journalId] = i;
    Iterable<FireflySyncMapEntry> matches =
        groupMaps.where((map) => map.fireflyJournalId == journalId);
    FireflyTransactionSplit? rebuilt = matches.isEmpty
        ? null
        : await _splitForMappedLocalRow(
            map: matches.first, counterparties: counterparties);
    splits.add(rebuilt ?? FireflyTransactionSplit.unchangedSplit(journalId));
  }

  FireflyTransactionGroup updated = await client.updateTransaction(
    groupMaps.first.fireflyId,
    FireflyTransactionGroup(id: groupMaps.first.fireflyId, splits: splits),
  );
  for (FireflySyncMapEntry map in groupMaps) {
    Transaction? local = await database.tryGetTransactionFromPk(map.localPk);
    await _upsertSyncMap(
      syncMapPk: map.syncMapPk,
      type: FireflySyncEntityType.transaction,
      localPk: map.localPk,
      fireflyId: map.fireflyId,
      fireflyUpdatedAt: updated.updatedAt,
      lastSyncedLocalModified: local?.dateTimeModified,
      counterpartyFireflyId: map.counterpartyFireflyId,
      fireflySplitIndex:
          positionByJournalId[map.fireflyJournalId] ?? map.fireflySplitIndex,
      fireflyJournalId: _journalIdAfterUpdate(updated, map.fireflyJournalId),
    );
  }
  report.pushedTransactions++;
}

Future<void> _pushTransfer({
  required FireflyApiClient client,
  required Transaction transaction,
  required Set<String> handledThisPass,
  required _FireflyAssetIndex assets,
  required FireflySyncReport report,
  required _FireflyPushBacklog backlog,
  // See preLinkCutoff in _pushOneTransaction.
  required DateTime? preLinkCutoff,
}) async {
  Transaction? paired =
      await database.tryGetTransactionFromPk(transaction.pairedTransactionFk!);
  if (paired == null) {
    // Firefly holds a transfer as one split with two accounts, thus the app
    // cannot send one side alone. Keep the change for a later cycle: the row
    // is behind the watermark after this cycle, and no other test finds it.
    handledThisPass.add(transaction.transactionPk);
    report.warnings.add(
        "Did not push a change to a transfer: this app holds one of its two "
        "sides only.");
    backlog.recordNotPushed(transaction.dateTimeModified);
    return;
  }

  Transaction fromTransaction = transaction.amount < 0 ? transaction : paired;
  Transaction toTransaction = transaction.amount < 0 ? paired : transaction;

  FireflySyncMapEntry? fromWalletMap = await _syncMapByLocalPk(
      FireflySyncEntityType.wallet, fromTransaction.walletFk);
  FireflySyncMapEntry? toWalletMap = await _syncMapByLocalPk(
      FireflySyncEntityType.wallet, toTransaction.walletFk);
  handledThisPass.add(transaction.transactionPk);
  handledThisPass.add(paired.transactionPk);
  if (fromWalletMap == null || toWalletMap == null) {
    report.skippedUnmappedWallet++;
    backlog.recordNotPushed(transaction.dateTimeModified);
    return;
  }

  FireflySyncMapEntry? fromMap = await _syncMapByLocalPk(
      FireflySyncEntityType.transaction, fromTransaction.transactionPk);
  FireflySyncMapEntry? toMap = await _syncMapByLocalPk(
      FireflySyncEntityType.transaction, toTransaction.transactionPk);

  // The two local rows of a transfer are one Firefly split, thus their rows
  // must give the same group. Two different groups mean that the user made
  // the pair from two records that each already had a Firefly record. To go
  // on writes both rows onto one group and leaves the other group on the
  // server with no local row, and the next pull then makes a second copy of
  // it. The app makes no request and tells the user.
  if (fromMap != null &&
      toMap != null &&
      fromMap.fireflyId != toMap.fireflyId) {
    report.warnings.add(
        "Did not push a change to a transfer: its two sides point at two "
        "different Firefly transactions. Remove one side and make it again.");
    backlog.recordNotPushed(transaction.dateTimeModified);
    return;
  }

  // Firefly counts each transaction that it holds in the balance of its
  // accounts, thus a transfer that is not yet paid stays local. Both sides
  // must be paid.
  if (fromTransaction.paid == false || toTransaction.paid == false) {
    List<FireflySyncMapEntry> maps = [
      if (fromMap != null) fromMap,
      if (toMap != null) toMap,
    ];
    if (maps.isNotEmpty) {
      await _removeRemoteRowThatIsNotPaid(
        client: client,
        maps: maps,
        assets: assets,
        walletPks: {fromTransaction.walletFk, toTransaction.walletFk},
        report: report,
        backlog: backlog,
        localModified: transaction.dateTimeModified,
      );
    }
    return;
  }

  // The side that the user changed last gives the text of the one remote
  // split.
  bool toSideIsNewer = toTransaction.dateTimeModified != null &&
      (fromTransaction.dateTimeModified == null ||
          toTransaction.dateTimeModified!
              .isAfter(fromTransaction.dateTimeModified!));
  int? storedJournalId = fromMap?.fireflyJournalId ?? toMap?.fireflyJournalId;
  // The currencies of the two wallets. A transfer between two currencies
  // must carry both amounts, or Firefly counts the source amount on the
  // destination account.
  TransactionWallet? fromWallet =
      await database.getWalletInstanceOrNull(fromTransaction.walletFk);
  TransactionWallet? toWallet =
      await database.getWalletInstanceOrNull(toTransaction.walletFk);
  FireflyTransactionSplit buildSplit({
    double? sourceAmountOverride,
    double? destinationAmountOverride,
  }) {
    return transferPairToFireflySplit(
      fromTransaction: fromTransaction,
      toTransaction: toTransaction,
      fromWalletFireflyId: fromWalletMap.fireflyId,
      toWalletFireflyId: toWalletMap.fireflyId,
      fromCurrency: fromWallet?.currency,
      toCurrency: toWallet?.currency,
      descriptionOverride: toSideIsNewer ? toTransaction.name : null,
      notesOverride: toSideIsNewer ? toTransaction.note : null,
      sourceAmountOverride: sourceAmountOverride,
      destinationAmountOverride: destinationAmountOverride,
      transactionJournalId: storedJournalId,
    );
  }

  // Either side of the transfer on an inactive account holds it back.
  Future<bool> blockedByInactiveAccount(DateTime? localModified) async {
    for (String walletPk in {
      fromTransaction.walletFk,
      toTransaction.walletFk
    }) {
      if (await _pushBlockedByAccountState(
          assets: assets,
          walletPk: walletPk,
          localModified: localModified,
          report: report,
          backlog: backlog)) {
        return true;
      }
    }
    return false;
  }

  if (fromMap == null && toMap == null) {
    if (_pushIsPreLinkHistory(
        transaction: fromTransaction,
        map: null,
        preLinkCutoff: preLinkCutoff)) {
      report.skippedPreLinkHistory++;
      _reportPreLinkHistory(report);
      return;
    }
    if (await blockedByInactiveAccount(transaction.dateTimeModified)) return;
    FireflyTransactionGroup created = await client.createTransaction(
        FireflyTransactionGroup(id: 0, splits: [buildSplit()]));
    // The two local rows are one remote split, thus they share its journal id.
    int? createdJournalId = created.splits.isEmpty
        ? null
        : created.splits.first.transactionJournalId;
    await _upsertSyncMap(
      type: FireflySyncEntityType.transaction,
      localPk: fromTransaction.transactionPk,
      fireflyId: created.id,
      fireflyUpdatedAt: created.updatedAt,
      lastSyncedLocalModified: fromTransaction.dateTimeModified,
      fireflySplitIndex: 0,
      fireflyJournalId: createdJournalId,
    );
    await _upsertSyncMap(
      type: FireflySyncEntityType.transaction,
      localPk: toTransaction.transactionPk,
      fireflyId: created.id,
      fireflyUpdatedAt: created.updatedAt,
      lastSyncedLocalModified: toTransaction.dateTimeModified,
      fireflySplitIndex: 0,
      fireflyJournalId: createdJournalId,
    );
    report.pushedTransactions++;
    return;
  }

  FireflySyncMapEntry linkedMap = (fromMap ?? toMap)!;
  // Each side has its own watermark, and the user can change either side. If
  // the app looks at the source row only, a change to the destination row
  // never goes to Firefly.
  bool fromChanged = fireflyLocalRowChanged(
    localModified: fromTransaction.dateTimeModified,
    lastSyncedLocalModified: fromMap?.lastSyncedLocalModified,
  );
  bool toChanged = fireflyLocalRowChanged(
    localModified: toTransaction.dateTimeModified,
    lastSyncedLocalModified: toMap?.lastSyncedLocalModified,
  );
  if (!fromChanged && !toChanged) return;

  DateTime? newestLocal = toSideIsNewer
      ? toTransaction.dateTimeModified
      : fromTransaction.dateTimeModified;
  if (await blockedByInactiveAccount(newestLocal)) return;

  FireflyTransactionGroup remoteGroup;
  try {
    remoteGroup = await client.getTransaction(linkedMap.fireflyId);
  } on FireflyNotFoundException {
    if (fromMap != null) await _tombstoneMapRow(fromMap);
    if (toMap != null) await _tombstoneMapRow(toMap);
    return;
  }

  FireflySyncDirection direction = decideSyncDirection(
    localModified: newestLocal,
    remoteUpdatedAt: remoteGroup.updatedAt,
    lastSyncedLocalModified: null,
    lastSyncedRemoteUpdatedAt: linkedMap.fireflyUpdatedAt,
  );
  if (direction != FireflySyncDirection.push) return;

  if (await _pushBlockedByMovedRemoteRow(
      assets: assets,
      split: _splitOfRemoteGroup(remoteGroup, storedJournalId),
      walletAccountIds: {fromWalletMap.fireflyId, toWalletMap.fireflyId},
      fireflyId: linkedMap.fireflyId,
      localModified: newestLocal,
      report: report,
      backlog: backlog)) {
    return;
  }

  // A transfer between two currencies is one Firefly split that carries the
  // amount of the source wallet and the foreign amount of the destination
  // wallet. The app keeps the two in two rows, and it sends both of them on
  // every push. A local row that a build with a bug wrote thus overwrites a
  // value on the server that is right: on 2026-09-10 a push of an edit to
  // the source leg replaced the foreign amount 22.98 USD of a transfer with
  // 2,850, the amount of the source row.
  //
  // The side that did not change locally therefore keeps what Firefly holds,
  // and the local row of that side is repaired with it.
  FireflyTransactionSplit? remoteSplit =
      _splitOfRemoteGroup(remoteGroup, storedJournalId);
  String? fromCode = fromWallet?.currency?.trim().toUpperCase();
  String? toCode = toWallet?.currency?.trim().toUpperCase();
  bool crossCurrency = fromCode != null &&
      toCode != null &&
      fromCode.isNotEmpty &&
      toCode.isNotEmpty &&
      fromCode != toCode;
  double? sourceAmountOverride;
  double? destinationAmountOverride;
  if (crossCurrency && remoteSplit != null) {
    if (!fromChanged &&
        _fireflyAmountDiffers(
            remoteSplit.amount.abs(), fromTransaction.amount.abs())) {
      sourceAmountOverride = remoteSplit.amount.abs();
    }
    if (!toChanged) {
      double remoteDestination =
          transferDestinationAmount(remoteSplit, toWallet?.currency);
      if (_fireflyAmountDiffers(
          remoteDestination, toTransaction.amount.abs())) {
        destinationAmountOverride = remoteDestination;
      }
    }
  }
  FireflyTransactionSplit split = buildSplit(
    sourceAmountOverride: sourceAmountOverride,
    destinationAmountOverride: destinationAmountOverride,
  );

  List<FireflyTransactionSplit>? splits = _splitsForPartialGroupUpdate(
    remoteGroup: remoteGroup,
    changedSplit: split,
    changedJournalId: storedJournalId,
  );
  if (splits == null) {
    report.warnings.add(
        "Did not push a change to a transfer: its Firefly transaction has "
        "${remoteGroup.splits.length} splits, and the app does not know which "
        "one is the transfer.");
    backlog.recordNotPushed(newestLocal);
    return;
  }

  // Repair the local rows first. The value that goes on the wire is the one
  // Firefly holds, thus the rows must hold it too, or the wallet totals of
  // this app stay wrong and the next cycle sends the stale value again.
  Transaction fromRow = fromTransaction;
  Transaction toRow = toTransaction;
  if (sourceAmountOverride != null || destinationAmountOverride != null) {
    await database.transaction(() async {
      if (sourceAmountOverride != null) {
        await database.createOrUpdateTransaction(
            fromTransaction.copyWith(amount: -sourceAmountOverride.abs()),
            insert: false,
            updateSharedEntry: false,
            fireflySync: true);
      }
      if (destinationAmountOverride != null) {
        await database.createOrUpdateTransaction(
            toTransaction.copyWith(amount: destinationAmountOverride.abs()),
            insert: false,
            updateSharedEntry: false,
            fireflySync: true);
      }
    });
    // Read them back: the write stamps a new dateTimeModified, and the map
    // rows below must carry that stamp. With the old one each cycle from
    // here on reads the row as changed and pushes it again.
    fromRow =
        await database.tryGetTransactionFromPk(fromTransaction.transactionPk) ??
            fromTransaction;
    toRow =
        await database.tryGetTransactionFromPk(toTransaction.transactionPk) ??
            toTransaction;
    report.pulledTransactions += (sourceAmountOverride != null ? 1 : 0) +
        (destinationAmountOverride != null ? 1 : 0);
  }

  FireflyTransactionGroup updated = await client.updateTransaction(
      linkedMap.fireflyId,
      FireflyTransactionGroup(id: linkedMap.fireflyId, splits: splits));
  // _upsertSyncMap writes with insertOrReplace, thus each field that this call
  // does not give gets its default value. If the journal id is not given here,
  // each transfer push erases it.
  int? transferJournalId = _journalIdAfterUpdate(updated, storedJournalId);
  // The position of the split in the group. The answer of the server gives it
  // when it names the split, thus a group that moved its splits stays right.
  int transferSplitIndex = _splitIndexAfterUpdate(
    updated,
    transferJournalId,
    fromMap?.fireflySplitIndex ?? toMap?.fireflySplitIndex ?? 0,
  );
  await _upsertSyncMap(
    syncMapPk: fromMap?.syncMapPk,
    type: FireflySyncEntityType.transaction,
    localPk: fromTransaction.transactionPk,
    fireflyId: linkedMap.fireflyId,
    fireflyUpdatedAt: updated.updatedAt,
    lastSyncedLocalModified: fromRow.dateTimeModified,
    fireflySplitIndex: transferSplitIndex,
    fireflyJournalId: transferJournalId,
  );
  await _upsertSyncMap(
    syncMapPk: toMap?.syncMapPk,
    type: FireflySyncEntityType.transaction,
    localPk: toTransaction.transactionPk,
    fireflyId: linkedMap.fireflyId,
    fireflyUpdatedAt: updated.updatedAt,
    lastSyncedLocalModified: toRow.dateTimeModified,
    fireflySplitIndex: transferSplitIndex,
    fireflyJournalId: transferJournalId,
  );
  report.pushedTransactions++;
}

Future<void> _pushDeletes(
    FireflyApiClient client,
    DateTime lastSynced,
    _FireflyAssetIndex assets,
    FireflySyncReport report,
    _FireflyPushBacklog backlog) async {
  List<DeleteLog> deleteLogs = await database.getAllNewDeleteLogs(lastSynced);
  Set<int> remoteDeletedTransactionIds = {};

  // First pass: the wallets. A wallet that the user deletes in this app is
  // unlinked from Firefly, and the Firefly account stays. DELETE on a Firefly
  // account destroys each transaction of that account, and also each other
  // split of the groups that hold them, which is history that the user did
  // not delete.
  //
  // deleteWallet() deletes the transactions of the wallet before it writes the
  // delete log of the wallet, thus the local rows are gone and the second pass
  // cannot read the wallet of a deleted transaction. The Firefly ids that this
  // pass collects tell the second pass which transaction to keep.
  Set<int> unlinkedAccountIds = {};
  for (DeleteLog log in deleteLogs) {
    if (log.type != DeleteLogType.TransactionWallet) continue;
    if (log.entryPk == "0") continue;
    FireflySyncMapEntry? map = await _syncMapByLocalPk(
        FireflySyncEntityType.wallet, log.entryPk,
        includeTombstones: true);
    if (map == null) continue;
    // The id goes into the set on each cycle, also when a cycle before this
    // one closed the link. The second pass uses the set to hold back a
    // transaction of the removed account. An empty set on a retry cycle lets
    // that transaction take the delete path and destroys the remote record.
    unlinkedAccountIds.add(map.fireflyId);
    if (map.isTombstone) continue;
    await _tombstoneMapRow(map);
    report.warnings
        .add("An account was removed in this app. Its Firefly account and the "
            "transactions of that account stay on the server, and this app no "
            "longer syncs them.");
  }

  for (DeleteLog log in deleteLogs) {
    FireflySyncEntityType? type;
    if (log.type == DeleteLogType.Transaction) {
      type = FireflySyncEntityType.transaction;
    } else if (log.type == DeleteLogType.TransactionCategory) {
      if (log.entryPk == "0") continue;
      type = FireflySyncEntityType.category;
    } else {
      continue;
    }

    FireflySyncMapEntry? map =
        await _syncMapByLocalPk(type, log.entryPk, includeTombstones: true);
    if (map == null) continue;
    if (map.isTombstone) continue;

    try {
      if (type == FireflySyncEntityType.transaction) {
        if (remoteDeletedTransactionIds.contains(map.fireflyId)) {
          await _tombstoneMapRow(map);
          continue;
        }
        if (unlinkedAccountIds.isNotEmpty &&
            await _transactionIsOnUnlinkedAccount(
                client: client,
                fireflyId: map.fireflyId,
                unlinkedAccountIds: unlinkedAccountIds)) {
          // The user deleted the account, not this transaction.
          await _tombstoneMapRow(map);
          continue;
        }
        List<FireflySyncMapEntry> groupMaps = await _syncMapsByFireflyId(
            FireflySyncEntityType.transaction, map.fireflyId);
        // A transfer is two local rows that point at one remote split. Such a
        // row is the other side of the transfer, not another split.
        bool pairedLegStillLocal = false;
        for (FireflySyncMapEntry sibling in groupMaps) {
          if (sibling.localPk == map.localPk) continue;
          bool sameRemoteSplit =
              (sibling.fireflyJournalId != null && map.fireflyJournalId != null)
                  ? sibling.fireflyJournalId == map.fireflyJournalId
                  : sibling.fireflySplitIndex == map.fireflySplitIndex;
          if (!sameRemoteSplit) continue;
          if (await database.tryGetTransactionFromPk(sibling.localPk) != null) {
            pairedLegStillLocal = true;
          }
        }
        // A Firefly group can hold several splits, and each split is one local
        // row. The delete must remove that split only, because a delete of the
        // group destroys each other split with it.
        //
        // The rows of this app do not say how many splits the group holds: a
        // split that the app never imported, or that it skipped, has no local
        // row. The live group must therefore be read before a delete, which is
        // what _removeSplitFromRemoteGroup does.
        bool groupWasDeleted = await _removeSplitFromRemoteGroup(
          client: client,
          deletedMap: map,
          groupMaps: groupMaps,
          assets: assets,
          report: report,
          backlog: backlog,
          deleteLoggedAt: log.dateTimeModified,
        );
        if (!groupWasDeleted) continue;
        remoteDeletedTransactionIds.add(map.fireflyId);
        if (pairedLegStillLocal) {
          // database.deleteTransaction does not follow pairedTransactionFk,
          // thus this app can hold one half of a transfer. Firefly cannot
          // store that.
          report.warnings
              .add("A transfer was removed from Firefly because one of its two "
                  "sides was deleted in Cashew. The other side is still stored "
                  "locally and is no longer synced.");
        }
      } else if (type == FireflySyncEntityType.category) {
        await client.deleteCategory(map.fireflyId);
        report.deletedRemote++;
        await _tombstoneMapRow(map);
      }
    } on FireflyNotFoundException {
      if (type == FireflySyncEntityType.transaction) {
        for (FireflySyncMapEntry sibling in await _syncMapsByFireflyId(
            FireflySyncEntityType.transaction, map.fireflyId,
            includeTombstones: true)) {
          await _tombstoneMapRow(sibling);
        }
      } else {
        await _tombstoneMapRow(map);
      }
    } catch (e) {
      report.warnings.add("Could not delete ${type.name} on Firefly: $e");
      backlog.recordNotPushed(log.dateTimeModified);
      print("Firefly push-delete error (will retry): " + e.toString());
    }
  }
}

// True if one side of the Firefly transaction is an account that the user
// removed in this app during this cycle.
Future<bool> _transactionIsOnUnlinkedAccount({
  required FireflyApiClient client,
  required int fireflyId,
  required Set<int> unlinkedAccountIds,
}) async {
  FireflyTransactionGroup remoteGroup;
  try {
    remoteGroup = await client.getTransaction(fireflyId);
  } on FireflyNotFoundException {
    return false;
  }
  return remoteGroup.splits.any((split) =>
      unlinkedAccountIds.contains(split.sourceId) ||
      unlinkedAccountIds.contains(split.destinationId));
}

// Removes one split from a Firefly group and keeps the other splits.
//
// DELETE on a transaction-journal removes that split alone. A PUT that
// rewrites the group would give each other split a new journal id and would
// delete each split that this app does not know.
//
// Firefly answers a journal id of another group, or an id that is not there,
// with a 401 error and not with a 404 error. The app therefore first reads the
// live group and looks for the id in it.
// Gives true when the full group went, and false when it stays.
Future<bool> _removeSplitFromRemoteGroup({
  required FireflyApiClient client,
  required FireflySyncMapEntry deletedMap,
  // Each row of this app that points at the group. The links of all of them
  // close when the full group goes.
  required List<FireflySyncMapEntry> groupMaps,
  required _FireflyAssetIndex assets,
  required FireflySyncReport report,
  required _FireflyPushBacklog backlog,
  required DateTime deleteLoggedAt,
}) async {
  FireflyTransactionGroup remoteGroup;
  try {
    remoteGroup = await client.getTransaction(deletedMap.fireflyId);
  } on FireflyNotFoundException {
    await _tombstoneGroupMaps(deletedMap, groupMaps);
    return false;
  }
  // A delete is a write. deleteWallet() removes the local rows before it
  // writes the delete log, thus the wallet of the row is gone here and the
  // account comes from the live group instead.
  FireflyAccount? inactive = _inactiveAssetAccountOfGroup(remoteGroup, assets);
  if (inactive != null) {
    report.skippedInactiveAccount++;
    backlog.recordNotPushed(deleteLoggedAt);
    if (assets.warnedInactive.add(inactive.id)) {
      report.warnings
          .add("Did not remove a transaction from the Firefly account "
              "\"${inactive.name}\": that account is inactive. Activate it on "
              "Firefly to let the delete through.");
    }
    return false;
  }
  if (remoteGroup.splits.length <= 1) {
    await client.deleteTransaction(deletedMap.fireflyId);
    await _tombstoneGroupMaps(deletedMap, groupMaps);
    report.deletedRemote++;
    return true;
  }
  int? journalId = deletedMap.fireflyJournalId;
  if (journalId == null ||
      !remoteGroup.splits
          .any((split) => split.transactionJournalId == journalId)) {
    report.warnings.add(
        "Did not remove a deleted record from a Firefly split transaction: "
        "the app cannot say which of its ${remoteGroup.splits.length} splits "
        "the record is.");
    backlog.recordNotPushed(deleteLoggedAt);
    return false;
  }
  await client.deleteTransactionJournal(journalId);
  await _tombstoneMapRow(deletedMap);
  report.deletedRemote++;
  return false;
}

// The first inactive asset account that one side of the group names. null
// when each account of the group is active, or not known here.
FireflyAccount? _inactiveAssetAccountOfGroup(
    FireflyTransactionGroup group, _FireflyAssetIndex assets) {
  for (FireflyTransactionSplit split in group.splits) {
    for (int? id in [split.sourceId, split.destinationId]) {
      FireflyAccount? account = id == null ? null : assets.byId[id];
      if (account != null && !account.active) return account;
    }
  }
  return null;
}

Future<void> _tombstoneGroupMaps(
    FireflySyncMapEntry deletedMap, List<FireflySyncMapEntry> groupMaps) async {
  await _tombstoneMapRow(deletedMap);
  for (FireflySyncMapEntry sibling in groupMaps) {
    if (sibling.syncMapPk == deletedMap.syncMapPk) continue;
    await _tombstoneMapRow(sibling);
  }
}

// The balance anchor of a wallet is one local row that holds the total of the
// data before the window:
//
//     anchor = firefly_current_balance - sum(the other local rows)
//
// Thus the local sum plus the anchor is the balance that Firefly reports. The
// anchor is in the reserved balance-correction category "0", thus the filter
// onlyShowIfNotBalanceCorrection() keeps it in the net totals and net worth,
// and out of the income and expense views. The anchor corrects itself: when
// an on-demand fetch adds older rows, the local sum increases and the anchor
// decreases by the same amount.

// A difference that is less than this is no change. To write the anchor again
// starts the auto-sync watcher, thus small floating-point noise must not do
// it.
const double _kAnchorEpsilon = 0.005;

Future<void> _refreshBalanceAnchors(
    FireflyApiClient client, FireflySyncReport report) async {
  List<FireflyAccount> accounts =
      await client.getAccounts(type: kFireflyAssetAccountType);
  Map<int, FireflyAccount> byId = {for (var a in accounts) a.id: a};

  for (FireflySyncMapEntry map
      in await _syncMapEntriesForType(FireflySyncEntityType.wallet)) {
    FireflyAccount? remote = byId[map.fireflyId];
    if (remote == null) {
      // The link names a Firefly account that the server no longer gives.
      // The anchor of that account then keeps the balance of the day the
      // account went, and the total of the local account drifts from it with
      // every row that is added. Say so: nothing else in a cycle does.
      TransactionWallet? wallet =
          await database.getWalletInstanceOrNull(map.localPk);
      report.warnings.add(
          "The account \"${wallet?.name ?? map.localPk}\" is linked to a "
          "Firefly account that the server no longer gives. Its total is held "
          "at the balance of the last sync that found it. Link the account to "
          "another Firefly account in the Firefly settings.");
      continue;
    }
    await _refreshBalanceAnchorForWallet(
      walletPk: map.localPk,
      remoteBalance: remote.currentBalance,
      report: report,
    );
  }
}

Future<void> _refreshBalanceAnchorForWallet({
  required String walletPk,
  required double? remoteBalance,
  required FireflySyncReport report,
}) async {
  String anchorPk = fireflyBalanceAnchorPk(walletPk);
  Transaction? existing = await database.tryGetTransactionFromPk(anchorPk);

  if (remoteBalance == null) {
    // Without a balance from the server the code cannot calculate an anchor.
    // Keep the anchor that is there: an old anchor is nearer to the truth
    // than a guess.
    if (existing == null) {
      report.warnings.add(
          "Firefly did not report a balance for one account; its total may be "
          "short by the history that is not stored locally.");
    }
    return;
  }

  // Firefly reports the balance of today and does not count a transaction
  // with a date in the future. The local sum must use the same rule, or each
  // such transaction makes the anchor wrong by its amount. Firefly counts each
  // transaction that is dated today, also one with a time later than now,
  // thus the limit is the end of today and not the present moment.
  DateTime now = DateTime.now();
  DateTime endOfToday = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);
  double localSum = await database.getSumOfWalletExcludingTransaction(
      walletPk, anchorPk,
      notLaterThan: endOfToday);
  double anchorAmount = remoteBalance - localSum;

  // Nothing to hold, and no row on disk. Do not make a row.
  if (existing == null && anchorAmount.abs() < _kAnchorEpsilon) return;
  // No change. The write is not permitted here: it sets a new
  // dateTimeModified, which starts the auto-sync watcher and one more sync in
  // each cycle.
  if (existing != null &&
      (existing.amount - anchorAmount).abs() < _kAnchorEpsilon) {
    return;
  }

  DateTime? earliest =
      await database.getEarliestTransactionDateOfWallet(walletPk, anchorPk);
  DateTime anchorDate =
      (earliest ?? fireflySyncWindowStart()).subtract(const Duration(days: 1));

  await database.createOrUpdateTransaction(
    buildFireflyBalanceAnchor(
      walletPk: walletPk,
      amount: anchorAmount,
      date: anchorDate,
      name: "firefly-balance-anchor".tr(),
    ),
    insert: false,
    updateSharedEntry: false,
    fireflySync: true,
  );
}

// The functions below read data from before the sync window, after an action
// of the user: a search, a filter on a date, an open account, or a pull to
// refresh a balance. They write each record into the local database, where it
// is a usual local row.
//
// None of them compares deletes and none of them moves fireflyLastSyncedAt.
// They read a part of the remote data on purpose, and _applyRemoteDeletes
// accepts a complete set only.

final ValueNotifier<bool> fireflyOnDemandBusyNotifier = ValueNotifier(false);

Future<T?> _withFireflyClient<T>(
    Future<T> Function(FireflyApiClient client) body) async {
  if (!fireflyEnabled) return null;
  String hostUrl = fireflyHostUrl;
  String? pat = await getFireflyPat();
  if (hostUrl.isEmpty || pat == null || pat.isEmpty) return null;

  FireflyApiClient client =
      FireflyApiClient(baseUrl: hostUrl, personalAccessToken: pat);
  fireflyOnDemandBusyNotifier.value = true;
  try {
    // In the same queue as the routine sync. These fetches use the same
    // _pullTransactions code on data that can be the same. If one runs during
    // a sync, both can read the same Firefly group, both find no link, and
    // each insert its own local copy.
    return await _withFireflyEngineLock(
        () => _withFireflyWrites(() => body(client)));
  } catch (e) {
    print("Firefly on-demand fetch error: " + e.toString());
    fireflySyncErrorNotifier.value = e.toString();
    return null;
  } finally {
    fireflyOnDemandBusyNotifier.value = false;
    client.close();
    // An edit during this fetch is not in a queue anywhere else. Without this
    // the flag stays set until the next cycle, which then only clears it.
    _reschedulePushIfEditedDuringWork();
  }
}

// Reads and keeps a range of booking dates from before the window, for
// example when the user scrolls or filters back past it.
Future<FireflySyncReport?> fireflyFetchTransactionRange({
  required DateTime start,
  DateTime? end,
}) async {
  return await _withFireflyClient((client) async {
    FireflySyncReport report = FireflySyncReport();
    await _ensureFireflySystemCategories();
    List<FireflyTransactionGroup> groups =
        await client.getTransactions(start: start, end: end);
    await _pullTransactions(client, report, preFetchedGroups: groups);
    await _refreshBalanceAnchors(client, report);
    fireflySyncReportNotifier.value = report;
    return report;
  });
}

// Reads each record that Firefly holds for one wallet, with an optional range
// of dates. This gives the full history of an account.
Future<FireflySyncReport?> fireflyFetchTransactionsForWallet(
  String walletPk, {
  DateTime? start,
  DateTime? end,
}) async {
  return await _withFireflyClient((client) async {
    FireflySyncReport report = FireflySyncReport();
    FireflySyncMapEntry? map =
        await _syncMapByLocalPk(FireflySyncEntityType.wallet, walletPk);
    if (map == null) {
      report.warnings.add("That account is not linked to Firefly yet.");
      return report;
    }
    await _ensureFireflySystemCategories();
    List<FireflyTransactionGroup> groups = await client
        .getTransactionsForAccount(map.fireflyId, start: start, end: end);
    await _pullTransactions(client, report, preFetchedGroups: groups);
    await _refreshBalanceAnchorForWallet(
      walletPk: walletPk,
      remoteBalance: (await client.getAccount(map.fireflyId)).currentBalance,
      report: report,
    );
    fireflySyncReportNotifier.value = report;
    return report;
  });
}

// Sends a full-text search to Firefly and keeps each record that comes back,
// thus a result from before the window becomes a local row.
Future<FireflySyncReport?> fireflySearchAndCacheTransactions(
    String query) async {
  if (query.trim().isEmpty) return null;
  return await _withFireflyClient((client) async {
    FireflySyncReport report = FireflySyncReport();
    await _ensureFireflySystemCategories();
    List<FireflyTransactionGroup> groups =
        await client.searchTransactions(query.trim());
    await _pullTransactions(client, report, preFetchedGroups: groups);
    await _refreshBalanceAnchors(client, report);
    fireflySyncReportNotifier.value = report;
    return report;
  });
}

// Reads the balances from Firefly again and writes the anchor of each linked
// wallet. This costs one account list and no transactions, thus a pull to
// refresh on a balance view or a net worth view can use it.
Future<bool> fireflyRefreshBalances() async {
  FireflySyncReport? report = await _withFireflyClient((client) async {
    FireflySyncReport report = FireflySyncReport();
    await _ensureFireflySystemCategories();
    await _refreshBalanceAnchors(client, report);
    return report;
  });
  return report != null;
}

// Makes the window larger and syncs again, for "my older transactions are not
// here". This is expensive on a full server, thus only the user starts it.
Future<bool> fireflySyncAllHistory() async {
  return await fireflySyncNow(fullResync: true);
}

// The functions below are the ones that the views of the application call.
// Each one does nothing if Firefly is off, uses the network only if the view
// asks for data that the local window does not hold, and keeps a record of
// what it read, thus a filter that the user sets two times reads the data one
// time. The caller does not wait for a result: the data goes into the local
// database, and the Drift streams put it into the open view.

String _fireflyDayKey(DateTime date) => date.toIso8601String().substring(0, 10);

final Set<String> _fireflyFetchedRangeKeys = {};
final Set<String> _fireflyFetchedSearchQueries = {};
final Set<String> _fireflyFetchedWalletPks = {};

// Clears the record of what the fetches read. A different server, or a larger
// window, makes each entry of that record wrong.
void fireflyClearOnDemandCacheMemory() {
  _fireflyFetchedRangeKeys.clear();
  _fireflyFetchedSearchQueries.clear();
  _fireflyFetchedWalletPks.clear();
}

// The user set a filter or scrolled to a range of dates. Only a range that
// starts before the window needs data from the server.
Future<void> fireflyEnsureRangeCached(DateTime? start, DateTime? end) async {
  if (!fireflyEnabled) return;
  if (start == null) return;
  if (!start.isBefore(fireflySyncWindowStart())) return;
  String key =
      _fireflyDayKey(start) + ".." + (end == null ? "" : _fireflyDayKey(end));
  if (!_fireflyFetchedRangeKeys.add(key)) return;
  FireflySyncReport? report =
      await fireflyFetchTransactionRange(start: start, end: end);
  // A fetch that fails must not go into the record, or the range stays empty
  // until the application starts again.
  if (report == null) _fireflyFetchedRangeKeys.remove(key);
}

// The user typed a search. Firefly searches its full history, thus this is
// the only way to see a result from before the window.
Future<void> fireflyEnsureSearchCached(String? query) async {
  if (!fireflyEnabled) return;
  String trimmed = (query ?? "").trim();
  // A query of less than three characters matches too much data, and the
  // local rows give an answer.
  if (trimmed.length < 3) return;
  String key = trimmed.toLowerCase();
  if (!_fireflyFetchedSearchQueries.add(key)) return;
  FireflySyncReport? report = await fireflySearchAndCacheTransactions(trimmed);
  if (report == null) _fireflyFetchedSearchQueries.remove(key);
}

// The user opened one account. This reads the full history of that account
// one time in each run of the application, thus its list of transactions and
// its balance are complete.
Future<void> fireflyEnsureWalletHistoryCached(String walletPk) async {
  if (!fireflyEnabled) return;
  if (!_fireflyFetchedWalletPks.add(walletPk)) return;
  FireflySyncReport? report = await fireflyFetchTransactionsForWallet(walletPk);
  if (report == null) _fireflyFetchedWalletPks.remove(walletPk);
}

// Sends the local transactions that are older than the link to Firefly. Only
// the user starts this: on a server that holds data it makes a remote copy of
// each local row, and there is no safe test for the rows that Firefly has.
Future<bool> fireflyUploadExistingLocalHistory() async {
  return await fireflySyncNow(pushExistingLocalHistory: true);
}

// Pushes each local change since the link that Firefly does not hold yet.
// See pushUnsynced in fireflySyncNow.
Future<bool> fireflyPushUnsyncedChanges() async {
  return await fireflySyncNow(pushUnsynced: true);
}

// The tombstone that a manual relink leaves for the previous Firefly account
// of a wallet gets a key with this prefix. The sync map allows one row per
// wallet, thus the tombstone cannot keep the key of the wallet. A tombstone
// with a key that no wallet has is the usual state after a wallet delete,
// and each reader of the map treats it the same way.
const String kFireflyUnlinkedPkPrefix = "firefly-unlinked-";

// One local wallet and its Firefly account, for the "Linked accounts" list
// of the settings page.
class FireflyWalletLink {
  final TransactionWallet wallet;
  // The id of the linked Firefly account, or null if the wallet has no link.
  final int? fireflyId;
  // The account, when the caller gave the list of the server and the id is
  // in it. null with a fireflyId means that the account is not an asset
  // account of the server any more.
  final FireflyAccount? account;

  const FireflyWalletLink({
    required this.wallet,
    this.fireflyId,
    this.account,
  });
}

// The asset accounts of the server, active and inactive, for the picker of
// the settings page. null if the sync is off or the request failed.
Future<List<FireflyAccount>?> fireflyListAssetAccounts() async {
  return await _withFireflyClient(
      (client) => client.getAccounts(type: kFireflyAssetAccountType));
}

// Each local wallet with its live link. `accounts` is the list that
// fireflyListAssetAccounts gave; without it each link has no account.
Future<List<FireflyWalletLink>> fireflyWalletLinks(
    {List<FireflyAccount>? accounts}) async {
  Map<int, FireflyAccount> byId = {
    for (FireflyAccount account in accounts ?? []) account.id: account
  };
  List<FireflyWalletLink> links = [];
  for (TransactionWallet wallet in await database.getAllWallets()) {
    FireflySyncMapEntry? map =
        await _syncMapByLocalPk(FireflySyncEntityType.wallet, wallet.walletPk);
    links.add(FireflyWalletLink(
      wallet: wallet,
      fireflyId: map?.fireflyId,
      account: map == null ? null : byId[map.fireflyId],
    ));
  }
  return links;
}

// Links a wallet to a Firefly asset account, by the choice of the user.
// `account` null removes the link.
//
// The previous account of the wallet is unlinked, not deleted, and gets a
// tombstone: the pull does not add it as a new wallet. The same as a wallet
// delete in this app. Each tombstone of the chosen account goes away, thus
// the pull attaches the transactions of that account to this wallet again,
// and the delete pass no longer treats them as rows of a removed account.
// The transactions that this app holds keep their links; the next pull
// re-reads each one that the server changed, and the balance anchor of the
// wallet takes the balance of the chosen account.
//
// Nothing is written to Firefly. The link takes the wallet as unchanged,
// thus the next cycle does not rename the account on Firefly to the name of
// the wallet, and it does not rename the wallet, until one side changes.
Future<void> fireflyLinkWalletToAccount(
    String walletPk, FireflyAccount? account) async {
  await _withFireflyEngineLock(() => database.transaction(() async {
        TransactionWallet? wallet =
            await database.getWalletInstanceOrNull(walletPk);
        if (wallet == null) return;
        FireflySyncMapEntry? current = await _syncMapByLocalPk(
            FireflySyncEntityType.wallet, walletPk,
            includeTombstones: true);
        if (current != null &&
            !current.isTombstone &&
            account != null &&
            current.fireflyId == account.id) {
          return;
        }
        if (current != null) {
          await _deleteSyncMapRow(current);
          if (!current.isTombstone) {
            await _upsertSyncMap(
              type: FireflySyncEntityType.wallet,
              localPk: kFireflyUnlinkedPkPrefix + uuid.v4(),
              fireflyId: current.fireflyId,
              fireflyUpdatedAt: current.fireflyUpdatedAt,
              lastSyncedLocalModified: current.lastSyncedLocalModified,
              isTombstone: true,
            );
          }
        }
        if (account == null) return;
        for (FireflySyncMapEntry map in await _syncMapsByFireflyId(
            FireflySyncEntityType.wallet, account.id,
            includeTombstones: true)) {
          // A live row of another wallet: that wallet loses the link. Two
          // wallets on one account would push each row twice.
          await _deleteSyncMapRow(map);
        }
        await _upsertSyncMap(
          type: FireflySyncEntityType.wallet,
          localPk: walletPk,
          fireflyId: account.id,
          fireflyUpdatedAt: account.updatedAt,
          lastSyncedLocalModified: wallet.dateTimeModified,
        );
      }));
}

// What "Push unsynced changes" would send. The settings page shows it next
// to the button. The count uses the local database only and applies the
// cheap rules of the push loops; a rule that needs the server (a conflict, a
// split that the app does not know) is not in it, thus the report after the
// push holds the exact numbers.
class FireflyUnsyncedCounts {
  final int wallets;
  final int categories;
  final int transactions;
  final int deletes;

  const FireflyUnsyncedCounts({
    this.wallets = 0,
    this.categories = 0,
    this.transactions = 0,
    this.deletes = 0,
  });

  static const FireflyUnsyncedCounts zero = FireflyUnsyncedCounts();

  int get total => wallets + categories + transactions + deletes;
  bool get isEmpty => total == 0;

  String describe() {
    List<String> parts = [];
    if (transactions > 0) parts.add("$transactions transactions");
    if (wallets > 0) parts.add("$wallets accounts");
    if (categories > 0) parts.add("$categories categories");
    if (deletes > 0) parts.add("$deletes deletions");
    return parts.join(", ");
  }
}

Future<FireflyUnsyncedCounts> fireflyCountUnsyncedChanges() async {
  if (!fireflyEnabled) return FireflyUnsyncedCounts.zero;
  DateTime since = fireflyUnsyncedSince();

  Future<bool> isUnsynced(FireflySyncEntityType type, String localPk,
      DateTime? localModified) async {
    FireflySyncMapEntry? map =
        await _syncMapByLocalPk(type, localPk, includeTombstones: true);
    if (map != null && map.isTombstone) return false;
    return map == null ||
        fireflyLocalRowChanged(
          localModified: localModified,
          lastSyncedLocalModified: map.lastSyncedLocalModified,
        );
  }

  int wallets = 0;
  for (TransactionWallet wallet in await database.getAllNewWallets(since)) {
    if (wallet.dateTimeModified == null) continue;
    if (await isUnsynced(FireflySyncEntityType.wallet, wallet.walletPk,
        wallet.dateTimeModified)) {
      wallets++;
    }
  }

  int categories = 0;
  for (TransactionCategory category
      in await database.getAllNewCategories(since)) {
    if (category.dateTimeModified == null) continue;
    if (category.categoryPk == kFireflyUncategorizedCategoryPk) continue;
    if (category.categoryPk == kBalanceCorrectionCategoryPk) continue;
    if (category.mainCategoryPk != null) continue;
    if (await isUnsynced(FireflySyncEntityType.category, category.categoryPk,
        category.dateTimeModified)) {
      categories++;
    }
  }

  int transactions = 0;
  for (Transaction transaction in await database.getAllNewTransactions(since)) {
    if (transaction.dateTimeModified == null) continue;
    if (isFireflyBalanceAnchorPk(transaction.transactionPk)) continue;
    FireflySyncMapEntry? map = await _syncMapByLocalPk(
        FireflySyncEntityType.transaction, transaction.transactionPk,
        includeTombstones: true);
    if (map != null && map.isTombstone) continue;
    // A row that is not paid has no Firefly form. It counts only when
    // Firefly still holds it: the push then removes the remote record.
    if (transaction.paid == false) {
      if (map != null) transactions++;
      continue;
    }
    if (map == null ||
        fireflyLocalRowChanged(
          localModified: transaction.dateTimeModified,
          lastSyncedLocalModified: map.lastSyncedLocalModified,
        )) {
      transactions++;
    }
  }

  int deletes = 0;
  for (DeleteLog log in await database.getAllNewDeleteLogs(since)) {
    if (log.entryPk == "0") continue;
    FireflySyncEntityType type;
    if (log.type == DeleteLogType.Transaction) {
      type = FireflySyncEntityType.transaction;
    } else if (log.type == DeleteLogType.TransactionCategory) {
      type = FireflySyncEntityType.category;
    } else if (log.type == DeleteLogType.TransactionWallet) {
      type = FireflySyncEntityType.wallet;
    } else {
      continue;
    }
    if (await _syncMapByLocalPk(type, log.entryPk) != null) deletes++;
  }

  return FireflyUnsyncedCounts(
    wallets: wallets,
    categories: categories,
    transactions: transactions,
    deletes: deletes,
  );
}
