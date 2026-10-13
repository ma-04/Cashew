# Firefly client: plan for the rework

Branch `feature/firefly-client`, cut from `feature/firefly-iii-sync` at `ab58f372`
on 2026-10-13. Target: Firefly III 6.7.9, API `/api/v1`.

Goal: Cashew is a mobile client of Firefly III with nearly full backend
compatibility, and Cashew never skews data on the Firefly side.

Owner decisions (2026-10-13):

- Firefly is the source of truth. The Cashew database is a cache of it.
- Scope beyond accounts, transactions and categories: budgets, bills and
  recurring transactions, tags and piggy banks, liabilities and multi-split
  groups.
- Integration tests run against a real Firefly 6.7.9 in Docker on the build
  server. The live server `money.onku.dev` is never used by tests or agents.
- No hotfix on the old branch; every fix goes into this rework.

The current engine is described in `FIREFLY_SYNC_SPEC.md`. Its notes are in
`todo.md` and `FIREFLY_SYNC_FINDINGS.md`.

## 1. Why the conflict model changes

The old engine is a two-way peer sync: the newer timestamp wins. Most of its
20 commits fix skew or duplicates that this design causes (position matching,
lost creates, currency rebooking, moved rows, pre-link history). Two items
were left open because no timestamp rule can solve them: the account PUT burst
after a reorder, and the edit in the same second as the watermark.

"Never skew Firefly" needs a different rule: **Cashew sends only the fields
that the user changed, and only when the server has not changed the same
field since Cashew last read it.** Everything else comes from the server.

## 2. What the audit of 2026-10-13 found

Tests: 117 pass on Flutter 3.19.6; `flutter analyze` has 0 errors. Verified
against the Firefly source at v6.7.9.

What is correct and stays: a transaction PUT keeps every key it does not send
(`UpdateRequest.php:398`, `JournalUpdateService` gates each field with
`array_key_exists`); an account PUT does not touch opening balance, IBAN,
virtual balance, notes, order or liability fields; opening balance and
reconciliation journals are never edited; no account DELETE is sent; split
deletes go through `/transaction-journals/{id}` after a read of the live group;
pagination refuses partial data; requests time out after 30 s.

Skew found in the old engine. Each item is a rule of the new one, with a test
against the real server:

| # | Severity | Fault | Rule in the rework |
| --- | --- | --- | --- |
| 1 | Critical | `toIso8601String()` of a local `DateTime` has no offset; Firefly reads it in `app.timezone` (UTC). Every push of an edited row moves its time by the phone's UTC offset | An unchanged date is not sent. A changed date is sent in UTC with `Z` |
| 2 | High | Liability accounts are not loaded as counterparties; a loan payment falls back to the Cash account on push | Load every account type. An unchanged counterparty is not sent |
| 3 | High | `external_id` is sent on every PUT and replaces the importer's id | `external_id` only on create |
| 4 | High | Category delete removes local rows (each becomes a remote DELETE); category merge moves only the sync window | Category delete = Firefly semantics (rows become uncategorized). Merge works on full history or is blocked |
| 5 | High | `reconciled` is never read or sent, so a reconciled journal can be changed and stays reconciled | Pull `reconciled`; a reconciled row is read-only in Cashew |
| 6 | Medium-high | Account PUT sends `currency_code` from the wallet and can change the account currency | An account PUT never sends the currency |
| 7 | Medium-high | Moving or merging wallets converts amounts with Cashew rates and moves only the window | Blocked in Firefly mode until it can be an explicit server operation |
| 8 | Medium | Marking a row unpaid deletes the remote journal with its tags, budget, bill and attachments | A row that Firefly holds cannot be marked unpaid; unpaid stays local planning only |
| 9 | Medium | A manual balance correction (category "0") is pushed as spending and creates a category on Firefly | Category "0" rows are never pushed |
| 10 | Medium | Amounts are sent with 2 decimals and pulled with `decimals: 2` | An unchanged amount is not sent; a changed one uses the currency's `decimal_places` |
| 11 | Low-medium | `apply_rules` and `fire_webhooks` default to true on update | Send `apply_rules: false` on update; re-read after each write anyway |
| 12 | Low | Seconds forced to :30/:31 on transfers, category PUT on every transaction save, cleared notes and categories not cleared remotely, stale foreign amount | Field diff: a cleared field is sent as cleared, an untouched field is not sent |
| 13 | Broken | Multi-split PUT without `group_title` gets 422 | Send the group title of the live group |
| 14 | Broken | Rename of a `ccAsset` account gets 422 (credit card fields required with the role) | Send the role only when it changes, with its required fields |
| 15 | Broken | A sign flip sends `type: deposit` with an expense source; Firefly changes the amount but not the type | A type change sends type, source and destination together, or is blocked |

