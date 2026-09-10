# TODO

## Done

### Never rewrite a Firefly row that belongs to another account

An adversarial review of the entry below found that it closed the way into the
incident, not the mechanism of it. `_pushOneTransaction` builds the split from
the link that the wallet holds now (`walletFireflyId: walletMap.fireflyId`)
and sends it to the group that the map row of the transaction names. A map row
that names a group on another Firefly account therefore still moves that group
onto the account of the wallet. The manual link picker makes such rows by
design: it points the wallet at another account and leaves the rows of the old
account mapped.

- New guard `_pushBlockedByMovedRemoteRow`. Before a push writes to a group it
  reads the asset accounts of the split. An account that is not the account of
  the wallet, and that no local account is linked to, holds the write back:
  the change stays in front of the watermark, `report.skippedMovedRemoteRow`
  counts it and one warning per group names the account. The discriminator is
  the link, not the account: a relink always leaves the old account linked to
  no wallet, and a transaction that the user moved to another wallet by hand
  leaves the account it came from linked to the wallet it came from, thus that
  transaction still moves on Firefly. The guard is on the update path of
  `_pushOneTransaction`, on `_pushExistingMultiSplitGroup`, on `_pushTransfer`
  and on the removal of a row that is no longer paid.
- The rule "nothing goes into an inactive account" now holds for every write,
  not for new and changed transactions only: the removal of a row that is no
  longer paid, the removal of one split of a group, and the rename of the
  account itself. A cycle can no longer report that nothing was pushed into an
  inactive account while it renamed that account.
- An id that the asset list of the cycle does not carry holds the push back as
  well. The account is gone, or is not an asset account; either way the app
  cannot judge the write, and going on took the same 422 in every cycle.
- An empty currency is no currency. `"" != "USD"` made a transfer carry a
  foreign amount with no currency code of its own, which is how 1,200 BDT came
  to count as 1,200 USD. A wallet made before the currency setting has `""` or
  null there.
- `convertToPrimaryWallet` runs its four steps in one transaction. A sync
  cycle between two of them saw two copies of one account, or an account whose
  rows had moved and whose Firefly link had not.
- The settings page: an overlapping refresh of the links is queued in place of
  dropped, `loadingWalletLinks` cannot stick on an error, a link that fails
  tells the user in place of failing in silence, the confirm dialog names the
  local account that loses the link, a list of accounts that could not be read
  no longer reads as "not linked", and a second sync while a cycle runs says
  that a sync is running in place of "sync failed".
- Tests: a row of the old account is not rewritten onto the new one, a row
  that the user moved to another wallet still moves on Firefly, an unpaid row
  is not deleted from an inactive account, an account that Firefly does not
  list holds the push back, an update does not write into a deactivated
  account, a wallet with no currency sends no foreign amount, and a transfer
  between two currencies carries both amounts over the wire in both
  directions. 98 tests pass.

### Follow the link when the primary wallet changes

The report was: the first push after the fix below "created lots of duplicated
changes and inflated 2 wallet balances". On the server nothing was created:
38 transaction groups of the account "Cash wallet" (id 4) were *updated* to
name the account "Bank" (id 358), which the user had deactivated and then
removed in this app. "Cash wallet" fell from 1,700 to -28,290 BDT, "Bank" rose
to 29,990.

Cashew cannot delete the wallet with the pk `"0"`. `deleteWallet("0")` copies
the first other wallet onto that key (`convertToPrimaryWallet`), moves its
transactions there and deletes its old key. The Firefly link stayed where it
was: `"0"` kept the link to the account of the removed wallet, and the delete
log of the old key unlinked the account that the moved wallet belongs to. Each
row of the wallet was then pushed into the account of the removed wallet. The
rename of that account is refused ("This account name is already in use."),
which before the fix below stopped the cycle in front of the transactions -
the reason this appeared only after that fix.

