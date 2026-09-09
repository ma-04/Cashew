# Firefly III Sync — Findings

Date: 2026-09-08, revised 2026-09-09. Branch: `feature/firefly-iii-sync`
(HEAD `e46aef13`; originally written against `367105fe`).
Scope: `budget/lib/struct/firefly/`, `budget/lib/database/tables.dart`,
`budget/lib/database/schema_versions.dart`, `budget/test/firefly/`.
Companion: `budget/todo.md`. This file verified that file's items against the
code and proposes the better fix. todo.md has since absorbed the verification
results and carries the current status of every item, including a second round
of findings (10-18) not covered here; where the two overlap, todo.md wins.

## Status, 2026-09-09 (second revision)

A second review ran on 2026-09-09, after the fixes below. Two agents read the
branch against a written brief, and a third pass ran next to them. It gave
twelve findings, of which three are in this file's own answers: the count-only
guard of item 1, the group-level reconciliation that item 4 did not reach, and
the tombstone precedence of item 2. All twelve are closed. The write-up is in
`todo.md`, section "Close the twelve findings of the adversarial review", which
carries the current state.

## Status, 2026-09-09

Section 0 records the code as it was at `e46aef13`. It stays as written, as the
record of the review. Each item of it is now closed, but for the parts that
this list names:

| Item | State |
| --- | --- |
| 0 migration blocker | Fixed. Tested from v46, v47, v48, v49. |
| 1 position match | Fixed by a guard on the shape of the group, not by a repair of the rows. |
| 2 tombstone index | Fixed. A tombstone row does not get an id; see below. |
| 3 stale journal id | Fixed. Each push reads the id from the response. |
| 4 backfill behind exits | Fixed. The write is in front of each exit. |
| 5 PUT contract | Answered, and the code follows it. |
| 6 count-mismatch refusal | Now unlink-and-push, for a row that has an id. |
| 7 test gaps | Open. The suite is still mapper-level. |
| 8, 9 branches and PR #5 | Open. Both need a hand. |

Two deviations from what section 2 asks for:

- A tombstone row does not get a journal id. A tombstone stands for a split
  that the server no longer holds, thus each id that a live split could give
  belongs to a different split.
- No row is repaired by a match on content. A group that the guard cannot
  resolve is not matched and not imported: it gets one warning that names the
  repair, and the user runs "Reset Firefly links" to rebuild them. To guess
  which local record is which split can put a remote change on the wrong
  record, and that is the failure that this branch set out to remove.

## 0. Verification of `todo.md` items

### 0 — BLOCKER: upgrade from an existing install fails to open the database. CONFIRMED, NOW FIXED.

Fixed in `e46aef13`; the write-up lives in todo.md's Done section.
`onUpgrade` asked the generated `migrationSteps()` to step to `to` (49) while
`drift_schemas/` stops at v46, so every upgrade threw
`ArgumentError("Unknown migration from N")` outside any try/catch, before the
hand-rolled Firefly blocks could run. Fresh installs worked via `onCreate`,
which is why it went unnoticed. `to` is now clamped to
`_lastGeneratedMigrationSchema`, and `test/database/migration_test.dart`
upgrades a real on-disk database from v46, v47 and v48.

Still outstanding, tracked in todo.md: generate `drift_schema_v47.json`,
`v48.json` and `v49.json`, regenerate `schema_versions.dart`, and convert the
hand-rolled blocks into real `from46To47` / `from47To48` / `from48To49` steps.

### 1 — Position fallback can mismatch once, backfill cements it. CONFIRMED.

- Non-transfer pull at `fireflySyncEngine.dart:787-805` backfills
  `fireflyJournalId` on the first position match, before the direction check.
- If that first pull coincides with a mid-journal remote delete, the wrong id
  is stored and identity matching then defends the wrong pairing permanently.
- The existing "middle split deleted" test only uses rows that already carry
  journal ids, so it does not cover this path.

### 2 — Tombstone index matching reintroduces the position bug. CONFIRMED (two defects).