The fake Firefly of the test suite could not see items 1, 5, 9, 13 and 14.
This is why the real server comes first.

## 2a. Test server, and what it showed

A disposable Firefly III 6.7.9 (`fireflyiii/core:version-6.7.9`, SQLite) runs
in Docker on the build server `fly@167.235.51.86`, in `~/firefly-test`, bound
to `127.0.0.1:18080` only. No token is in git.

- `./reset.sh && . ./env.sh`: a clean instance in about 0.4 s; exports
  `FIREFLY_LIVE_URL` and `FIREFLY_LIVE_TOKEN`.
- `./bootstrap.sh`: a new volume, user, token and snapshot (about 27 s).
- `docker compose up -d` / `docker compose down`.
- `tool/firefly_remote_test.sh [flutter test args]` rsyncs the repo to
  `~/firefly-review` and runs the tests there with the live variables set;
  `--analyze` runs the analyzer. The tests tagged `live` skip when
  `FIREFLY_LIVE_URL` is not set. The build server's own time zone is
  Asia/Dhaka (+06), which exercises the date rules.

Facts read from the server (2026-10-13):

- A date with an offset is stored as that instant in UTC; a date with no
  offset is read in the server time zone. `Z` is accepted.
- Amounts keep the precision sent (`10.123` stays `10.123000000000`, also for
  a 2-decimal currency).
- `current_balance` includes `virtual_balance`.
- `category_id: null` clears the category; `notes: ""` clears the notes.
- `/search/transactions?query=updated_at_after:YYYY-MM-DD` returns full
  groups with pagination. With a time in the value it returns 0 records and
  no error; `updated_after:` also returns 0. `external_id_is:` works.
- A PUT of a group with more than one split and no `group_title` gets 422.
- An account PUT of `{"name": ...}` keeps the role; a PUT that sends
  `account_role: ccAsset` without the card fields gets 422.
- A withdrawal to a loan has `destination_type: "Loan"`. Liability opening
  balances come back as `opening balance`.
- Categories have `color` and `notes`. The asset account list includes
  inactive accounts.

Facts for phase B (2026-10-13):

- A transaction PUT with `tags: [...]` replaces the tags; `tags: []` clears
  them. A tag that does not exist is made, also "Parent/Child".
- `destination_name` (withdrawal) or `source_name` (deposit) finds the
  expense or revenue account of that name, or makes one. It never finds a
  liability or an asset account: the name "Car loan" makes an expense
  account "Car loan". An empty name or a null id puts the split on the cash
  account.
- Liabilities (`type=liabilities`): a withdrawal can go from a liability to
  an expense account and from an asset account to a liability; a deposit can
  go from a revenue account or a liability. A transfer between an asset
  account and a liability gets 422; a transfer between two liabilities is
  accepted. `current_balance` of a liability is the sum of its flows, like an
  asset account (a payment of 100 into a credit loan gives 100.00).
  `liability_amount` on a create made no opening transaction.
- An account PUT of `{"name"}` or `{"active": false}` on a liability keeps
  its liability fields. `account_role` can be changed by a PUT.

## 3. Architecture

Keep: `fireflyApiClient.dart`, most of `fireflyMapper.dart` and
`fireflyModels.dart`, journal-id identity, delete confirmed by 404, the
`external_id` lost-create recovery, the Google Drive exclusion. Replace: the
engine's conflict model, its push path and its pull apply step.

### 3.1 Snapshot per mirrored row

`FireflySyncMap` gets a column `remoteSnapshot` (JSON text): the last server
version of the record as Cashew read it, with `updated_at`. For a split it
holds the split object plus the group id, group title and journal id. This
snapshot is the base of every diff and the passthrough of every field that
Cashew has no column for.

### 3.2 Outbox

New table `FireflyOutbox`: `opPk`, `entityType`, `localPk`, `kind`
(create / update / delete), `state` (pending / sending / failed / done),
`attempts`, `lastError`, `createdAt`. One open operation per entity; a new
edit coalesces into it.