- `convertToPrimaryWallet` calls the new `swapFireflyWalletLinks(a, b)`
  (`tables.dart`): both wallet rows of `fireflySyncMap`, tombstones included,
  change places in one transaction. `"0"` gets the link of the wallet that
  moved there, and the key that is about to be deleted gets the link of the
  removed wallet, thus its delete log unlinks that account, as a wallet delete
  always does.
- The push never writes into a Firefly account that is inactive. Each cycle
  holds the asset accounts in `_FireflyAssetIndex`; a row whose wallet is
  linked to an inactive account is held back (the watermark stays at it, thus
  the next cycle tries again), counted in `report.skippedInactiveAccount` and
  named once per account: activate it on Firefly, or link the local account to
  another Firefly account. Both sides of a transfer and every row of a split
  group are tested.
- A rename that Firefly refuses because another account holds the name is one
  warning and one `failedWallets`; the link stays on the account it had. It
  was the raw message of the generic catch before.
- A split group that Firefly refuses is attempted once per cycle: the rows of
  the group go into `handledThisPass` before the request, not after it. One
  group gave six warnings and six requests in one cycle before.
- A transfer sends `currency_code`, and between two currencies also
  `foreign_amount` and `foreign_currency_code`; a pulled transfer puts the
  foreign amount on the destination row when it is in that wallet's currency.
  Without this a transfer of 1,200 BDT into a USD account counted 1,200 USD
  there, which is what lifted "EBL Credit USD" from -4.57 to 1,185.75.
- The Firefly settings page has "Linked accounts": one row per local account
  with the Firefly account it syncs with, and a picker with every asset
  account of the server (inactive ones marked) and "Not linked". Choosing one
  moves the link only - no transaction is moved, here or on the server - and
  then syncs, thus the pull attaches the transactions of the new account and
  the balance anchor sets the total again. `fireflyLinkWalletToAccount` also
  removes the tombstone of the account that is chosen, or the pull would keep
  skipping it, and leaves a tombstone for the account that the wallet had, so
  that it is unlinked and not deleted.
- Tests: `test/firefly/firefly_wallet_link_test.dart` (the link follows the
  new primary wallet and nothing goes into the account of the removed wallet;
  an inactive account holds the push back and warns once; a refused rename
  warns and the cycle goes on; the manual link moves the link, clears the
  tombstone and the next pull attaches the rows; unlinking leaves a
  tombstone), the refused split group in `firefly_push_resilience_test.dart`,
  and the two currencies in `firefly_mapper_test.dart`. 91 tests pass.

The 38 groups on the server were repaired with a one-off script that set the
source or the destination of each back to the account 4 and re-sent the
transfer with its currencies; nothing else of those records was touched.

### Keep the cycle alive when Firefly refuses one row

The report was: a new local transaction never reached Firefly, nothing pushed
by itself, and the Cashew balance was below the Firefly balance. The manual
sync showed `HTTP 422: This account name is already in use.` from
`createAccount`. Nothing in `_pushAccounts` caught it, thus the one wallet
stopped the cycle in front of `_pushTransactions`, `_pushDeletes` and
`_refreshBalanceAnchors`, and the watermark did not move: each later cycle,
automatic or manual, failed on the same wallet. The wallet was a second local
account with the name of an account that Firefly holds (Firefly allows one
asset account per name, inactive ones included), and `_pullAccounts` links
one local wallet per remote account only.

- `_pushOneCategory`, `_pushOneAccount` and `_pushOneTransaction` hold the
  body of each push loop. A failure of one row is a warning, a count
  (`failedCategories`, `failedWallets`, `failedTransactions` on the report)
  and a backlog entry, and the loop goes on. An auth error and a rate limit
  still stop the cycle: no row can pass them.
- A create that Firefly refuses for the name (`FireflyValidationException`,
  HTTP 422) links the local row to the remote record with that name
  (`_linkWalletToExistingRemote`, `_linkCategoryToExistingRemote`), and says
  so in a warning. A name that a second local wallet already holds, or that
  a non-asset account holds, gives a warning that asks for a rename; the row
  is not in the backlog, because a rename gives it a new modification time.
