import 'package:budget/colors.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/firefly/fireflyApiClient.dart';
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

// Self-hosted Firefly III integration settings: enable toggle, host URL,
// PAT entry (write-only - never redisplayed after save, mirroring how the
// app never redisplays other secrets), connection test, and manual sync.
//
// Enabling this while the existing Google Drive sync (appStateSettings
// ["backupSync"]) is on shows a confirm dialog and turns Google Drive sync
// off first - the two are mutually exclusive per install. See the symmetric
// check in lib/widgets/accountAndBackup.dart's backupSync toggle.
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

  Future<bool> enableFirefly() async {
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
    await _doEnableFirefly();
    return true;
  }

  Future<void> _doEnableFirefly() async {
    await setFireflyHostUrl(hostController.text.trim());
    if (patController.text.trim().isNotEmpty) {
      await setFireflyPat(patController.text.trim());
      patController.clear();
    }
    await setFireflyEnabled(true);
    setState(() {
      enabled = true;
    });
    fireflySyncNow();
  }

  Future<bool> disableFirefly() async {
    await setFireflyEnabled(false);
    setState(() {
      enabled = false;
    });
    return true;
  }

  Future<void> saveHostAndToken() async {
    await setFireflyHostUrl(hostController.text.trim());
    if (patController.text.trim().isNotEmpty) {
      await setFireflyPat(patController.text.trim());
      patController.clear();
      setState(() {});
    }
    openSnackbar(SnackbarMessage(title: "saved".tr()));
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
    openSnackbar(
      SnackbarMessage(
        title: success
            ? "firefly-sync-successful".tr()
            : "firefly-sync-failed".tr(),
        description: success ? null : fireflySyncErrorNotifier.value,
        icon: appStateSettings["outlinedIcons"]
            ? (success ? Icons.check_circle_outlined : Icons.error_outlined)
            : (success ? Icons.check_circle_rounded : Icons.error_rounded),
      ),
    );
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
              maxLines: 3,
              textColor: getColor(context, "textLight"),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding:
                const EdgeInsetsDirectional.symmetric(horizontal: 17, vertical: 8),
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
