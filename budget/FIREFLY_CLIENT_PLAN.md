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