- A user edit during an on-demand fetch is pushed afterwards.
  `_reschedulePushIfEditedDuringWork` runs at the end of `fireflySyncNow` and
  of `_withFireflyClient`; before, only the first one read the flag, and
  `fireflySyncNow` cleared it at its start.
- The balance anchor sums the local rows up to the end of today, not up to
  the present moment. Firefly counts each transaction dated today.
- An update of an account keeps the `active` flag that Firefly holds
  (`existingActive` on `walletToFireflyAccount`). Before, each push sent
  `active: true`, and re-enabled an account that the user had deactivated on
  Firefly.
- "Push unsynced changes" on the settings page sends each local change since
  the link that Firefly does not hold, and skips the pull. It reads from
  `fireflyLinkedAt` (set on the first cycle; an older installation gets its
  watermark) and not from the watermark, thus it works after the cycles
  failed for a while. `fireflyCountUnsyncedChanges` gives the count that the
  page shows next to the button; the count uses the local database only.
- `test/firefly/firefly_test_env.dart` holds a small Firefly server on the
  loopback interface and an in-memory database, and
  `firefly_push_resilience_test.dart` and `firefly_push_test.dart` run the
  engine against it: the collision, the per-row failure with the watermark,
  the deactivated account, the anchor, the unsynced push and the auto-push
  after a fetch.

### Match Firefly splits by `transaction_journal_id`, not by position

Fixed in `367105fe`. A Firefly transaction group shares one id across all its
splits, so the sync map had been distinguishing them by their position in
`group.splits`. Firefly renumbers that array when a split is deleted from the
middle of a journal, so a stored position silently started pointing at a
neighbour: the surviving split overwrote the wrong local row, and the row it
should have matched was orphaned and re-imported as a duplicate.

`FireflySyncMap` now carries a nullable `fireflyJournalId` (schema 48 -> 49).
Matching lives in `matchSplitToSyncMap` / `matchSplitToSyncMaps` in
`fireflyMapper.dart` - pure helpers, so the awkward cases are unit-testable
without a database. Rows written before the column existed still match by
position and are backfilled on first sight; a backfilled row is never matched
by position again. Covered by 12 tests in `test/firefly/firefly_mapper_test.dart`.

`fireflySplitIndex` is kept: it no longer carries identity but still drives
ordering when rebuilding a journal's split list.

### Fix upgrades never reaching the Firefly migrations

Fixed in `e46aef13`. Every upgrade from an existing install failed to open the
database; only fresh installs worked, via `onCreate`. Broken since
`schemaVersionGlobal` went 46 -> 47 in the original Firefly commit, so it was
never a regression from the journal-id work.

`onUpgrade` asked the generated `migrationSteps()` to step to `to` (49), but
`drift_schemas/` stops at v46 and the switch throws `ArgumentError("Unknown
migration from N")` past that. `to` is now clamped to
`_lastGeneratedMigrationSchema`, leaving 46 -> 49 to the hand-rolled blocks.

Those blocks were broken too, which only the new test revealed: all three built
`$FireflySyncMapTable(database)`, reaching for the app-wide `late FinanceDatabase
database` global that only app startup assigns, so anywhere the database is
constructed directly they threw `LateInitializationError` into their own catch
and migrated nothing. They now use the generated `fireflySyncMap` accessor.

`test/database/migration_test.dart` upgrades a real on-disk database from v46,
v47, v48 and v49, and asserts the index of schema 50 on each path. To revert
the clamp fails the tests with the original error. The snapshots of the schema
stay outstanding; they are item 4 below, not a blocker.

### Send the journal id on each write, and delete one split at a time

Items 3 and 5. `toRequestJson` now sends `transaction_journal_id` when the
split has one, and `FireflyTransactionSplit.unchangedSplit` gives the id-only
entry that keeps a split as it is. `_splitsForPartialGroupUpdate` builds the
list for a group with several splits: the changed split with its id, and the
id alone for each other split. It first looks for the stored id in the live
group and makes no request if it is not there, because `find()` is scoped to
the group and a stale id makes Firefly create a new split and delete the old
one.

