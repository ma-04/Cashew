import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/firefly/fireflyModels.dart';
import 'package:budget/struct/firefly/fireflySettings.dart';
import 'package:budget/struct/firefly/fireflySyncEngine.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:timer_builder/timer_builder.dart';

// The settings of the Firefly III integration: the enable switch, the host
// URL, the token field (write only: the page does not show a saved token
// again), the connection test and the manual sync.
//
// To enable this while the Google Drive sync (appStateSettings["backupSync"])
// is on opens a dialog and stops the Google Drive sync first. The two are
// mutually exclusive on one installation. The backupSync switch in
// lib/widgets/accountAndBackup.dart has the same test.
class FireflySettingsPage extends StatefulWidget {
  const FireflySettingsPage({super.key});

  @override
  State<FireflySettingsPage> createState() => _FireflySettingsPageState();
}

class _FireflySettingsPageState extends State<FireflySettingsPage> {
  late bool enabled = fireflyEnabled;
  late TextEditingController hostController =
      TextEditingController(text: fireflyHostUrl);
  TextEditingController patController = TextEditingController();
  bool testingConnection = false;
  bool syncingNow = false;
  bool runningHistoryAction = false;
  late String counterpartyNaming = fireflyCounterpartyNaming;
  // The local changes that Firefly does not have yet. null until the first
  // read.
  FireflyQueuedChanges? queuedChanges;
  // Each local account and the Firefly account that it mirrors. The server
  // gives the link; the page only shows it.
  List<FireflyLinkedWallet> linkedWallets = [];

  @override
  void initState() {
    super.initState();
    fireflySyncReportNotifier.addListener(_onSyncReport);
    _refreshQueuedChanges();
    _refreshLinkedWallets();
  }

  @override
  void dispose() {
    fireflySyncReportNotifier.removeListener(_onSyncReport);
    hostController.dispose();
    patController.dispose();
    super.dispose();
  }

  Future<void> _refreshQueuedChanges() async {
    if (!fireflyEnabled) {
      if (mounted) setState(() => queuedChanges = null);
      return;
    }
    FireflyQueuedChanges changes = await fireflyQueuedChanges();
    if (mounted) setState(() => queuedChanges = changes);
  }

  // A sync can change both the queue and the links, thus this runs again
  // after each report.
  void _onSyncReport() {
    _refreshQueuedChanges();
    _refreshLinkedWallets();
  }

  Future<void> _refreshLinkedWallets() async {
    if (!fireflyEnabled) {
      if (mounted) setState(() => linkedWallets = []);
      return;
    }
    List<FireflyLinkedWallet> wallets = await fireflyLinkedWallets();
    if (mounted) setState(() => linkedWallets = wallets);
  }

  String _linkedWalletDescription(FireflyLinkedWallet wallet) {
    return "\u2192 " +
        wallet.accountName +
        (wallet.active ? "" : " (" + "firefly-inactive".tr() + ")");
  }

  String _entityKindLabel(FireflySyncEntityType type) {
    switch (type) {
      case FireflySyncEntityType.wallet:
        return "firefly-entity-account".tr();
      case FireflySyncEntityType.transaction:
        return "firefly-entity-transaction".tr();
      case FireflySyncEntityType.category:
        return "firefly-entity-category".tr();
    }
  }

  // The first line of the error of the server, cut to a length that fits a
  // row of the list.
  String _shortError(String? error) {
    String text = (error ?? "").trim();
    if (text.isEmpty) return "firefly-change-refused".tr();
    text = text.split("\n").first.trim();
    const int maxLength = 120;
    if (text.length > maxLength) {
      text = text.substring(0, maxLength).trimRight() + "\u2026";
    }
    return text;
  }

  // Asks a yes or no question. True if the user chose to continue.
  Future<bool> _confirm({
    required String title,
    required String description,
    required IconData icon,
  }) async {
    bool confirmed = false;
    await openPopup(
      context,
      title: title,
      description: description,
      icon: icon,
      onSubmitLabel: "continue".tr(),
      onSubmit: () {
        confirmed = true;
        popRoute(context);
      },
      onCancelLabel: "cancel".tr(),
      onCancel: () {
        popRoute(context);
      },
    );
    return confirmed;
  }