- `fireflySyncEngine.dart:693-695`: the skip condition is
  `tombstonedSplitIndexes.contains(splitIndex) || journalId-match`. The index
  set is consulted outright, not as a fallback, so a live split that merely
  reuses an old index is skipped.
- Tombstoned splits `continue` before any backfill runs, and
  `matchSplitToSyncMap` is only called for non-tombstone rows, so a
  pre-column tombstone keeps `fireflyJournalId == null` forever.

### 3 — Push paths store a stale journal id. CONFIRMED (3 sites), but not equally severe.

- `_pushTransactions` (`:1533-1543`), `_pushExistingMultiSplitGroup`
  (`:1670-1680`), `_removeSplitFromRemoteGroup` (`:2019-2028`) all write
  `fireflyJournalId: map.fireflyJournalId` (the value already stored).
- Only `_pushTransfer` (`:1810-1815`) prefers the PUT response's id with a
  stored-value fallback.
- `toRequestJson()` (`fireflyModels.dart:171-194`) never sends
  `transaction_journal_id`, and `_splitForMappedLocalRow` (`:1549`) builds
  id-less splits, so a multi-split PUT destroys and recreates every journal in
  the group. Stored ids go stale, `_matchesSplit` then refuses the position
  fallback (the row *has* an id), finds no match, and inserts duplicates.
- Correction to the original text, from item 5: this is **not** uniform.
  `_pushTransactions` only ever pushes a group it holds a single split for,
  and Firefly updates a single-split group in place, keeping the journal id.
  It is not exposed to the churn - it merely misses a free backfill from a
  response it already holds. The other two sites are the real damage.

### 4 — Backfill skipped by early exits. CONFIRMED.

- Transfer path: `_pullTransferSplit:914-916` (`first == null`) returns before
  the `937-952` backfill; `:860-862` (`sourcePk/destPk == null`) likewise.
- Non-transfer path: the unmapped-wallet skip (`:728-737`) plus the
  type-skip and balance-correction `continue`s all run before the `:787`
  backfill.
- Rows behind any of these stay position-matched indefinitely (exposed to 1).

### 5 — Whether PUT honours `transaction_journal_id`. ANSWERED, FROM DOCS AND SOURCE.

The full answer, with quotes, is todo.md item 5. In short, the
["API special endpoints" doc](https://docs.firefly-iii.org/references/firefly-iii/api/specials/)
(readable via the `firefly-iii/docs` repo, since the rendered site refuses
WebFetch and curl alike) states the PUT contract for *split* transactions:

- Every split should carry its `transaction_journal_id`, even unchanged ones
  (send id-only `{"transaction_journal_id": N}`).
- A split omitted from the PUT **is deleted**.
- A changed split submitted **without** its id is created anew; the old one
  is deleted.

`GroupUpdateService.php` agrees and adds what the docs omit: a single
submitted transaction against a single-journal group is updated in place,
returning before the delete pass, with any submitted id ignored. Two
consequences the original text did not draw:

- Sending `transaction_journal_id` unconditionally is safe, so no split-count
  branching is needed in `toRequestJson()`.
- It is only safe while the stored ids are *correct*: `find()` is scoped to the
  group and returns null rather than erroring, so a stale or foreign id
  silently creates a new split and destroys the original. That makes the
  legacy repair a **prerequisite** of the PUT change, which reverses the order
  originally suggested in section 3 below.

A live round-trip against a pinned `fireflyiii/core` tag is still worth doing,
but nothing here is guesswork any more.

### 6/7/8/9. AGREED.

- 6: the count-mismatch refusal in `_pushExistingMultiSplitGroup` must stay
  until items 1–2 are fixed; afterwards it can become tombstone-and-allow.
  todo.md item 10 adds that the refusal currently loses the edit outright.
- 7: the suite in `test/firefly/firefly_mapper_test.dart` is mapper-level
  only, so findings 1–4 were unreachable by it; several tests pass under both
  position and identity matching.
- 8: since verified. The four local branches are deleted; `fix/ci-flutter-version`
  and `fix/disable-firebase-workflow` are still on origin, both with trees
  identical to `origin/main`.
- 9: PR #5 (`fix/ci-artifact-names`) is still open.

## 1. Why the filed fixes are band-aids

Items 1–4 accept the premise "PUTs recreate journals, so pull must cope with
churning ids plus legacy null-id rows via position fallback + perpetual
backfill" (count guard, tombstone condition ordering, hoisting backfill,
response-id propagation). That leaves a permanently dual-identity system in
which every new early-exit or push site can reintroduce the bug — which is
exactly the history items 2 and 4 describe.