- Operations are queued by the database write methods (`createOrUpdate*`,
  `delete*`, batch methods) when Firefly is on and the write did not come from
  the engine. A scan by `dateTimeModified` runs as a backstop, so a write
  path that is missed still gets an operation.
- The payload is computed at send time, as a diff of the local row against
  `remoteSnapshot`. No changed Cashew-modelled field = no request.
- Before an update: GET the live record. For each field in the local diff,
  if the live value differs from the snapshot, the server changed it too:
  the server value wins and the user is told. The remaining fields go out.
- After each write: re-read the record, overwrite the local row and the
  snapshot.
- A 422 marks the operation failed and visible in the settings page. The
  local row returns to the server state. Nothing is retried with a guessed fix.
- Creates carry `external_id` = local key and `error_if_duplicate_hash`.

### 3.3 Pull

- First connect: full history. Opening balance, reconciliation and liability
  credit rows are imported read-only, so local sums equal Firefly balances and
  the balance-anchor row goes away. A check compares each wallet sum with the
  account's `current_balance` and reports drift.
- Later: changes since the last pull through
  `/search/transactions?query=updated_at_after:<date>` (to verify on the real
  server), plus an id sweep to find deletes.
- Server wins: a pulled record overwrites the local row and the snapshot.
  Exception: a row with an open operation keeps the local edit; the outbox
  merges it at send time (3.2).
- Cashew-only columns (icon, colour, subcategory, wallet display settings)
  survive a server overwrite.

### 3.4 Read-only and blocked in Firefly mode

Read-only rows: reconciled journals, opening balance, reconciliation,
liability credit, multi-split groups (until the split editor exists), bills,
recurrences, available budgets. Blocked actions: wallet move and merge, wallet
delete, marking a Firefly row unpaid. These need owner decisions, see 5.

## 3a. State of phase A (2026-10-13)

Done, with tests against Firefly 6.7.9:

- Snapshot and outbox (schema 51); field-diff push with a three-way merge;
  server-wins pull; full first pull; incremental pull through
  `updated_at_after:`; deletes found in a 62-day range on each pull and in
  the full history once a day and on "Sync all history".
- Rebuild from Firefly after a backup (`VACUUM INTO`), only on the user's
  confirm; an automatic cycle on a phone from the two-way sync stops with a
  message. The rebuild keeps Cashew-only columns of linked records, removes
  the balance anchors and the paid local rows that Firefly does not have, and
  writes nothing to the server.
- Opening balances, reconciliations (read with `type=all`) and reconciled
  journals are read-only. A Firefly row cannot be marked unpaid. Balance
  corrections and unpaid planning rows stay local.
- Every rule of table 2. A new withdrawal or deposit in "generic" payee mode
  names no other account, thus Firefly books it on its own cash account.
- Category colour in the notes of the Firefly category: a "color: #rrggbb"
  label or a bare "#rrggbb" is read; a colour changed in Cashew replaces
  only the hex digits (or adds a "color: #rrggbb" line). A rename does not
  touch the notes. The `color` field of Firefly 6 is read when the notes have
  no colour, and is never written.
- A record that changed in the same second as the last write of the client
  is still pulled: the pull compares the fields too, not only `updated_at`.
- Category delete (server first, rows uncategorized), category merge
  (moves, then the delete), wallet delete (account inactive, history kept),
  wallet merge refused between two currencies.
- A balance check after each pull: the wallet sum against current_balance,
  within the rounding of the currency.

Not done in phase A:

- Edits of a multi-split group work one split at a time; there is no split
  editor, and a new multi-split group cannot be made here.
- The UI does not stop an edit of a read-only row; the push undoes it and
  says so.

## 3b. State of phase B (2026-10-13)

Done, with tests against Firefly 6.7.9 (schema 52):

- `Transactions.payee`: the name of the expense account of a withdrawal or
  the revenue account of a deposit; null is the cash account. A change sends
  the name only; a payee change on a split whose other account is a
  liability or an asset account is undone (a name cannot find such an
  account). A new row with a payee names it; with no payee it names no other
  account (or the category, in "category" naming mode).
- `Transactions.tags`: the tags, sent as the full list when they change.
- A subcategory is the tag "Parent/Child" (the name of the category, a
  slash, the name of the subcategory). The pull makes the local subcategory
  when it does not exist. A local subcategory that was never on Firefly
  stays, and its tag goes with the next change of the row; a tag removed on
  Firefly removes the subcategory.