`_journalIdAfterUpdate` reads the id from the response. A group with one split
is updated in place and ignores a submitted id, thus the response is the only
correct source there.

A local delete of one split of a group now calls
`DELETE /v1/transaction-journals/{id}`, and a group with one split still gets
the group delete: a journal delete that removes the last journal leaves an
empty group on the server.

### Make position matching safe, and give each row its journal id

Items 1, 2, 4 and 6.

`fireflyPositionMatchIsSafe` (in `fireflyMapper.dart`) is true only when the
map rows of a group point at as many splits as the group holds.
`fireflySplitSlotCount` counts a journal id one time and a position one time,
thus the two rows of a transfer count as one split. `matchSplitToSyncMaps`
takes `matchByPosition` and gives no match when the positions are not safe.

The pull loop now reads the map rows of the group for each split, matches the
split, and writes the journal id on each matched row before any other test can
end that split. The unmapped-wallet skip, the type skip, the
balance-correction skip and the two early exits of `_pullTransferSplit` are
thus behind the write, not in front of it. The transfer path gets the matched
rows from the caller and no longer looks them up itself.

A split that matches no row, while the group holds a row with no id and the
positions are not safe, is not matched and not imported. Such a group gets one
warning that names the repair (disconnect Firefly and connect it again), and
`FireflySyncReport.skippedAmbiguousSplits` counts the splits. To match by
position there can put a remote change on the wrong local row, and to import
the split makes a second copy of a row that is already here.

A tombstone that holds a position only now counts against a split solely when
no live row claims that split and when the positions are safe.

`_pushExistingMultiSplitGroup` no longer stops the full group for one row: a
row whose journal id is not in the live group is unlinked with a warning, and
the other rows go to Firefly. It still makes no request while any row of the
group has no journal id at all, because a request that does not name a split
makes Firefly delete that split.

Deviation from the review: a tombstone row does not get a journal id. A
tombstone stands for a split that the server no longer holds, thus each id that
a live split could give belongs to a different split.

### Keep each push that failed, and stop the extra cycle

Items 10 and 17. `_FireflyPushBacklog` records the modification time of each
row that a cycle did not send. The watermark moves to the oldest of those times
in place of the start time of the cycle, thus the next cycle offers the row
again. Each skip and each failure in the push and the delete paths records the
row.

`scheduleFireflyPush` no longer starts a second cycle for the writes of the
engine itself.

### Stop the destructive delete paths

Items 11 and 15. A wallet that the user deletes in this app is unlinked: the
map row gets a tombstone and the Firefly account stays. `DELETE` on a Firefly
account destroys each transaction of that account and each other split of the
groups that hold them. The transactions that the app deletes together with the
wallet are recognised by the Firefly ids that the first pass collects, and are
unlinked in place of a remote delete.

A category that the user deletes on Firefly now goes through
`database.deleteCategory`, thus the subcategories and the filters of the
budgets and the objectives stay correct.

### Send only the rows that are paid

Item 12. Firefly has no state for a payment that is expected but not made, thus
a row that is not paid is not sent. Both sides of a transfer must be paid. A
row that goes from not paid to paid has no link and is created. A row that goes
from paid to not paid is removed from Firefly.

Deviation from the review: that removal deletes the map row, it does not write
a tombstone. A tombstone stops each later sync of the row, and the row is
expected to come back when the user marks it paid again.

### Read the live record before each push

Item 13. `_pushCategories`, `_pushAccounts`, `_pushTransactions`,
`_pushExistingMultiSplitGroup` and `_pushTransfer` read the record from Firefly
before the direction test, thus a remote change that came after the last sync
is visible. The account read also gives the account role, which the local
database does not hold: an update that does not send the role changes a savings
account or a credit card into a plain asset account.

### Clear the links when the host changes

Item 14. `fireflyForgetSyncState()` deletes each map row and each balance
anchor, and clears the last-sync time. The settings page calls it, together
with `clearFireflyPat()`, when the host in the field is not the host that the
saved token and the saved links belong to. A token is a secret of one server,
and an id is correct for one server only. `_hasCredentials()` refuses a stored
token whose host no longer matches, thus the check happens before the dialog of
the Google Drive exclusion changes anything.