## 2. Better solution: stabilise journals, then delete position matching

1. **Send `transaction_journal_id` on every PUT; include untouched splits
   id-only.** Add the field to `toRequestJson()` (emit when non-null), thread
   it through `_splitForMappedLocalRow`, and send id-only placeholders for
   siblings not being edited, per the docs. Firefly then preserves ids across
   rewrites; pushes stop churning identity and item 3 disappears at the
   source. Response-id handling stays as a sanity check only.
2. **Delete splits via `DELETE /v1/transaction-journals/{id}`, not group
   rewrite.** The API exposes per-split delete
   (`DestroyController@destroyJournal`). `_removeSplitFromRemoteGroup`
   (`:1966-2032`, including the `fireflySplitIndex: i` renumbering that
   assumes order preservation) collapses to one call — no completeness check,
   no sibling rebuild, no index shifting. Its comment at `:2011-2015`, that
   "Firefly keeps them across the rewrite", is false and goes with it.
3. **One-time legacy repair, then remove the position branch entirely.**
   Resolve null-`fireflyJournalId` rows once, deterministically: match within
   group by content fingerprint (amount/date/description/counterparty); where
   ambiguous, quarantine the group (delete its local rows, re-pull clean)
   rather than guess. Then delete `_matchesSplit`'s position branch, the
   count guard, and all backfill code. `fireflySplitIndex` returns to pure
   ordering. Kills the root cause of items 1, 4, 7.
4. **Tombstones keyed by `(fireflyId, fireflyJournalId)` only.** An "old
   index 1" tombstone is meaningless after renumbering; null-id tombstones
   pre-dating the repair are unrecoverable by index and should retire with
   the repair in (3).
5. **Enforce identity in the DB; extract a pure reconciler.** Add an index on
   `(entityType, fireflyId, fireflyJournalId)` — non-unique, since transfer
   pairs share one journal across two `localPk`s — keep
   `(entityType, localPk)` unique (it already is, as of schema 48). Replace
   the scattered per-split DB reads/writes with one pure
   `reconcileGroup(remoteGroup, maps) -> actions` function so engine behaviour
   becomes unit-testable (item 7's gap). This also closes todo.md item 18's
   missing `(entityType, fireflyId)` index.

## 3. Order taken

1. Legacy rows first, as item 5 requires: the pull writes the journal id on
   each row that it matches, and the count guard stops a match that the
   positions cannot support. Done.
2. PUT identity: each split of a group goes into the request with its id, and
   an untouched split goes as the id alone. Done.
3. One `DELETE /v1/transaction-journals/{id}` for a split, and the group delete
   for a group with one split. Done.
4. The index on `(entity_type, firefly_id)`, from schema 50. Done.

Left, in the order to take:

1. The pure `reconcileGroup()` of section 2.5, and the engine tests that it
   makes possible. The pull loop still reads and writes for each split.
2. The removal of the position branch. It needs the repair of section 2.3,
   which this branch does not take: a group that the guard cannot resolve waits
   for the user in place of a guess.
3. The snapshots of the schema, and the hand-rolled blocks as generated steps.
4. A live round trip against a pinned `fireflyiii/core` tag.

todo.md items 10-18 (a push that the watermark loses, a wallet delete that
destroys remote history, rows that are not paid, the conflict test of the push,
the links after a change of host, the balance anchor, the extra cycle) are
independent of the identity work. Each of them is closed; todo.md carries the
write-up.
