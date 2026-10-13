// The fields of a transaction that only Firefly mode shows: the payee (the
// expense or revenue account of Firefly) and the tags.

import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/firefly/client/fireflyPull.dart'
    show fireflySplitIsEditable;
import 'package:budget/struct/firefly/client/fireflyStore.dart';
import 'package:budget/struct/firefly/fireflySettings.dart' show fireflyEnabled;
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/selectChips.dart';
import 'package:budget/widgets/tappable.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

// The state of a local transaction on Firefly. `mirrored` is true when the
// row has a Firefly record. `readOnly` is true when that record is
// reconciled, an opening balance or a reconciliation. Both are false when
// Firefly mode is off.
class FireflyRowState {
  const FireflyRowState({required this.mirrored, required this.readOnly});
  final bool mirrored;
  final bool readOnly;
}

Future<FireflyRowState> fireflyRowStateOf(String transactionPk) async {
  if (!fireflyEnabled) {
    return const FireflyRowState(mirrored: false, readOnly: false);
  }
  try {
    FireflySyncMapEntry? map =
        await fireflyMapOf(FireflySyncEntityType.transaction, transactionPk);
    Map<String, dynamic>? snapshot = fireflySnapshotOf(map);
    // A row with no snapshot is not read yet; the engine holds its change.
    // Do not lock it here.
    return FireflyRowState(
      mirrored: map != null,
      readOnly: snapshot != null && !fireflySplitIsEditable(snapshot),
    );
  } catch (e) {
    print("Firefly row state: " + e.toString());
    return const FireflyRowState(mirrored: false, readOnly: false);
  }
}

// Tells the user that the transaction cannot change here.
void openFireflyReadOnlySnackbar() {
  openSnackbar(SnackbarMessage(
    title: "firefly-read-only".tr(),
    description: "firefly-read-only-description".tr(),
    icon: appStateSettings["outlinedIcons"]
        ? Icons.lock_outlined
        : Icons.lock_rounded,
  ));
}

// Tells the user that a Firefly transaction stays paid.
void openFireflyCannotMarkUnpaidSnackbar() {
  openSnackbar(SnackbarMessage(
    title: "firefly-cannot-mark-unpaid".tr(),
    icon: appStateSettings["outlinedIcons"]
        ? Icons.lock_outlined
        : Icons.lock_rounded,
  ));
}

