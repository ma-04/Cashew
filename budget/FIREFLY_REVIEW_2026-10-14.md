# Firefly client: adversarial review, 2026-10-14

Branch `feature/firefly-client` at `e288ab17`. Six reviewers each covered one area: push body, local writers, pull and state, lifecycle and backup, UI, and schema and tests. The lead then checked the findings against the code. The four highest findings were run against the Docker Firefly 6.7.9 with `test/firefly/live/review_repro_test.dart`, a temporary file that is not committed.

Status labels:
- **LIVE**: reproduced on the Docker Firefly.
- **CODE**: the lead read the cited code and the path is real.
- **PLAUSIBLE**: from a reviewer; the lead did not check it.
- **REJECTED**: checked and not a problem.

## A. Firefly data is changed or deleted (the "no skew" rule is broken)

| # | Finding | Status | Where |
|---|---|---|---|
| A1 | Deleting the "Uncategorized" category DELETEs every uncategorized transaction on Firefly. Deleting "Balance correction" (`"0"`) DELETEs every transfer, liability leg and so on in the same way. These two categories have no map row, so `deleteCategory` takes the Cashew path (`deleteCategoryTransactions` + DeleteLogs), and each linked row then becomes a remote DELETE. The UI offers delete for both. | **LIVE** (Uncategorized). "0" follows the same code path. | tables.dart:5314-5321, 5360-5370; fireflySyncEngine.dart:348-356 |
| A2 | A wallet deleted while sync is off: its full history is DELETEd on Firefly when sync comes back on and the first cycle is a push-only cycle (for example, a local edit just after re-enabling). The same applies to a category delete, and a budget delete sends `budget_id: null`. The guards check `fireflyEnabled` instead of "has a map row". Re-enabling on the same host does not rebuild. The planned `fireflyLinkedAt` / `fireflyUnsyncedSince` guard was never connected. | **LIVE** (with a push-only cycle; a full cycle re-pulled the rows first) | fireflyStore.dart:226; fireflySettingsPage.dart:234-289; fireflySettings.dart:96-123 |
| A3 | Reordering categories or wallets (`moveCategory`, `shiftCategories`, `moveWallet`, `shiftWallets` bump `dateTimeModified`) POSTs every **unlinked** local category or wallet to Firefly. Cashew's default categories ("Dining", "Beauty", ...) and pre-Firefly wallets stay unlinked after the first sync. It also happens with no user action: a category deleted in the Firefly web UI makes the pull call `deleteCategory` → `shiftCategories`. | **CODE** | fireflyStore.dart:85 (`map == null` → dirty); fireflyPush.dart:184-200, 285-300 |
| A4 | An account deleted on Firefly comes back. The pull keeps the wallet without a map row; any later touch (rename, reorder, a queued deactivate) POSTs `/accounts` again as an asset account. | CODE (the reviewers agree) | fireflyPull.dart:357-367; fireflyPush.dart:285-303 |
| A5 | Merging a Firefly category into a category Firefly does not have leaves the rows without a category on both sides, or held for ever. | PLAUSIBLE | tables.dart:5782-5830 |
| A6 | Deleting an unlinked category or wallet that holds Firefly rows DELETEs those rows on Firefly. This has the same cause as A1. | CODE (same path as A1) | tables.dart:5360-5370, 5689-5700 |
| A7 | "Update both transfers?" on edit: (a) the fallback match (category "0", opposite sign, ±1 s) can catch an **unrelated** transfer leg, and the push then overwrites that transfer's amount and tags. (b) On a cross-currency transfer, `foreign_amount` is recomputed with Cashew's exchange rates. | PLAUSIBLE (b is high confidence) | addTransactionPage.dart:488-563; tables.dart:7927-8020 |
| A8 | The category colour parser accepts a bare `#xxxxxx` anywhere in the notes. "Invoice #123456" is read as a colour, and a colour change in Cashew rewrites it to "Invoice #ff8800" on Firefly. | CODE | fireflyProjection.dart:456-467, 494-503 |
| A9 | The subcategory tag is rebuilt from local names. A category rename, or a difference in case or whitespace, rewrites the tag on each row the user edits later. After a category is deleted, the next edit of a row removes its `Parent/Child` tag on Firefly. | PLAUSIBLE (two reviewers agree) | fireflyProjection.dart:199-210; fireflyPull.dart:246-251 |
| A10 | A Firefly category named "Uncategorized" or "Balance Correction" links by name to a system category, and the next edit of its rows then sends `category_id: null`. | PLAUSIBLE | fireflyPull.dart:157-165 |
| A11 | Adding a Firefly withdrawal to a local-only Cashew budget sends `budget_id: null` and clears its Firefly budget. This is by design in the plan, but the user cannot see it. After the v3 backfill, a pending row in a local budget has the same effect. | CODE | fireflyPush.dart:423-431 |
| A12 | A backup restore can POST a duplicate. `_lostCreate` finds the server record but returns on an open op without linking it, and the push skips the search because `attempts == 0`. `error_if_duplicate_hash` is never sent (plan §3.2 says it is). | PLAUSIBLE | fireflyPull.dart:653-657; fireflyPush.dart:472-526 |
| A13 | The delete path checks only the snapshot's `reconciled` flag, not the live flag that the update path uses. A row reconciled on Firefly after the last pull can be deleted. | CODE (reviewer quote) | fireflyPush.dart:697-719 |
| A14 | `apply_rules` is not sent on PUT. If Firefly runs the user's rules on update, a date edit could change other fields on the server. | Accepted by the owner (see the status table) | fireflyPush.dart:657-674 |
| A15 | A date is sent as a UTC instant. A server in another time zone can book it on the previous day. | PLAUSIBLE (needs a server check) | fireflyProjection.dart:283-288 |
| — | Amount float noise (`99999.99` → `"99999.990000000005"`) | **REJECTED**: Firefly stores `99999.990000000000` | fireflyProjection.dart:293 |