### Take the future rows out of the balance anchor

Item 16. `getSumOfWalletExcludingTransaction` takes `notLaterThan`, and the
anchor uses the end of today. Firefly reports a balance that holds no journal
with a later date, thus the local sum must hold none either; a journal dated
later today is in the Firefly balance, thus it is in the local sum too.

### Smaller items

Item 18. `FireflySyncMap` has an index on `(entity_type, firefly_id)` from
schema 50; `onCreate` and the upgrade from 49 both make it, and
`test/database/migration_test.dart` asserts it on each path. The API client
sends `User-Agent: Cashew-FireflySync`, in place of `Dart/3.3 (dart:io)`.

### Close the twelve findings of the adversarial review

Two agents read the branch against a written brief (OpenCode, Cursor), and a
third pass ran next to them. Twelve findings stayed after the triage. Each one
is now closed.

**1. A delete of one record destroyed a full Firefly group.** `_pushDeletes`
called `deleteTransaction` on the group when this app held no other row of it.
The rows of this app do not say how many splits the group holds: a split that
the app never imported, or that it skipped, has no local row.
`_removeSplitFromRemoteGroup` now runs for each transaction delete, thus the
live group is read first. It gives true when the full group went, and the
caller then records the group id and gives the transfer warning.

**2. The account-delete protection was empty on a retry cycle.** The first pass
of `_pushDeletes` left `unlinkedAccountIds` empty when a cycle before it had
already closed the link of the wallet. The transactions of that account then
took the delete path. The id now goes into the set on each cycle, and the
tombstone stops the warning only.

**3. A same-length reshape could put a remote change on the wrong record.**
`fireflyPositionMatchIsSafe` compared counts only. It now also asks that the
group still holds each split that a row names by id, that each such split is at
the position that the row holds, and that a row with no id points at a split
that no other row names. Eight tests cover it. A group that Firefly reshaped
and kept at the same length, and that moved no split that a row names, is still
undetectable from the group alone; the comment on the function says so.

**4. A split that Firefly removed left a local record with a link for ever.**
`_applyRemoteDeletes` asks whether a GROUP is on the server, thus it cannot see
a split that went from a group that stays. `_unlinkRowsOfRemovedSplits` runs
after the split loop of each pulled group and removes the local row of each map
row that names a journal id that the group no longer holds. A row that has no
journal id is not touched: its position gives no proof.

**5. A tombstone of a position hid a live split for ever.** A tombstone that
holds a position only counted against a split that HAS an id, in front of the
backfill and in front of the warning. The app made no record for that split and
gave no message. The position now counts only for a split that the server did
not name.

**6. The repair that the ambiguity warning names did not exist.**
`fireflyForgetSyncState()` ran on a change of host only, thus "disconnect
Firefly and connect it again" did nothing. The settings page now has a "Reset
Firefly links" action with a dialog that says what happens. To turn the sync
off must not clear the links: the pull makes a new record for each remote split
that no link names, thus the user would get each transaction two times.

**7. A split with no journal id stopped the full cycle.**
`_pushExistingMultiSplitGroup` read the id of each split of the live group with
`!`. A group where Firefly gives a split with no id thus threw, and each later
cycle threw again. The group is now tested first, and the push waits.

**8. A transfer with one side only stopped the cycle.** `_pushTransfer` read
the paired row with `!`. It now warns and holds the row for a later cycle.

**9. A subcategory held the watermark for ever.** `_pushCategories` called
`recordNotPushed` for a subcategory, which no cycle can send, thus the
watermark never moved past it. It is now counted and skipped.

**10. Each push of a transfer blanked the position.** The four upserts of
`_pushTransfer` gave no `fireflySplitIndex`, and `insertOrReplace` thus reset it
to 0. `_splitIndexAfterUpdate` reads the position from the answer of the server.

**11. A pair of rows that pointed at two Firefly groups made a copy.**
`_pushTransfer` wrote both rows onto one group and left the other group on the
server with no local row, and the next pull imported it again. The app now
makes no request and tells the user.

