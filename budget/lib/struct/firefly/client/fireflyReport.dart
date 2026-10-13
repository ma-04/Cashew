// What one cycle of the Firefly client did. The settings page shows the
// summary, and each warning names a record that the user must look at.

class FireflySyncReport {
  int pulledWallets = 0;
  int pulledCategories = 0;
  int pulledTransactions = 0;
  int removedTransactions = 0;
  int pushedCreates = 0;
  int pushedUpdates = 0;
  int pushedDeletes = 0;
  // Local edits of a field that the server changed too. The server value
  // stays.
  int conflicts = 0;
  // Local edits that the server refused, or that change a record that this
  // app must not change. The local row went back to the server state.
  int reverted = 0;
  // Changes that wait: the record they need is not on the server yet, or the
  // record has no snapshot yet.
  int held = 0;
  // Changes that the server refused. They stay in the list of failed changes.
  int failed = 0;
  // Local rows that do not go to Firefly: balance corrections, unpaid
  // planning rows, subcategories.
  int keptLocal = 0;
  final List<String> warnings = [];

  void warn(String message) {
    if (!warnings.contains(message)) warnings.add(message);
  }

  bool get changedAnything =>
      pulledWallets +
          pulledCategories +
          pulledTransactions +
          removedTransactions +
          pushedCreates +
          pushedUpdates +
          pushedDeletes >
      0;

  String summary() {
    List<String> parts = [];
    void add(int n, String what) {
      if (n > 0) parts.add("$n $what");
    }

    add(pulledWallets, "accounts pulled");
    add(pulledCategories, "categories pulled");
    add(pulledTransactions, "transactions pulled");
    add(removedTransactions, "transactions removed");
    add(pushedCreates, "created on Firefly");
    add(pushedUpdates, "updated on Firefly");
    add(pushedDeletes, "deleted on Firefly");
    add(conflicts, "conflicts (Firefly kept its value)");
    add(reverted, "local changes undone");
    add(held, "changes waiting");
    add(failed, "changes refused");
    if (parts.isEmpty) return "Nothing to sync";
    return parts.join(", ");
  }
}