## B. A local change is lost, or Cashew silently differs from Firefly

| # | Finding | Status |
|---|---|---|
| B1 | A local delete is undone by a full cycle that runs before the push: the open-op check needs a local row, so the pull re-creates the row and the delete op then finds no diff. This applies to any delete made offline, or one whose push-only cycle failed. The same happens to one deleted leg of a pair. | **LIVE** |
| B2 | Saving the edit-wallet page clears `archived` and `accountKind`, because a new `TransactionWallet` is built without them (insertOrReplace), and nothing repairs it. An inactive account comes back in the pickers, and a loan wallet then builds a `transfer` that Firefly refuses. | CODE (two reviewers) |
| B3 | Deleting one transfer leg ("only current") deletes the whole Firefly transfer but keeps the other local leg as an orphan, so its wallet balance stays wrong. | CODE (three reviewers) |
| B4 | Edits to a transfer leg's category, or to the destination leg's date or amount, are dropped and never reverted, so Cashew differs from Firefly for good. | PLAUSIBLE |
| B5 | The push's apply context (`force: true`, no open ops) overwrites a queued edit of a sibling split in the same group. | PLAUSIBLE |
| B6 | Pull writes are not atomic. A kill between the row write and the map write can lead to a duplicate create. | PLAUSIBLE (low likelihood) |
| B7 | Bulk "change category or account" to an unlinked target holds the rows for ever. That also turns off `_checkBalances`, which returns while any op is pending. | PLAUSIBLE |
| B8 | A wallet's initial balance and "update total balance" are local-only rows. The new Firefly account has no opening balance. | CODE |
| B9 | Debt/credit flows: "collect all" is reverted on every sync, and "partially collect" renames the Firefly transaction to "initial-record". | PLAUSIBLE |
| B10 | Subcategory rename and main→sub category conversion are not tracked (the first is already known). | CODE |
| B11 | Deleting a row whose create got no answer loses the delete, and the pull then brings the row back. | PLAUSIBLE |
| B12 | A rebuild clears the outbox, so pending local edits are lost (they are kept only in the backup file). | CODE |
| B13 | A wallet that becomes inactive stays the selected default for new transactions. | PLAUSIBLE |
| B14 | The Firefly budget edit page still allows edits to name, amount and period, which the next pull overwrites. | PLAUSIBLE |

## C. Lifecycle and security

| # | Finding | Status |
|---|---|---|
| C1 | "Test connection" sends the saved token to a new host that is not yet saved, for example a typo in the host field. | CODE (reviewer quote) |
| C2 | A token change for a different user on the same host is not treated as a host change, so the maps and the outbox stay. A restore can also pair host A's settings with host B's token. | PLAUSIBLE |
| C3 | A 404 or 401 is not caught in `_run`, so one stale wallet or category op stops every push cycle. A 5xx is retried for ever. | CODE |
| C4 | A wallet create is not idempotent: a retry after a lost reply gets a 422, then the next pull makes a second local wallet. | PLAUSIBLE |
| C5 | A host change while a cycle is running mixes the ids of two servers. | PLAUSIBLE |
| C6 | `http://` is accepted (on desktop and web the token is sent in clear). There is no "forget token" action. | CODE |

## D. Tests

