# THE C.I.U–Inspired Fashion E-commerce & Flash Sale — Design Pack v2.1

This design pack adapts the earlier generic E-commerce & Flash Sale blueprint to a women's fashion storefront reference. v2.1 incorporates a full design review: it closes functional gaps (COD, cart, outbox/inbox, multi-line reservations), tightens the stock model, and is validated against MySQL 8.

## Files
- `ARCHITECTURE.md` — scope, service boundaries, diagrams, workflows (checkout, COD, expiry, campaign lifecycle), messaging, security, API surface, delivery plan, test plan.
- `DATABASE_DESIGN.md` — five-database ownership model, ERDs, table rules, lock order, transaction rules, reconciliation queries, verification notes.
- `schema.sql` — MySQL 8 starter DDL for all five service databases (loads cleanly, re-runnable).

## Key modeling choices
1. `products` is a clothing style/product page; `product_variants` is the sellable SKU (color + size, both NOT NULL with defaults).
2. Cart and order lines reference `variant_id`; one line per variant per order.
3. Inventory is tracked by `(variant_id, location_id)`. Checkout uses the single location flagged `is_online_default`; stores are informational in the MVP.
4. Flash Sale items target individual SKUs. Inventory Service owns allocation and reservation correctness; at most one `ACTIVE` allocation exists per variant+location.
5. MySQL is the durable source of truth. Redis accelerates, caches and sheds load; it is never the stock ledger.
6. VND is the only settlement currency, stored as whole dong (`DECIMAL(14,0)`). A currency selector is display-only.
7. Reservations are idempotent by `(order_id, variant_id)`; orders by `(user_id, Idempotency-Key)` plus a request hash. `order_id` is generated before the first remote call.
8. COD reservations are confirmed at order placement; online-payment holds expire (authoritative expiry lives in Inventory).
9. All Inventory transactions lock in one global order (allocation → user limit → stock), with lines sorted by `variant_id`.

## Changelog: v2.0 → v2.1

| # | Problem found in review | Fix |
|---|---|---|
| 1 | COD orders would lose their hold when it expired (confirm only on `order.paid`) | Confirm at placement for COD; new `order.confirmed` event; sync confirm call with event as safety net |
| 2 | `UNIQUE(user_id)` on carts blocked a new cart after `CONVERTED` | One **ACTIVE** cart per user via generated-column unique key |
| 3 | Nullable `size_label` let duplicate free-size variants through the unique key | `color_name`/`size_label` NOT NULL with defaults |
| 4 | Inventory published/consumed events but had no outbox/inbox | `outbox_events` + `inbox_messages` added to `inventory_db` |
| 5 | Checkout diagram created the saga before the order, but the saga FK needs the order | Order (`CREATING`) + saga inserted together first; `orderId` pre-generated |
| 6 | One reservation per idempotency key vs. multi-line orders | Reservation unique per `(order_id, variant_id)`; atomic batch reserve and batch release |
| 7 | Deadlock risk, ambiguous `released_qty`, pooled flash bucket, one-bucket movement log | Global lock order; defined `released_qty`; one ACTIVE allocation per variant+location; movements log all four buckets with CHECKs; release-after-close returns to regular stock |
| 8 | Payment after reservation expiry undefined; two expiry sources | `RESERVATION_EXPIRED` → order `EXPIRED`; `reservations.expires_at` is authoritative |
| 9 | `ON DELETE CASCADE` product→variants contradicted soft delete | `RESTRICT` |
| 10 | Image could point to another product's variant | Composite FK `(variant_id, product_id)` |
| 11 | No total-consistency checks; fractional dong | `grand_total` / `line_total` CHECKs; whole-VND money; `currency = 'VND'` |
| 12 | Idempotency key reusable with a different payload | `request_hash`; `422 IDEMPOTENCY_KEY_REUSED` |
| 13 | UTC claimed but session time zone used; FULLTEXT ignores 2-letter Vietnamese words | MySQL/JDBC UTC settings documented; MVP search uses `LIKE` |
| 14 | Internal APIs and exact public stock exposed | `/internal/**` not routed; service tokens; coarse public availability |
| 15 | Flash allocation handshake undescribed; no way for Inventory to learn variants | Campaign lifecycle workflow, `allocation_status`, internal allocate/close APIs; admin upserts stock after validating the variant |
| 16 | Scope too large for 2 people / 12 weeks | Eureka dropped from MVP (Docker DNS); 1 transactional location; week-by-week plan, risk table, scope-cut order, modular-monolith fallback |
| 17 | Redis admission guard could drift | Compensation on reject/release, rebuild from DB, reconciliation |
| 18 | Redundant `products.is_featured` | Removed; "featured" is a collection |

## Verification performed on this revision

- `schema.sql` loaded into MySQL 8.0 without errors: 32 tables, zero cross-database FKs, safe to re-run.
- 36 behavioural checks passed (constraint rejections and acceptances for each fix above).
- Concurrency smoke test of the Flash Sale reservation transaction (150 concurrent attempts, 20 units, limit 2 per user): exactly 20 reserved, 130 sold out, no negative stock, no deadlock, reconciliation queries clean; a deliberately corrupted bucket was detected.
- All 10 Mermaid diagrams parse.

Not verified: the Java services (none exist yet), RabbitMQ/Redis behaviour, and behaviour on a MySQL version other than 8.0.x. Re-run the checks against the exact version and driver you ship.

## Before coding
1. Agree on the MVP scope and which reference pages will be recreated. Decide **microservices vs modular monolith by the end of week 1** (see `ARCHITECTURE.md` §12.3).
2. Review the stock invariants, lock order and the Flash Sale transactions with both team members.
3. Create `SRS.md` and `API_SPECIFICATION.md` from these documents (the error-code table and API list in `ARCHITECTURE.md` §8 and §11 are the starting point).
4. Split `schema.sql` into Flyway migrations owned by each service; do not share DB credentials between services. Configure MySQL with `default-time-zone='+00:00'` and JDBC `connectionTimeZone=UTC`.
5. Seed original/demo product photos and data. Do not reuse brand assets or product photographs without permission.
6. Implement in this order: Product/Variant → **Inventory with its concurrency tests** → Cart/Order (normal + COD) → Flash Sale → Frontend polish and load test.
7. Automate tests T1–T13 from `ARCHITECTURE.md` §14.2 and run the reconciliation queries after each.

The SQL is a starter schema. Add application-level validation for the rules listed in `DATABASE_DESIGN.md` §7, which cannot be expressed as local constraints.
