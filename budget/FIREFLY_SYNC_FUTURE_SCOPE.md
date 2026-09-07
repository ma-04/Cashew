# Firefly III Sync - Future Scope

Phase 1 (this implementation) syncs **Accounts (Wallets), Transactions
(withdrawal/deposit/transfer only), and Categories (top-level only)** between
Cashew and a self-hosted Firefly III instance, using a Personal Access Token
and last-write-wins conflict resolution. Everything below is deliberately out
of scope for phase 1.

## 1. Deferred entities

- **Budgets** (`lib/database/tables.dart` `Budgets` table) &harr; Firefly
  `budgets`. Cashew's budget model (recurring windows, category associations)
  doesn't map cleanly to Firefly's budget+budget-limit model; needs its own
  design pass.
- **Objectives/goals/loans** (`Objectives` table) &harr; Firefly `piggy-banks`
  and loan/debt/mortgage account types. Not attempted.
- **Tags**. Cashew has no local tag table at all right now (the old `Labels`
  table is fully commented out in `tables.dart`) - tag sync needs a new local
  table before it can even be considered.
- **Bills/Subscriptions/Recurring transactions**. Cashew models these as
  fields on `Transactions`; Firefly has separate `recurrences`/`bills`
  resources. Not attempted.

## 2. Deferred features

- **OAuth2 authentication** - PAT only in phase 1. Firefly's OpenAPI spec
  supports both; OAuth2 would let users avoid pasting a long-lived token, but
  needs a redirect flow that a mobile client can't host without a bundled
  webview/browser tab handler.
- **Per-transaction foreign currency** (amount + rate distinct from the
  wallet's currency). Not synced; Firefly's `foreign_amount`/
  `foreign_currency_id` fields are ignored on pull and never sent on push.
- **Transaction splits beyond the first**. A Firefly transaction group can
  contain multiple splits (Cashew has no concept of a multi-split
  transaction). Only `splits.first` is consumed on pull; extra splits are
  silently skipped. Recommendation for a future pass: surface a "N splits
  skipped" count to the user rather than silently dropping data.
- **Subcategories**. Firefly categories are flat; Cashew categories have one
  level of nesting. Phase 1 only syncs main categories
  (`mainCategoryPk == null`) - subcategories are never pushed and never
  created from a pull. Recommended future approach: either flatten via a
  `"Parent: Child"` naming convention on push, or add real hierarchical
  category support to Firefly's side via tags.
- **Non-asset Firefly accounts** (expense, revenue, cash, liability accounts).
  Only `asset` accounts become/stay linked to local Wallets. When a pulled
  transaction's counterparty is a non-asset account, only the transaction's
  own wallet/category/amount fields are used - the counterparty name is not
  currently persisted (a future pass could append it to the transaction note).
- **Opening balance / reconciliation transaction types**. Both are skipped by
  `classifySplitType()` (returns `FireflyPulledSplitKind.skip`).
- **Richer conflict-resolution UI**. Phase 1 is last-write-wins with no user
  visibility into what got overwritten. A future pass could log conflicts
  and let the user review them.
- **Webhook/relay-based near-real-time sync**. Firefly III supports outbound
  webhooks, but a mobile client has no stable public endpoint to receive them
  without a relay server. Sync stays pull-based polling (foreground, pull-to-
  refresh, debounced push) for now.

## 3. Known lossy-mapping limitations

- **Timezone/date normalization**: Firefly transaction dates are stored and
  compared as UTC-normalized values; Cashew's `dateCreated` is a plain local
  `DateTime`. Edge-of-day transactions may shift by a day depending on the
  server's configured timezone.
- **Currency code validation**: `fireflyMapper.dart` passes wallet/category
  currency codes through uppercased with no validation against Firefly's
  configured currency list - an unrecognized code will surface as a push
  error rather than being caught client-side.
- **flutter_secure_storage on web**: the Personal Access Token is stored via
  `flutter_secure_storage`, which on web does not use OS-keychain-backed
  storage (reduced protection vs. native platforms). This is a known,
  accepted tradeoff consistent with other web-specific compromises already
  present in the app - not something phase 1 attempts to fix.
- **Transfer pull updates**: an edit made on the Firefly side to an
  already-linked transfer is not currently pulled back down (see the comment
  in `fireflySyncEngine.dart`'s `_pullTransactions` - new transfers are
  pulled, but updates to existing linked transfer pairs are deferred to a
  future iteration and left to the push side's last-write-wins check
  instead).