**12. A v47 install kept a `firefly_sync_map` with no unique key.** The dedup
and the unique index sat in the `from == 47` block, thus a database that a
build before this one moved to v48 or v49 never got them. `_upsertSyncMap`
writes with `InsertMode.insertOrReplace` and needs that key, or each sync adds
one more row for the same entity. The block is now guarded at `from >= 47 &&
from <= 49`, and it has its own try/catch.

### Earlier

- CI is green and merged (`671f0b05` / `1720fd2d`): both workflows pinned to
  Flutter 3.19.6, the `intl` bump reverted, stock `widget_test.dart` replaced
  with `test/functions_test.dart`.
- The Firefly code has now been compiled for the first time. Eight type errors
  were found and fixed in `4bc23b77` - the settings page importing the API
  client rather than the models, a missing `drift` import in the mapper, a
  `show` clause that hid drift's `BooleanExpressionOperators` extension (so `&`
  on `Expression<bool>` was undefined), and a null-promotion failure.
- `fireflyMapperTest.dart` -> `firefly_mapper_test.dart` (`18c5fc0e`). It had
  never run anywhere: `flutter test` only discovers `*_test.dart`.
- `tables.g.dart` was stale, generated by an older `drift_dev`. Regenerated on
  its own in `c5df6d3b` so toolchain churn stays out of the schema diff.
- `.github/workflows/firebase-hosting-pull-request.yml` disabled - it ran
  `npm ci` against a repo with no `package.json`.

---

## Outstanding

### 1. Engine-level tests: started, not complete

`test/firefly/firefly_test_env.dart` gives an engine test a fake Firefly on
the loopback interface and an in-memory database, and the two push test files
use it. The pull path, the transfer path, the multi-split group and the delete
paths have no engine test yet; the findings 1-4 of the review are still
covered by the mapper suite only.

The mapper suite covers `fireflyPositionMatchIsSafe`,
`matchSplitToSyncMaps` with no position match, the journal id in
`toRequestJson`, `FireflyTransactionSplit.unchangedSplit` and
`fireflyLocalRowChanged`.

### 2. A pure `reconcileGroup()` is not written

`FIREFLY_SYNC_FINDINGS.md` section 2.5 asks for one pure function that takes a
remote group and its map rows and gives the actions, in place of the reads and
the writes that the pull loop makes for each split. It is a change of shape,
not a defect: each defect that it was to prevent is closed. It stays open, and
it is the natural first step for the engine tests above.

### 3. Position matching is still in the code

The review asks for a one-time repair of the rows that hold no journal id, by a
match on the content of the split, and for the removal of the position branch
after it. This branch takes the safer part only: the position branch stays for
the rows that have no id, behind the guard of
`fireflyPositionMatchIsSafe`, and each pull writes the id on each row that it
matches. A group that the guard cannot resolve waits for "Reset Firefly links".
No row is repaired by a guess.

The guard now tests the shape of the group, not the count alone. One case is
left: a group that Firefly reshaped and kept at the same length, and that moved
no split that a row names by id, passes the guard. That needs a change of two
splits between two syncs of an install that came from a build before the
journal-id column, because the first pull after that build gives each row its
id. To remove the branch closes it; to remove it also makes a second local copy
of each split of each group that still holds such a row, which is worse.

### 4. The migration steps are still hand-rolled

Generate `drift_schemas/drift_schema_v47.json`, `v48.json`, `v49.json` and
`v50.json`, regenerate `schema_versions.dart`, convert the blocks in
`onUpgrade` into `from46To47` ... `from49To50` steps, and raise
`_lastGeneratedMigrationSchema`. Out of scope on this branch by choice; the
hand-rolled blocks are tested from v46, v47, v48 and v49.

Upstream gap, not ours: the generated switch has no case below 33, thus an
install older than v33 still throws. Worth confirming that such installs exist
before it takes any work.

### 5. A live round trip is not done