- `test/firefly/firefly_mapper_test.dart` (1059 lines) tests functions of the old engine that `lib/` no longer calls. `test/firefly/firefly_test_env.dart` (FakeFirefly) is not imported by any test.
- CI does not run the live tests, so it does not test `fireflyPush`, `fireflyPull` or `fireflySyncEngine` at all.
- Several live tests check only some fields: amount edit, loan edit, income flip, category merge, subcategory tag, payee clear, budget clear, and the account attributes after a deactivate.
- The live harness has no check that the server is the test instance; only `env.sh` decides that.
- The migration test covers 46–51 only, with empty databases, and does not test the v47 dedup.

## Checked and correct (by the reviewers)

- A PUT sends every live split by `transaction_journal_id`, so no split is dropped.
- The 3-way merge sends only the fields the user changed and keeps newer server edits. Foreign amount, bill, piggy bank, interest dates, `internal_reference` and `reconciled` are never sent.
- Account PUTs send only `name` or `active:false`. A wallet delete deactivates the account.
- Remote deletes are confirmed by a 404 before a local removal, and pagination refuses partial data.
- There is a single pusher; the old engine and mapper hold only constants and pure helpers.
- The token is in secure storage and not in backups or logs. There is no TLS bypass.
- When sync is off, the hooks do nothing for non-Firefly users. The schema 52 migration is sound.

## Status after the fixes (same day)

The owner's decisions:
- Unlinked leftovers are removed at the link.
- Changes made while sync was off are shown and confirmed before they are sent.
- Local-only budgets are hidden from the budget picker while sync is on.

Then everything in section A was fixed, plus B1 to B3. The tests in `test/firefly/live/firefly_review_regression_test.dart` run against the Docker Firefly. Each test names its item, and each fix also has an analyzer pass. The full suite passes: 149 tests, the live ones included.

| Item | Fix | Test |
|---|---|---|
| A1, A6 | `fireflyDeleteRefusal`: while sync is on, the two system categories cannot be deleted. A category or wallet with no link that holds Firefly rows cannot be deleted either. The delete popups show the reason. For a linked record the popup no longer asks "delete all transactions?". `deleteWanderingTransactions` skips Firefly rows. | live A1, A6 |
| A2 | When the user turns sync on again (same host), the settings page first counts the changes the next cycle would send (`fireflyLocalChangesToSend`). It then asks: Send to Firefly, Discard (a rebuild after a backup), or Cancel. | live A2 (count + discard) |
| A3 | The rebuild removes unlinked empty categories and wallets, then sets `fireflyLinkedAt`. Installs that were linked before this run the clean-up once at their next sync. They delete the empty categories, but only make the wallets inactive, because these users did not confirm a replace of their data. The scan does not queue an unlinked record created before the link. A record is queued only when the user puts a transaction into it. | live A3 (2 tests) |
| A4 | An account deleted on Firefly: the wallet is deleted when it is empty, or else made inactive. An unlinked inactive wallet, or a deactivate intent with no link, is never POSTed. A 404 no longer stops the push. | live A4 |
| A5 | Covered by the A3 change: a transaction in an unlinked category queues that category. | not tested |
| A7 | A Firefly row matches its other leg by `pairedTransactionFk` only. "Update both" keeps the other leg's amount on a transfer between two currencies. | not tested (UI path) |
| A8 | Owner's decision: Cashew sets the colour and only Cashew reads it. Cashew writes a `color: #rrggbb` line in the notes, and that line is the only thing it reads. Any other text in the notes is never treated as a colour and never changed, and Firefly's `color` field is not used. | unit |
| A9 | The push keeps the server's spelling of the `Parent/Child` tag. When a category is deleted, its subcategory tag stays on the row as a plain tag. A rename still creates new tags (not fixed). | unit (spelling) |
| A10 | Matching by name never links the two system categories. | — |
| A11 | Local-only budgets are hidden from both pickers while sync is on. The push never clears `budget_id` because a row is in a local-only budget. | live A11 |
| A12 | Creates send `error_if_duplicate_hash: true`. On Docker this was checked: the hash includes `external_id`, so only a second create of the same row is refused. A refused duplicate is linked through an `external_id` search. The pull links a lost create and does not skip it. | live A12 |
| A13 | A delete checks the live `reconciled` flag. | — |
| A14 | **Kept (owner's decision):** a PUT does not send `apply_rules`, so Firefly runs the user's "update" rules, the same as an edit in the web UI. The next pull shows the result. | — |
| A15 | **Rejected:** on Docker, a date sent with `+06:00` is stored and shown in the server's time zone, the same as a `Z` date. The day is set by the server's `TZ`, not by the client. | Docker probe |
| B1 | The pull keeps the local state of each split that has an open op, including a deleted row. | live B1 |
| B2 | The wallet page keeps `archived` and `accountKind` on save. | — |
| B3 | A pushed delete of one leg also removes the other local leg. | live B3 |
| D (sentinel) | The live tests run only against a loopback URL. | — |

Still open: B4 to B14 and C1 to C6.