// The notice at the top of the page of a read-only transaction.
class FireflyReadOnlyNotice extends StatelessWidget {
  const FireflyReadOnlyNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsetsDirectional.symmetric(horizontal: 13, vertical: 8),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadiusDirectional.circular(15),
        ),
        padding:
            const EdgeInsetsDirectional.symmetric(horizontal: 15, vertical: 12),
        child: Row(
          children: [
            Icon(
              appStateSettings["outlinedIcons"]
                  ? Icons.lock_outlined
                  : Icons.lock_rounded,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFont(
                    text: "firefly-read-only".tr(),
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    textColor:
                        Theme.of(context).colorScheme.onSecondaryContainer,
                  ),
                  SizedBox(height: 2),
                  TextFont(
                    text: "firefly-read-only-description".tr(),
                    fontSize: 14,
                    maxLines: 5,
                    textColor:
                        Theme.of(context).colorScheme.onSecondaryContainer,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// The payee of a withdrawal or a deposit. An empty payee is the cash account
// of Firefly; `onChanged` then gets null.
class FireflyPayeeField extends StatefulWidget {
  const FireflyPayeeField({
    required this.payee,
    required this.onChanged,
    super.key,
  });
  final String? payee;
  final ValueChanged<String?> onChanged;

  @override
  State<FireflyPayeeField> createState() => _FireflyPayeeFieldState();
}

class _FireflyPayeeFieldState extends State<FireflyPayeeField> {
  late TextEditingController _controller =
      TextEditingController(text: widget.payee ?? "");

  @override
  void didUpdateWidget(covariant FireflyPayeeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.payee ?? "") != _controller.text) {
      _controller.text = widget.payee ?? "";
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 22),
      child: Tappable(
        color: getColor(context, "canvasContainer"),
        borderRadius: 15,
        onTap: () async {
          String? result = await openFireflyTextWithSuggestions(
            context,
            title: "firefly-payee".tr(),
            initialText: widget.payee ?? "",
            showClear: true,
            getSuggestions: (search) =>
                database.getDistinctPayees(search: search, limit: 20),
          );
          if (result == null) return;
          String payee = result.trim();
          widget.onChanged(payee.isEmpty ? null : payee);
        },
        child: IgnorePointer(
          child: TextInput(
            padding: EdgeInsetsDirectional.zero,
            readOnly: true,
            labelText: "firefly-payee-cash".tr(),
            icon: appStateSettings["outlinedIcons"]
                ? Icons.storefront_outlined
                : Icons.storefront_rounded,
            controller: _controller,
          ),
        ),
      ),
    );
  }
}

// The tags of a transaction as chips. A tap on a chip removes the tag; the
// add button adds a tag.
class FireflyTagsField extends StatelessWidget {
  const FireflyTagsField({
    required this.tags,
    required this.onChanged,
    this.wrapped = false,
    super.key,
  });
  final List<String> tags;
  final ValueChanged<List<String>> onChanged;
  final bool wrapped;

  Future<void> addTag(BuildContext context) async {
    String? result = await openFireflyTextWithSuggestions(
      context,
      title: "firefly-add-tag".tr(),
      initialText: "",
      showClear: false,
      getSuggestions: (search) async {
        List<String> found =
            await database.getDistinctTags(search: search, limit: 30);
        return found.where((tag) => !tags.contains(tag)).toList();
      },
    );
    String tag = (result ?? "").trim();
    if (tag.isEmpty || tags.contains(tag)) return;
    // A new list, thus the page sees a change of the row.
    onChanged([...tags, tag]);
  }

  @override
  Widget build(BuildContext context) {
    return SelectChips<String>(
      wrapped: wrapped,
      items: tags,
      getSelected: (_) => true,
      getLabel: (tag) => tag,
      onSelected: (tag) {
        onChanged(tags.where((t) => t != tag).toList());
      },
      extraWidgetAfter: SelectChipsAddButtonExtraWidget(
        openPage: null,
        onTap: () => addTag(context),
      ),
    );
  }
}

// Opens a popup with a text field and the suggestions that match its text.
// Returns the text, or null when the user closes the popup.
Future<String?> openFireflyTextWithSuggestions(
  BuildContext context, {
  required String title,
  required String initialText,
  required bool showClear,
  required Future<List<String>> Function(String search) getSuggestions,
}) async {
  dynamic result = await openBottomSheet(
    context,
    popupWithKeyboard: true,
    PopupFramework(
      title: title,
      child: _FireflyTextWithSuggestions(
        initialText: initialText,
        showClear: showClear,
        getSuggestions: getSuggestions,
      ),
    ),
  );
  if (result is String) return result;
  return null;
}

class _FireflyTextWithSuggestions extends StatefulWidget {
  const _FireflyTextWithSuggestions({
    required this.initialText,
    required this.showClear,
    required this.getSuggestions,
  });
  final String initialText;
  final bool showClear;
  final Future<List<String>> Function(String search) getSuggestions;

  @override
  State<_FireflyTextWithSuggestions> createState() =>
      _FireflyTextWithSuggestionsState();
}

class _FireflyTextWithSuggestionsState
    extends State<_FireflyTextWithSuggestions> {
  late String text = widget.initialText;
  late Future<List<String>> suggestions = widget.getSuggestions("");

  void setText(String value) {
    setState(() {
      text = value;
      suggestions = widget.getSuggestions(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextInput(
          autoFocus: true,
          initialValue: widget.initialText,
          labelText: "",
          padding: EdgeInsetsDirectional.zero,
          textCapitalization: TextCapitalization.sentences,
          onChanged: setText,
          onEditingComplete: () {
            popRoute(context, text);
          },
        ),
        FutureBuilder<List<String>>(
          future: suggestions,
          builder: (context, snapshot) {
            List<String> items = (snapshot.data ?? [])
                .where((item) => item != text.trim())
                .toList();
            if (items.isEmpty) return SizedBox(height: 10);
            return Padding(
              padding: const EdgeInsetsDirectional.only(top: 10, bottom: 5),
              child: SelectChips<String>(
                wrapped: true,
                items: items,
                getSelected: (_) => false,
                getLabel: (item) => item,
                onSelected: (item) {
                  popRoute(context, item);
                },
              ),
            );
          },
        ),
        SizedBox(height: 5),
        Row(
          children: [
            if (widget.showClear)
              Expanded(
                child: Button(
                  label: "clear".tr(),
                  onTap: () {
                    popRoute(context, "");
                  },
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  textColor: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
            if (widget.showClear) SizedBox(width: 10),
            Expanded(
              child: Button(
                label: "done".tr(),
                onTap: () {
                  popRoute(context, text);
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}