  // The first sync with a server replaces the local accounts, transactions
  // and categories with the ones of Firefly. Say so before it runs.
  Future<bool> _confirmRebuildOnEnable() {
    return _confirm(
      title: "firefly-enable-confirm-title".tr(),
      description: "firefly-enable-confirm".tr(),
      icon: appStateSettings["outlinedIcons"]
          ? Icons.warning_amber_outlined
          : Icons.warning_amber_rounded,
    );
  }

  Future<bool> enableFirefly() async {
    if (!await _hasCredentials()) {
      openSnackbar(
        SnackbarMessage(
          title: "firefly-host-and-token-required".tr(),
          icon: appStateSettings["outlinedIcons"]
              ? Icons.error_outlined
              : Icons.error_rounded,
        ),
      );
      return false;
    }
    bool turnOffGoogleDrive = appStateSettings["backupSync"] == true;
    if (turnOffGoogleDrive) {
      bool confirmed = await _confirm(
        title: "cloud-sync".tr(),
        description: "firefly-disable-google-drive-sync-warning".tr(),
        icon: appStateSettings["outlinedIcons"]
            ? Icons.warning_amber_outlined
            : Icons.warning_amber_rounded,
      );
      if (!confirmed) return false;
    }
    return await _doEnableFirefly(turnOffGoogleDrive: turnOffGoogleDrive);
  }

  // True if the host in the field is not the host that the saved links and
  // the saved token belong to.
  bool _hostChanged(String host) {
    String previous = fireflyHostUrl.trim();
    return previous.isNotEmpty && previous != host;
  }

  // Removes the token and the links of the previous host. The token is a
  // secret of that server, thus the application must not send it to a
  // different one, and each saved Firefly id is correct for that server only.
  // The user is about to change the host. That removes the token and every
  // link, which cannot be undone from here. Ask first: before this, a typo in
  // the host field and a tap on Save were enough to lose them.
  Future<bool> _confirmForgetPreviousHost() {
    return _confirm(
      title: "firefly-host-changed".tr(),
      description: "firefly-host-change-confirm".tr(),
      icon: appStateSettings["outlinedIcons"]
          ? Icons.warning_amber_outlined
          : Icons.warning_amber_rounded,
    );
  }

  Future<void> _forgetPreviousHost() async {
    await clearFireflyPat();
    await fireflyForgetSyncState();
    // The link moment belongs to the previous host. The first sync with the
    // new host sets a new one.
    await clearFireflyLinkedAt();
  }

  // A token that the user saved for a different host does not count: the
  // application must get a token for the new host first.
  Future<bool> _hasCredentials() async {
    String host = hostController.text.trim();
    if (host.isEmpty) return false;
    if (patController.text.trim().isNotEmpty) return true;
    if (_hostChanged(host)) return false;
    String? stored = await getFireflyPat();
    return stored != null && stored.isNotEmpty;
  }

  // Each question comes before any change: a cancel at any of them leaves
  // the Google Drive sync, the token and the local data as they were.
  Future<bool> _doEnableFirefly({bool turnOffGoogleDrive = false}) async {
    if (!await _hasCredentials()) {
      openSnackbar(
        SnackbarMessage(
          title: "firefly-host-and-token-required".tr(),
          icon: appStateSettings["outlinedIcons"]
              ? Icons.error_outlined
              : Icons.error_rounded,
        ),
      );
      return false;
    }
    String host = hostController.text.trim();
    String token = patController.text.trim();
    bool hostChanged = _hostChanged(host);
    if (hostChanged && !await _confirmForgetPreviousHost()) return false;
    // The first sync with a server, and the first after a host change, is a
    // rebuild of the local copy from Firefly.
    bool willRebuild = hostChanged || await fireflyNeedsRebuild();
    if (willRebuild && !await _confirmRebuildOnEnable()) return false;
    if (turnOffGoogleDrive) {
      await updateSettings("backupSync", false,
          pagesNeedingRefresh: [], updateGlobalState: false);
    }
    if (hostChanged) await _forgetPreviousHost();
    await setFireflyHostUrl(host);
    if (token.isNotEmpty) {
      await setFireflyPat(token);
      patController.clear();
    }
    await setFireflyEnabled(true);
    // The page can be gone: each await above gives the user time to leave it,
    // and this one is a full-height sheet that a drag closes.
    if (!mounted) return true;
    setState(() {
      enabled = true;
    });
    _syncAfterEnable();
    return true;
  }