- `Wallets.archived`: an inactive Firefly account is hidden in the wallet
  lists; its history stays.
- Liabilities are wallets (`Wallets.accountKind` = loan, debt or mortgage).
  A split between two wallets is two local rows (a transfer pair) whatever
  its Firefly type; a new pair is a transfer between two asset accounts or
  two liabilities, a withdrawal from an asset account to a liability, and a
  deposit from a liability to an asset account.
- Fixed: the create of a transfer from Cashew sent `source_id: "null"`.

Not done in phase B:

- A rename of a subcategory does not rename its tag on Firefly; the next
  pull of a row with the old tag makes a subcategory of the old name again.
- Foreign amounts of withdrawals and deposits are kept on the server but not
  shown or edited here.
- The asset role is kept but cannot be changed here.

- UI: payee and tags fields on the transaction page (Firefly mode); a
  read-only row shows a lock and cannot be saved or deleted; a mirrored row
  cannot be marked unpaid; archived wallets are hidden in the wallet lists
  and pickers (the edit wallets page shows them as inactive). Bulk delete and
  bulk actions are not blocked; the engine undoes them.
- Upgrade: client version 1 fills payee, tags, archived and account kind from
  the snapshots before any push, then reads the full history once.

## 3c. State of phase C (2026-10-13)

Facts: a split `budget_id` of `null` or `"0"` clears the budget; Firefly
drops a budget given on a deposit. `/budgets/{id}/limits?start=&end=` gives
the limit of a period; an auto budget makes its limit itself. A piggy bank
create needs `accounts: [{account_id}]` and `transaction_currency_code`.
`/bills?start=&end=` gives `pay_dates` and `paid_dates` in that range.

Done (client version 3, no schema change; new map types budget, piggyBank,
bill):

- A Firefly budget is a Cashew budget of the type "added transactions only".
  Name, amount (the limit of this month, else the auto-budget amount), period
  and active state come from Firefly on each pull and are read-only here.
- The budget of a withdrawal is Transaction.sharedReferenceBudgetPk, sent as
  `budget_id` with the three-way merge. A local-only budget on a row is no
  budget on Firefly.
- Piggy banks and bills are cached in the map rows (snapshots) on each pull.
  There is no screen for them yet.
- Upgrade from version 2: a forced full pull, then the budget link of each
  row with a queued change from its snapshot.

Not done in phase C: screens for piggy banks and bills, recurrences,
attachments, writing budget limits.

## 4. Phases

Each phase ends with its tests green on the real server and the fake server.

- **A. Core on the new model.** Real-server test harness; snapshot and outbox
  tables (schema 51); field-diff push; server-wins pull with full first
  history and incremental pull; read-only types imported; balance anchor
  removed; category colour and notes; every rule of table 2.
- **B. Wider mirror.** Payees (expense and revenue accounts) with a picker in
  place of the guessed counterparty; liability wallets (kept out of asset
  totals); tags (new local table and join table); foreign amount on every
  type; asset roles editable.
- **C. Planning entities.** Firefly budgets and the current budget limit,
  mapped to Cashew budgets that use "added transactions only"; piggy banks as
  goals with progress read from Firefly; bills read-only with `bill_id` on
  splits; recurrences read-only; attachment download.
- **D. Read-only screens.** Available budgets, rules (with an explicit
  trigger), exchange rates, object groups, the ledger (user group) picker,
  insight totals.

Stays local or unsupported: Cashew budgets defined by category or wallet
filters and their category limits, associated titles, scanner templates,
unpaid planning rows, Drive attachments, writing server preferences, webhook
management, pushing Cashew's exchange rates.

## 5. Open decisions

Answered by the owner on 2026-10-13:

| Question | Decision |
| --- | --- |
| Local data when a phone connects or upgrades to the new engine | Back up the local database, then rebuild wallets, transactions and categories from the full Firefly history. Cashew-only columns are kept where an existing link matches |
| Wallet delete | Sets the Firefly account inactive and hides the wallet; history stays on the server |
| Category delete | Firefly semantics: the category is deleted on Firefly, its transactions become uncategorized on both sides |
| Subcategories | Stored as a Firefly tag (`Parent/Child`) in phase B |

Still open: wallet move and merge (blocked for now), marking a Firefly row
unpaid (blocked for now).
