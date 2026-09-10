import 'package:budget/colors.dart';
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
  late int syncWindowDays = fireflySyncWindowDays;
  // What "Push unsynced changes" would send. null until the first count.
  FireflyUnsyncedCounts? unsyncedCounts;

  @override
  void initState() {
    super.initState();
    fireflySyncReportNotifier.addListener(_refreshUnsyncedCounts);
    _refreshUnsyncedCounts();
  }

  @override
  void dispose() {
    fireflySyncReportNotifier.removeListener(_refreshUnsyncedCounts);
    hostController.dispose();
    patController.dispose();
    super.dispose();
  }

  Future<void> _refreshUnsyncedCounts() async {
    if (!fireflyEnabled) {
      if (mounted) setState(() => unsyncedCounts = null);
      return;
    }
    FireflyUnsyncedCounts counts = await fireflyCountUnsyncedChanges();
    if (mounted) setState(() => unsyncedCounts = counts);
  }

  // The window lengths in days. A fixed list, not a text field, thus the
  // value stays in the limits that fireflySettings sets.
  static const List<int> _windowOptions = [7, 14, 30, 60, 90, 180, 365, 730];

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
    if (appStateSettings["backupSync"] == true) {
      bool confirmed = false;
      await openPopup(
        context,
        title: "cloud-sync".tr(),
        description: "firefly-disable-google-drive-sync-warning".tr(),
        icon: appStateSettings["outlinedIcons"]
            ? Icons.warning_amber_outlined
            : Icons.warning_amber_rounded,
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
      if (!confirmed) return false;
      await updateSettings("backupSync", false,
          pagesNeedingRefresh: [], updateGlobalState: false);
    }
    return await _doEnableFirefly();
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

  Future<bool> _doEnableFirefly() async {
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
    if (_hostChanged(host)) await _forgetPreviousHost();
    await setFireflyHostUrl(host);
    if (token.isNotEmpty) {
      await setFireflyPat(token);
      patController.clear();
    }
    await setFireflyEnabled(true);
    setState(() {
      enabled = true;
    });
    fireflySyncNow();
    return true;
  }

  Future<bool> disableFirefly() async {
    await setFireflyEnabled(false);
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
      await _forgetPreviousHost();
      // Without a token for the new host the application cannot sync. Stop
      // the automatic cycles until the user gives one.
      if (token.isEmpty) await setFireflyEnabled(false);
    }
    await setFireflyHostUrl(host);
    if (token.isNotEmpty) {
      await setFireflyPat(token);
      patController.clear();
    }
    // The cached ranges of the on-demand fetches are answers of the previous
    // host, or of a smaller window.
    fireflyClearOnDemandCacheMemory();
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
    setState(() {
      syncingNow = true;
    });
    bool success = await fireflySyncNow();
    if (mounted) {
      setState(() {
        syncingNow = false;
      });
    }
    await _refreshUnsyncedCounts();
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
    setState(() {
      runningHistoryAction = true;
    });
    bool success = await action();
    if (mounted) {
      setState(() {
        runningHistoryAction = false;
      });
    }
    await _refreshUnsyncedCounts();
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
    bool confirmed = false;
    await openPopup(
      context,
      title: "firefly-sync-all-history".tr(),
      description: "firefly-sync-all-history-warning".tr(),
      icon: appStateSettings["outlinedIcons"]
          ? Icons.history_outlined
          : Icons.history_rounded,
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
    if (!confirmed) return;
    await _runHistoryAction(fireflySyncAllHistory);
  }

  // Sends each local change since the link that Firefly does not hold yet.
  // The routine cycles do the same for each change since the last cycle; this
  // is for the case that those cycles failed for a while.
  Future<void> pushUnsyncedChanges() async {
    FireflyUnsyncedCounts counts = await fireflyCountUnsyncedChanges();
    if (!context.mounted) return;
    setState(() => unsyncedCounts = counts);
    if (counts.isEmpty) {
      openSnackbar(
        SnackbarMessage(
          title: "firefly-unsynced-none".tr(),
          icon: appStateSettings["outlinedIcons"]
              ? Icons.check_circle_outlined
              : Icons.check_circle_rounded,
        ),
      );
      return;
    }
    bool confirmed = false;
    await openPopup(
      context,
      title: "firefly-push-unsynced".tr(),
      description:
          "firefly-push-unsynced-description".tr() + "\n\n" + counts.describe(),
      icon: appStateSettings["outlinedIcons"]
          ? Icons.cloud_upload_outlined
          : Icons.cloud_upload_rounded,
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
    if (!confirmed) return;
    await _runHistoryAction(fireflyPushUnsyncedChanges);
  }

  Future<void> uploadExistingLocalHistory() async {
    bool confirmed = false;
    await openPopup(
      context,
      title: "firefly-upload-local-history".tr(),
      description: "firefly-upload-local-history-warning".tr(),
      icon: appStateSettings["outlinedIcons"]
          ? Icons.warning_amber_outlined
          : Icons.warning_amber_rounded,
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
    if (!confirmed) return;
    await _runHistoryAction(fireflyUploadExistingLocalHistory);
  }

  // The links, not the records. To turn the sync off must not do this: the
  // pull makes a new record for each remote split that no link names, thus a
  // user who turns the sync off and on again would get each transaction two
  // times. This action therefore asks first.
  Future<void> resetFireflyLinks() async {
    bool confirmed = false;
    await openPopup(
      context,
      title: "firefly-reset-links".tr(),
      description: "firefly-reset-links-warning".tr(),
      icon: appStateSettings["outlinedIcons"]
          ? Icons.link_off_outlined
          : Icons.link_off_rounded,
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
    if (!confirmed) return;
    await fireflyForgetSyncState();
    if (mounted) setState(() {});
    openSnackbar(SnackbarMessage(
      title: "firefly-reset-links-done".tr(),
      icon: appStateSettings["outlinedIcons"]
          ? Icons.link_off_outlined
          : Icons.link_off_rounded,
    ));
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
                  SizedBox(height: 8),
                  TextFont(
                    textAlign: TextAlign.center,
                    fontSize: 13,
                    maxLines: 3,
                    textColor: getColor(context, "textLight"),
                    text: unsyncedCounts == null
                        ? ""
                        : unsyncedCounts!.isEmpty
                            ? "firefly-unsynced-none".tr()
                            : "firefly-unsynced-count".tr(namedArgs: {
                                "count": unsyncedCounts!.total.toString()
                              }),
                  ),
                  SizedBox(height: 8),
                  Button(
                    label: "firefly-push-unsynced".tr(),
                    disabled: runningHistoryAction ||
                        syncingNow ||
                        (unsyncedCounts?.isEmpty ?? true),
                    onTap: pushUnsyncedChanges,
                  ),
                  SizedBox(height: 12),
                  SettingsContainerDropdown(
                    enableBorderRadius: true,
                    title: "firefly-sync-window".tr(),
                    description: "firefly-sync-window-description".tr(),
                    icon: appStateSettings["outlinedIcons"]
                        ? Icons.date_range_outlined
                        : Icons.date_range_rounded,
                    initial: syncWindowDays.toString(),
                    items: [
                      for (int days in _windowOptions) days.toString(),
                    ],
                    getLabel: (String value) => value + " " + "days".tr(),
                    onChanged: (String value) async {
                      int? days = int.tryParse(value);
                      if (days == null) return;
                      await setFireflySyncWindowDays(days);
                      // A range that was in the window with the previous
                      // setting can be outside of the window now.
                      fireflyClearOnDemandCacheMemory();
                      setState(() {
                        syncWindowDays = fireflySyncWindowDays;
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
                          label: "firefly-upload-local-history".tr(),
                          disabled: runningHistoryAction || syncingNow,
                          onTap: uploadExistingLocalHistory,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Button(
                    label: "firefly-reset-links".tr(),
                    disabled: runningHistoryAction || syncingNow,
                    onTap: resetFireflyLinks,
                  ),
                  SizedBox(height: 12),
                  TextFont(
                    text: "firefly-scope-note".tr(),
                    fontSize: 13,
                    maxLines: 8,
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