  Future<void> _syncAfterEnable() async {
    // The user confirmed the rebuild in _enable when one is due.
    await fireflySyncNow(allowRebuild: true);
    await _refreshQueuedChanges();
    await _refreshLinkedWallets();
  }

  Future<bool> disableFirefly() async {
    await setFireflyEnabled(false);
    if (!mounted) return true;
    setState(() {
      enabled = false;
    });
    return true;
  }

  Future<void> saveHostAndToken() async {
    String host = hostController.text.trim();
    String token = patController.text.trim();
    bool hostChanged = _hostChanged(host);
    if (hostChanged) {
      if (!await _confirmForgetPreviousHost()) return;
      await _forgetPreviousHost();
      // The first sync with the new host replaces the local data, and the
      // switch asks before it does that. Stop the automatic cycles until the
      // user turns the sync on again.
      await setFireflyEnabled(false);
    }
    await setFireflyHostUrl(host);
    if (token.isNotEmpty) {
      await setFireflyPat(token);
      patController.clear();
    }
    if (!mounted) return;
    setState(() {
      enabled = fireflyEnabled;
    });
    openSnackbar(SnackbarMessage(
      title: hostChanged ? "firefly-host-changed".tr() : "saved".tr(),
      description: hostChanged ? "firefly-host-changed-description".tr() : null,
      icon: hostChanged
          ? (appStateSettings["outlinedIcons"]
              ? Icons.warning_amber_outlined
              : Icons.warning_amber_rounded)
          : null,
    ));
  }