Nothing on this branch has run against a Firefly server. The contract of the
PUT comes from the documentation and from `GroupUpdateService.php`, not from a
request. Run the manual plan of `FIREFLY_SYNC_FUTURE_SCOPE.md` against a pinned
`fireflyiii/core` tag.

### 6. The tests now run, on the toolchain that CI pins

The local Flutter is 3.47.2, which cannot resolve `intl ^0.18.1` against
`easy_localization`. Flutter 3.19.6, the version that CI pins, is a git
checkout on the test box `fly@167.235.51.86` (`~/flutter3196`, on PATH), and a
copy of the branch in `~/firefly-review` there gives:

- `flutter test`: 81 tests, all pass. This holds the migration tests
  from v46, v47, v48 and v49, the mapper suite and the engine tests.
- `flutter analyze --no-fatal-infos --no-fatal-warnings`: 0 errors and 0
  warnings outside the vendored `packages/sliding_sheet` copy.
- The box has `libsqlite3.so.0` and no sudo, thus the test environment opens
  that name when `libsqlite3.so` is not there.

A live round trip against a Firefly server is still not done; that is item 5.

### 7. Branch cleanup

The four local branches are deleted. Two remote ones are left, both with trees
identical to `origin/main` (`git diff origin/main origin/<branch>` is empty),
thus neither holds work that is not merged. Blocked on a permission prompt,
needs a hand:

```
git push origin --delete fix/ci-flutter-version fix/disable-firebase-workflow
```

### 8. PR #5 (`fix/ci-artifact-names`) is open and awaits review

It names the build artifacts after `github.event.pull_request.head.sha` in
place of `github.sha`, which on a `pull_request` event is a merge commit that
the repository does not hold.

### 9. The Firefly account of a transfer is not read back

`fireflySplitToTransferPair` puts the foreign amount on the destination row
when the foreign currency is the currency of the destination wallet. The
currency of the wallet is the local one; the engine does not compare it with
the currency that Firefly holds for that account. Two accounts that hold the
same currency in Firefly but not in the app therefore still put the source
amount on the destination row. A pull that reads `currency_code` per account
would close it.

### 10. "Linked accounts" shows the local accounts only

The picker in the Firefly settings lists each local account and lets the user
name its Firefly account. It does not show a Firefly asset account that no
local account holds, thus a user cannot make a local account from it there.
The pull makes one by itself on the next cycle, which is why this is a comfort
item and not a defect.

---

## What the Firefly documentation gave

From `github.com/firefly-iii/docs`, read with `gh` because the rendered site
refuses `curl` and WebFetch:

- A split of a group must go into a PUT with its `transaction_journal_id`, also
  when nothing in it changes. A split that the request does not name is
  deleted. A changed split with no id makes a new split, and the old one is
  deleted.
- A group with one journal is updated in place, and it ignores a submitted id.
- `DELETE /v1/transaction-journals/{id}` removes one split. It leaves an empty
  group when it removes the last journal of that group, thus the app uses the
  group delete for a group with one split.
- An unknown journal id gives 401, not 404. The app thus makes sure that a
  stored id is in the live group before it sends a delete, because a 401 reads
  as a token that is not valid.
- `DELETE /accounts/{id}` destroys each journal of that account, and the full
  group of each of those journals. This is why a local wallet delete unlinks
  only.
- Firefly holds no state for a payment that is expected but not made. The
  Firefly model for that is a bill or a recurring transaction, and both are
  deferred in `FIREFLY_SYNC_FUTURE_SCOPE.md`.
- Firefly applies no rate limit of its own. The 429 path of the client stays
  for a reverse proxy in front of it.

## Decisions taken

- Item 11: a local wallet delete unlinks only; the Firefly account stays.
- Item 12: only a row with `paid == true` goes to Firefly.
- Item 14: a change of host clears the token and each link, because a token is
  a secret of one server and an id is correct for one server only.
- Comments: the code keeps a comment that records a constraint of Firefly or of
  the local database; a comment that repeats the code is deleted. The comments,
  the reports and this file follow ASD-STE100 Simplified Technical English.