  Future<void> testConnection() async {
    String host = hostController.text.trim();
    String pat = patController.text.trim().isNotEmpty
        ? patController.text.trim()
        : (await getFireflyPat()) ?? "";
    if (host.isEmpty || pat.isEmpty) {
      openSnackbar(
        SnackbarMessage(
          title: "firefly-host-and-token-required".tr(),
          icon: appStateSettings["outlinedIcons"]
              ? Icons.error_outlined
              : Icons.error_rounded,
        ),
      );
      return;
    }
    setState(() {
      testingConnection = true;
    });
    try {
      FireflyAbout about = await testFireflyConnection(host, pat);
      openSnackbar(
        SnackbarMessage(
          title: "firefly-connection-successful".tr(),
          description: "Firefly III v" + about.version,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.check_circle_outlined
              : Icons.check_circle_rounded,
        ),
      );
    } catch (e) {
      openSnackbar(
        SnackbarMessage(
          title: "firefly-connection-failed".tr(),
          description: e.toString(),
          icon: appStateSettings["outlinedIcons"]
              ? Icons.error_outlined
              : Icons.error_rounded,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          testingConnection = false;
        });
      }
    }
  }

  Future<void> syncNow() async {
    // A cycle that the engine started on its own holds the same lock. Such a
    // call does nothing and returns false, which is not a failure.
    bool alreadyRunning = fireflySyncIsRunning;
    // A phone that comes from the two-way sync of an earlier build waits for
    // a rebuild, which the user confirms here.
    bool rebuild = await fireflyNeedsRebuild();
    if (rebuild && !await _confirmRebuildOnEnable()) return;
    if (!mounted) return;
    setState(() {
      syncingNow = true;
    });
    bool success;
    try {
      success = await fireflySyncNow(allowRebuild: rebuild);
    } finally {
      // Without this a throw leaves the flag set and each button of the page
      // stays disabled until the page is opened again.
      if (mounted) {
        setState(() {
          syncingNow = false;
        });
      }
    }
    await _refreshQueuedChanges();
    await _refreshLinkedWallets();
    if (!success && alreadyRunning) {
      openSnackbar(SnackbarMessage(
        title: "firefly-sync-busy".tr(),
        icon: appStateSettings["outlinedIcons"]
            ? Icons.hourglass_empty_outlined
            : Icons.hourglass_empty_rounded,
      ));
      return;
    }
    String? description = success
        ? fireflySyncReportNotifier.value?.summary()
        : fireflySyncErrorNotifier.value;
    if (success &&
        (fireflySyncReportNotifier.value?.warnings.isNotEmpty ?? false)) {
      description = (description ?? "") +
          "\n" +
          fireflySyncReportNotifier.value!.warnings.join("\n");
    }
    openSnackbar(
      SnackbarMessage(
        title: success
            ? "firefly-sync-successful".tr()
            : "firefly-sync-failed".tr(),
        description: description,
        icon: appStateSettings["outlinedIcons"]
            ? (success ? Icons.check_circle_outlined : Icons.error_outlined)
            : (success ? Icons.check_circle_rounded : Icons.error_rounded),
      ),
    );
  }

  Future<void> _runHistoryAction(Future<bool> Function() action) async {
    bool alreadyRunning = fireflySyncIsRunning;
    setState(() {
      runningHistoryAction = true;
    });
    bool success;
    try {
      success = await action();
    } finally {
      if (mounted) {
        setState(() {
          runningHistoryAction = false;
        });
      }
    }
    await _refreshQueuedChanges();
    await _refreshLinkedWallets();
    if (!success && alreadyRunning) {
      openSnackbar(SnackbarMessage(
        title: "firefly-sync-busy".tr(),
        icon: appStateSettings["outlinedIcons"]
            ? Icons.hourglass_empty_outlined
            : Icons.hourglass_empty_rounded,
      ));
      return;
    }
    openSnackbar(
      SnackbarMessage(
        title: success
            ? "firefly-sync-successful".tr()
            : "firefly-sync-failed".tr(),
        description: success
            ? fireflySyncReportNotifier.value?.summary()
            : fireflySyncErrorNotifier.value,
        icon: appStateSettings["outlinedIcons"]
            ? (success ? Icons.check_circle_outlined : Icons.error_outlined)
            : (success ? Icons.check_circle_rounded : Icons.error_rounded),
      ),
    );
  }

  Future<void> syncAllHistory() async {
    bool confirmed = await _confirm(
      title: "firefly-sync-all-history".tr(),
      description: "firefly-sync-all-history-warning".tr(),
      icon: appStateSettings["outlinedIcons"]
          ? Icons.history_outlined
          : Icons.history_rounded,
    );
    if (!confirmed) return;
    await _runHistoryAction(fireflySyncAllHistory);
  }

  // Sends the changes that Firefly refused again, after the user fixed the
  // cause on the server.
  Future<void> retryFailedChanges() async {
    await _runHistoryAction(fireflyRetryFailedChanges);
  }

  // Drops the changes that Firefly refused. The local records already show
  // the Firefly version, thus nothing else changes.
  Future<void> dismissFailedChanges() async {
    bool confirmed = await _confirm(
      title: "firefly-dismiss-changes".tr(),
      description: "firefly-dismiss-changes-confirm".tr(),
      icon: appStateSettings["outlinedIcons"]
          ? Icons.delete_outlined
          : Icons.delete_rounded,
    );
    if (!confirmed) return;
    await fireflyDismissFailedChanges();
    await _refreshQueuedChanges();
    openSnackbar(SnackbarMessage(
      title: "firefly-dismiss-changes-done".tr(),
      icon: appStateSettings["outlinedIcons"]
          ? Icons.check_circle_outlined
          : Icons.check_circle_rounded,
    ));
  }

  // A backup of the local database, then the local copy built again from
  // Firefly. Each linked record keeps the fields that only Cashew has.
  Future<void> rebuildFromFirefly() async {
    bool confirmed = await _confirm(
      title: "firefly-rebuild".tr(),
      description: "firefly-rebuild-warning".tr(),
      icon: appStateSettings["outlinedIcons"]
          ? Icons.restore_outlined
          : Icons.restore_rounded,
    );
    if (!confirmed) return;
    await _runHistoryAction(fireflyRebuildFromFirefly);
  }

  @override
  Widget build(BuildContext context) {
    return PageFramework(
      dragDownToDismiss: true,
      title: "firefly-iii-sync".tr(),
      slivers: [
        SliverToBoxAdapter(
          child: SettingsContainerSwitch(
            enableBorderRadius: true,
            title: "enable-firefly-sync".tr(),
            description: "enable-firefly-sync-description".tr(),
            icon: appStateSettings["outlinedIcons"]
                ? Icons.sync_outlined
                : Icons.sync_rounded,
            initialValue: enabled,
            onSwitched: (value) async {
              return value ? await enableFirefly() : await disableFirefly();
            },
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 17, vertical: 8),
            child: TextInput(
              labelText: "firefly-host-url".tr(),
              controller: hostController,
              autoFocus: false,
              keyboardType: TextInputType.url,
              onSubmitted: (_) => saveHostAndToken(),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 17, vertical: 8),
            child: TextInput(
              labelText: "firefly-personal-access-token".tr(),
              controller: patController,
              obscureText: true,
              autoFocus: false,
              onSubmitted: (_) => saveHostAndToken(),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 17, vertical: 5),
            child: TextFont(
              text: "firefly-token-note".tr(),
              fontSize: 13,
              maxLines: 4,
              textColor: getColor(context, "textLight"),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 17, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Button(
                    label: "save".tr(),
                    onTap: saveHostAndToken,
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Button(
                    label: testingConnection
                        ? "testing".tr()
                        : "test-connection".tr(),
                    disabled: testingConnection,
                    onTap: testConnection,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (enabled)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: 17, vertical: 8),
              child: Column(
                children: [
                  ValueListenableBuilder<FireflySyncStatus>(
                    valueListenable: fireflySyncStatusNotifier,
                    builder: (context, status, child) {
                      return TimerBuilder.periodic(
                        Duration(seconds: 5),
                        builder: (context) {
                          return TextFont(
                            textAlign: TextAlign.center,
                            fontSize: 13,
                            maxLines: 3,
                            textColor: getColor(context, "textLight"),
                            text: _statusLabel(status) +
                                " - " +
                                "synced".tr().capitalizeFirst +
                                " " +
                                (fireflyLastSyncedAt == null
                                    ? "never".tr()
                                    : getTimeAgo(fireflyLastSyncedAt!)),
                          );
                        },
                      );
                    },
                  ),
                  SizedBox(height: 8),
                  Button(
                    label: syncingNow ? "syncing".tr() : "sync-now".tr(),
                    disabled: syncingNow,
                    onTap: syncNow,
                  ),
                  SizedBox(height: 12),
                  ..._changesWaiting(),
                  SizedBox(height: 8),
                  SettingsContainerDropdown(
                    enableBorderRadius: true,
                    title: "firefly-payee-naming".tr(),
                    description: "firefly-payee-naming-description".tr(),
                    icon: appStateSettings["outlinedIcons"]
                        ? Icons.storefront_outlined
                        : Icons.storefront_rounded,
                    initial: counterpartyNaming,
                    items: const [
                      kFireflyCounterpartyNamingGeneric,
                      kFireflyCounterpartyNamingCategory,
                    ],
                    getLabel: (String value) =>
                        value == kFireflyCounterpartyNamingCategory
                            ? "firefly-payee-naming-category".tr()
                            : "firefly-payee-naming-generic".tr(),
                    onChanged: (String value) async {
                      await setFireflyCounterpartyNaming(value);
                      setState(() {
                        counterpartyNaming = fireflyCounterpartyNaming;
                      });
                    },
                  ),
                  SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Button(
                          label: "firefly-sync-all-history".tr(),
                          disabled: runningHistoryAction || syncingNow,
                          onTap: syncAllHistory,
                        ),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Button(
                          label: "firefly-rebuild".tr(),
                          disabled: runningHistoryAction || syncingNow,
                          onTap: rebuildFromFirefly,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextFont(
                      text: "firefly-linked-accounts".tr(),
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 4),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextFont(
                      text: "firefly-linked-accounts-description".tr(),
                      fontSize: 13,
                      maxLines: 5,
                      textColor: getColor(context, "textLight"),
                    ),
                  ),
                  SizedBox(height: 8),
                  for (FireflyLinkedWallet wallet in linkedWallets)
                    SettingsContainer(
                      key: ValueKey(wallet.walletPk),
                      enableBorderRadius: true,
                      title: wallet.walletName,
                      description: _linkedWalletDescription(wallet),
                      icon: appStateSettings["outlinedIcons"]
                          ? Icons.account_balance_wallet_outlined
                          : Icons.account_balance_wallet_rounded,
                    ),
                  SizedBox(height: 12),
                  TextFont(
                    text: "firefly-scope-note".tr(),
                    fontSize: 13,
                    maxLines: 12,
                    textColor: getColor(context, "textLight"),
                  ),
                  ValueListenableBuilder<FireflySyncReport?>(
                    valueListenable: fireflySyncReportNotifier,
                    builder: (context, report, child) {
                      if (report == null) return SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsetsDirectional.only(top: 8),
                        child: TextFont(
                          text: report.summary(),
                          fontSize: 13,
                          maxLines: 8,
                          textColor: getColor(context, "textLight"),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // The count of the changes that Firefly does not have yet, and each change
  // that Firefly refused, with the actions for those.
  List<Widget> _changesWaiting() {
    FireflyQueuedChanges? changes = queuedChanges;
    if (changes == null) return [];
    List<FireflyOutboxEntry> failed = changes.failed;
    int waiting = changes.pending + failed.length;
    return [
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextFont(
          text: "firefly-changes-waiting".tr(),
          fontSize: 15,
          fontWeight: FontWeight.bold,
        ),
      ),
      SizedBox(height: 4),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextFont(
          fontSize: 13,
          maxLines: 3,
          textColor: getColor(context, "textLight"),
          text: waiting == 0
              ? "firefly-changes-waiting-none".tr()
              : "firefly-changes-waiting-count"
                  .tr(namedArgs: {"count": waiting.toString()}),
        ),
      ),
      if (failed.isNotEmpty) ...[
        SizedBox(height: 4),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextFont(
            text: "firefly-changes-failed".tr(
                namedArgs: {"count": failed.length.toString()}),
            fontSize: 13,
            maxLines: 5,
            textColor: getColor(context, "textLight"),
          ),
        ),
        SizedBox(height: 8),
        for (FireflyOutboxEntry entry in failed)
          SettingsContainer(
            key: ValueKey(entry.entityType.name + "/" + entry.localPk),
            enableBorderRadius: true,
            title: _entityKindLabel(entry.entityType),
            description: _shortError(entry.lastError),
            icon: appStateSettings["outlinedIcons"]
                ? Icons.error_outlined
                : Icons.error_rounded,
          ),
        SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Button(
                label: "firefly-retry-changes".tr(),
                disabled: runningHistoryAction || syncingNow,
                onTap: retryFailedChanges,
              ),
            ),
            SizedBox(width: 10),
            Expanded(
              child: Button(
                label: "firefly-dismiss-changes".tr(),
                disabled: runningHistoryAction || syncingNow,
                onTap: dismissFailedChanges,
              ),
            ),
          ],
        ),
      ],
    ];
  }

  String _statusLabel(FireflySyncStatus status) {
    switch (status) {
      case FireflySyncStatus.syncing:
        return "syncing".tr();
      case FireflySyncStatus.error:
        return "error".tr();
      case FireflySyncStatus.neverSynced:
        return "never".tr();
      case FireflySyncStatus.idle:
        return "idle".tr();
    }
  }
}
