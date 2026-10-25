# Audit log

Point-in-time engineering audits. A record of what was checked, what was found and what
was changed — not a description of current behaviour. For how the system works today see
[`architecture.md`](architecture.md), [`api.md`](api.md) and
[`decisions.md`](decisions.md). Newest last.

---

## Pre-containerisation audit — 20 September 2026

**Scope:** full repository, backend through frontend
**Commit:** `2434705` — *fix: close two frontend state bugs and a restock race found in audit*
**Verdict:** **Ready for the next stage.** Three defects found and fixed, 17 tests added, all checks green.

No new features were added. No Docker, AWS, Terraform, CI/CD, monitoring or deployment work
was started. Figures below are as measured on the audit date.

---

### 1. Issues found

#### 1.1 Aborted requests flashed the empty state — 5 files, user-visible

Every data-loading page shared this shape:

```js
catch (caught) {
  if (caught instanceof DOMException && caught.name === "AbortError") return;
  setError(...);
} finally {
  setIsLoading(false);   // runs even on the early return above
}
```

A `finally` block executes on an early `return`, so a **superseded** request cleared the
loading flag while `result` was still `null`. The page then fell through to its empty or
not-found branch.

Observed live in the browser, not inferred: navigating to `/products` rendered
*"Nothing matches those filters"* with a category count of `0` before the data arrived.

| Page | What flashed |
|---|---|
| `ProductsPage` | "Nothing matches those filters" |
| `OrdersPage` | empty order history |
| `OrderDetailPage` | "We could not find that order on your account." |
| `ProductDetailPage` | "We could not find that product. It may have been removed." |
| `HomePage` | empty catalogue sections |

Triggered on **every** filter, sort, search or pagination change — the effect re-runs and
aborts the in-flight request — not merely on a StrictMode double-mount.

#### 1.2 Duplicate DOM ids broke form labelling — accessibility

`SearchBar` hardcoded `id="product-search"` and renders **three times** per page: desktop
header, mobile header, and the products-page filter bar. Measured in the live DOM:

```json
{ "duplicateIds": ["product-search"],
  "searchCount": 3,
  "labelsPerSearch": [3, 0, 0] }
```

`label[for]` resolves to the first matching element, so only the first input received an
accessible name. The other two fell back to their `placeholder` — which disappears on typing
and is a weak substitute for a label. The document was also invalid HTML.

#### 1.3 Order cancellation could inflate inventory — backend, concurrency

`cancel_order` performed an unguarded status check followed by a Python read-then-write:

```python
if OrderStatus.CANCELLED not in ORDER_STATUS_TRANSITIONS[order.status]:
    raise HTTPException(409, ...)
for item in sorted(order.items, key=lambda i: i.product_id):
    product = db.get(Product, item.product_id)
    product.stock_quantity += item.quantity      # read-modify-write
order.status = OrderStatus.CANCELLED
```

Nothing locks the order row before the check, so two overlapping cancellations both pass it
and **both** credit the catalogue.

Reproduced directly against the old code with two real sessions — a 2-unit order:

```
stock after checkout:            3
stock after session A cancels:   5
B's cancel SUCCEEDED -> stock:   7     ← two units returned twice
```

This was the **only** read-modify-write on `stock_quantity` in the codebase. Checkout already
used the correct conditional-UPDATE pattern; cancellation had been missed.

#### 1.4 Pre-existing lint errors

Three, all present at `HEAD` before the audit: import ordering in `alembic/env.py` and
`app/schemas/user.py`, and one line over 100 characters in `tests/test_auth.py`.

#### 1.5 Test-coverage gaps against the specified matrix

Missing before the audit:

- anonymous `401` for **every** category write (`POST`, `PUT`, `DELETE`)
- customer `403` for category `PUT` and `DELETE`
- an explicit public-read assertion for categories
- the admin create → update → delete success path
- anonymous `401` for product `PUT` and `DELETE` (only `POST` was covered)
- rejection of a **forged-signature** token
- rejection of an **expired** token

#### 1.6 Stale documentation

README claimed **"110 tests"** in two places; had no frontend route documentation and no
endpoint reference of its own.

---

### 2. Issues fixed

| # | Fix | Files |
|---|---|---|
| 1.1 | Loading flag survives an abort: `if (!controller.signal.aborted) setIsLoading(false)` | 5 pages |
| 1.2 | `SearchBar` takes its id from React's `useId()` | `SearchBar.tsx` |
| 1.3 | Cancellation claimed by conditional `UPDATE`; restock made relative | `api/orders.py` |
| 1.4 | Lint clean — `ruff check .` passes | 3 files |
| 1.5 | 17 tests added | `test_catalogue.py`, `test_auth.py`, `test_concurrency.py` |
| 1.6 | README rewritten where stale, three sections added | `README.md` |

The cancellation fix now mirrors checkout's discipline exactly:

```python
claimed = db.execute(
    update(Order)
    .where(Order.id == order.id, Order.status.in_(cancellable))
    .values(status=OrderStatus.CANCELLED)
)
if claimed.rowcount == 0:
    db.rollback()
    raise HTTPException(409, "This order has already been cancelled or dispatched")

for item in sorted(order.items, key=lambda i: i.product_id):   # deadlock ordering
    db.execute(
        update(Product)
        .where(Product.id == item.product_id)
        .values(stock_quantity=Product.stock_quantity + item.quantity)   # relative
    )
```

The loser's `UPDATE` waits on the winner's row lock, then matches zero rows and is rejected —
so the restock cannot run twice.

#### A correction worth recording

My **first** regression test for 1.3 passed against the buggy code. SQLAlchemy's identity map
holds **weak** references, so the stale order object was garbage-collected and the session's
next `SELECT` silently returned fresh, already-cancelled data — which is not the interleaving
under test. Two earlier attempts at a threaded HTTP race also failed to reproduce it: the
requests never genuinely overlapped.

The test only became a real guard once it holds a strong reference to the pre-cancellation
order, which is precisely what a real request handler's local variable does. Verified in both
directions:

- against the old code → **fails**, `Failed: DID NOT RAISE HTTPException`
- against the fixed code → **passes**

#### Test data hygiene

A customer account was registered through the UI to exercise checkout end to end, then removed
along with its order, with the consumed stock restored. The development database is back to its
exact pre-audit state: **7 users, 6 categories, 35 products, 1 order**, `plant-pot` stock `59`.

---

### 3. Tests executed and results

```
132 passed, 1 warning in 44.01s
```

| Metric | Before | After |
|---|---:|---:|
| **Total** | 115 | **132** |
| **Passed** | 115 | **132** |
| **Failed** | 0 | **0** |
| **Skipped** | 0 | **0** |

| File | Before | After | Δ |
|---|---:|---:|---:|
| `test_auth.py` | 26 | 28 | +2 |
| `test_cart.py` | 16 | 16 | — |
| `test_catalogue.py` | 40 | 54 | +14 |
| `test_concurrency.py` | 2 | 3 | +1 |
| `test_health.py` | 6 | 6 | — |
| `test_orders.py` | 25 | 25 | — |

> A note on accuracy: my terminal summary at the end of the audit stated `test_auth.py 30`.
> The correct figure is **28**. The 132 total was right; the per-file breakdown was not.

No test was weakened, skipped or rewritten to mask a defect. The one warning is a
`StarletteDeprecationWarning` from FastAPI's own `TestClient` import, unrelated to this project.

Linters: `ruff check .` → **All checks passed**. `oxlint` → clean. `tsc -b` → clean.

---

### 4. Build result

```
npm run build
✓ 96 modules transformed
dist/index.html                  1.81 kB │ gzip:   0.88 kB
dist/assets/index-BPC4cNwR.js  397.40 kB │ gzip: 121.41 kB
dist/assets/index-C_du7RKY.css  39.74 kB │ gzip:   8.46 kB
✓ built in 2.08s
```

Vite prints a Node 22.11-vs-22.12 advisory. It is a **warning, not an error**, and the README
already documents why Vite 7 is pinned: Vite 8 and oxlint publish native binaries with an
`engines` floor of Node `>=22.12`, which npm silently skips on 22.11, producing a
*"Cannot find native binding"* failure at build time.

---

### 5. Migration result

```
alembic check    → No new upgrade operations detected.
alembic current  → 6a2486682a48 (head)
```

Models and live schema are in sync, with `compare_type=True` enabled so `NUMERIC` precision and
`String` length drift is caught rather than silently dropped.

A full round trip was run in a throwaway schema — `upgrade head` → `downgrade base` →
`upgrade head` — completing cleanly and producing all seven tables plus `alembic_version`.

Schema introspected against the live database:

| Check | Result |
|---|---|
| Primary keys | Present on all 7 tables |
| Foreign keys | `RESTRICT` on `order_items.product_id`, `orders.user_id`, `products.category_id`; `CASCADE` on `carts.user_id`, `cart_items.*` |
| Unique constraints | `users.email`, `categories.name`, `categories.slug`, `products.slug`, `carts.user_id`, `(cart_id, product_id)` |
| Indexes | Every foreign key indexed — Postgres does not do this automatically |
| Timestamps | `timestamptz` with `now()` server defaults on all 7 tables |
| Monetary types | `NUMERIC(10,2)` on `products.price`, `orders.total_amount`, `order_items.unit_price` |
| Check constraints | Non-negative stock and price, positive quantities, non-negative totals, role and status enums |

`RESTRICT` on `order_items.product_id` is deliberate: deleting a product must never erase order
history. Products are retired with `is_active = False` instead.

**Environment note:** the Postgres role has no `CREATEDB` privilege, so the suite uses its
documented fallback — a dedicated `ecommerce_test` schema with `search_path` pinned to it.
Isolation is equivalent; development data is never touched.

---

### 6. Authentication / admin authorization verification

#### Role system

`User.role` is a `VARCHAR(20) + CHECK` enum — `customer` | `admin` — non-null, defaulting to
`customer`. A native Postgres enum was deliberately avoided because autogenerate silently misses
added values and leaves orphaned types behind on downgrade.

Role **cannot** be set through public registration; `test_register_never_grants_admin` asserts
that a `"role": "admin"` field in the request body is ignored. Administrators are provisioned
only by the seed script.

#### Authorization matrix — verified against the running app and now under test

| Endpoint | anonymous | customer | admin |
|---|:---:|:---:|:---:|
| `GET /categories` | 200 | 200 | 200 |
| `GET /categories/{id}` | 200 | 200 | 200 |
| `GET /categories/slug/{slug}` | 200 | 200 | 200 |
| `POST /categories` | **401** | **403** | **201** |
| `PUT /categories/{id}` | **401** | **403** | **200** |
| `DELETE /categories/{id}` | **401** | **403** | **200** |
| `POST /products` | **401** | **403** | 201 |
| `PUT /products/{id}` | **401** | **403** | 200 |
| `DELETE /products/{id}` | **401** | **403** | 200 |
| `PATCH /orders/{id}/status` | **401** | **403** | 200 |

The 401-vs-403 split is the load-bearing distinction: a customer's token *authenticates*
successfully but does not *authorize*, so it must be `403` — never `401`, which would wrongly
suggest the credentials were the problem.

#### Password handling

- bcrypt via `bcrypt.hashpw`, stored in a `String(60)` column — hashes always begin `$2b$`.
- No plaintext password is stored, logged or returned. `UserRead` has no password field.
- `verify_password` catches bcrypt's `ValueError` on inputs over its 72-**byte** limit, so an
  attacker posting a 200-character password gets a clean `401` rather than a `500`.

#### Token handling

| Case | Result | Covered by |
|---|---|---|
| No token | 401 | `test_me_requires_authentication` |
| Malformed token | 401 | `test_me_rejects_a_malformed_token` |
| **Forged signature** | 401 | `test_me_rejects_a_token_signed_with_another_key` *(new)* |
| **Expired token** | 401 | `test_me_rejects_an_expired_token` *(new)* |
| Refresh token used as access | 401 | `test_refresh_token_is_rejected_as_an_access_token` |
| Access token used as refresh | 401 | `test_refresh_rejects_an_access_token` |
| Disabled account | 403 | `test_login_rejects_disabled_account` |

The refresh/access separation matters because both are signed with the same key and algorithm.
`decode_token` asserts the `type` claim — without it, a 7-day refresh token would authenticate
every request for a week.

Login returns an **identical** 401 for an unknown email and a wrong password, so the endpoint
cannot be used to enumerate registered accounts. Ownership failures on orders and cart items
return `404` rather than `403`, so the API does not confirm that an id exists.

**No security control was weakened to make any test pass.**

---

### 7. Checkout / stock verification

#### Transaction integrity

All eight required steps happen inside **one** transaction with a single `commit()` at the very
end:

1. Cart validated — empty cart is a `400`
2. Product availability validated — `is_active` is part of the UPDATE predicate
3. Stock validated — `stock_quantity >= :qty` in the same predicate
4. Order created (`db.flush()`, not `commit()`, to obtain `order.id`)
5. Order items created, with `product_name` and `unit_price` snapshotted
6. Total accumulated in `Decimal`
7. Stock decremented
8. Cart cleared

Anything raised before that final `commit()` leaves the session dirty, and `get_db()`'s teardown
rolls the whole thing back — **no partial orders, and no stock decremented for an order that
never came into existence.** Covered by `test_failed_checkout_leaves_the_cart_intact` and
`test_failed_checkout_does_not_decrement_any_stock`.

#### Concurrency safety

```sql
UPDATE products
   SET stock_quantity = stock_quantity - :qty
 WHERE id = :id AND is_active AND stock_quantity >= :qty
RETURNING price, name
```

Three properties make this correct under Postgres' READ COMMITTED isolation:

- the `stock_quantity >= :qty` predicate is **re-evaluated after the row lock is acquired**, so
  a losing concurrent decrement matches zero rows and is rejected — the same guarantee as
  `SELECT ... FOR UPDATE`, without a separate locking step a future code path could forget;
- `RETURNING` reads the price **under that same lock**, so a concurrent reprice cannot skew the
  order total;
- cart lines are processed in `product_id` order, so two shoppers with overlapping carts cannot
  take row locks in opposite orders and deadlock.

#### Verified end to end in a real browser

Registered → added to cart → checked out → order created → appeared in history. Stock moved
**59 → 58**, the cart emptied (`IN YOUR CART: 0 items`), and the order detail page rendered the
correct total and shipping address.

#### Concurrency tests — all passing

| Test | Asserts |
|---|---|
| `test_concurrent_checkout_never_oversells` | Two racers, one unit: exactly `[201, 409]`, stock `0`, **one** order |
| `test_concurrent_checkout_allows_both_when_stock_suffices` | The guard rejects overselling without rejecting legitimate concurrency |
| `test_concurrent_cancel_restocks_exactly_once` *(new)* | Staged interleaving: loser gets `409`, stock credited **once** |

Payment processing remains simulated by design; no card details are collected or stored.

---

### 8. README / documentation status

#### Verified accurate

- **No stale catalogue prices** and no old design copy — grepped and confirmed.
- Tech-stack versions match `requirements.txt` and `package.json` exactly (FastAPI 0.141.1,
  SQLAlchemy 2.0.54, Alembic 1.20.0, bcrypt 5.0.0, PyJWT 2.14.0, React 19.2, Vite 7.3.6,
  Tailwind 4.3.3, TypeScript 6.0).
- `docs/api.md` checked against the live OpenAPI schema — **no drift** across all 31 operations.

#### Added

| Section | Contents |
|---|---|
| **API endpoints** | All 31 operations (29 under `/api`, plus `/` and `/health`), grouped by resource, each with an explicit public / user / admin access column |
| **Frontend routes** | All 10 routes plus the catch-all, with protection marked and behaviour described |
| **Development commands** | Consolidated table: run, test, lint, migrate, seed, type check, build, preview |
| **Not yet implemented** | A dedicated section marking each item **NOT YET IMPLEMENTED** |

#### Corrected

- `110 tests` → `132 tests`, in both the Testing section and the project tree.
- `VITE_API_URL` documentation, which described a stale `http://localhost:8000` default.
- Status line now points at *Not yet implemented* rather than *Roadmap*.
- Table of contents updated; every anchor verified against its heading.

#### Explicitly marked NOT YET IMPLEMENTED

| Area | Status |
|---|---|
| AWS deployment | **NOT YET IMPLEMENTED** |
| Terraform / infrastructure as code | **NOT YET IMPLEMENTED** |
| Docker and a production container setup | **NOT YET IMPLEMENTED** |
| CI/CD pipelines | **NOT YET IMPLEMENTED** |
| Monitoring, logging and alerting | **NOT YET IMPLEMENTED** |
| Production infrastructure and hardening | **NOT YET IMPLEMENTED** |

The section states plainly that no configuration, scripts or scaffolding for any of it exists,
that `infrastructure/` is deliberately empty, and that any mention of AWS elsewhere in the docs
is a statement of intent rather than of fact.

#### Documented coverage

Architecture · tech stack · local setup · PostgreSQL · environment variables · migrations ·
seed data · authentication · admin authorization · API endpoints · frontend routes · testing ·
development commands — all present and verified.

---

### 9. Secrets and environment

```
git check-ignore -v backend/.env    → .gitignore:2:.env   backend/.env
git check-ignore -v frontend/.env   → .gitignore:2:.env   frontend/.env
```

- Both `.env` files are **ignored and untracked** (`git ls-files --error-unmatch` fails on both).
- Only `backend/.env.example` and `frontend/.env.example` are tracked, permitted by the
  `!.env.example` negation.
- A secret scan across all tracked files found nothing but well-known test-fixture passwords in
  `tests/conftest.py`.
- `.env.example` contains placeholders only: `SECRET_KEY=CHANGE_ME_generate_with_secrets_token_urlsafe`,
  `SEED_ADMIN_PASSWORD=CHANGE_ME_choose_a_strong_password`.
- **The real `SEED_ADMIN_PASSWORD` is not exposed anywhere.** `app/seed.py` never prints it —
  only the email — and refuses to create an admin if the value is unset or still a placeholder.
- `SECRET_KEY` has no default and is validated at startup; the application refuses to boot on a
  missing or placeholder value.

---

### 10. Frontend route verification

Every route was exercised in a real browser against the running dev server.

| Route | Status | Notes |
|---|---|---|
| `/` | Pass | 6 departments, in-stock highlights, new arrivals all load |
| `/products` | Pass | 34 active products, filters, sort, pagination |
| `/products/:id` | Pass | Detail, stock, quantity selector, related products |
| `/login` | Pass | Renders; receives protected-route redirects |
| `/register` | Pass | Account created, signed in, redirected |
| `/cart` | Pass | Protected; lines, totals, quantity edits |
| `/checkout` | Pass | Protected; full shipping form, order placed |
| `/orders` | Pass | Protected; history with totals and status |
| `/orders/:id` | Pass | Protected; items, timeline, cancellation |
| `/account` | Pass | Protected; profile, name editing, sign out |

**Protected routes** correctly redirect anonymous visitors to `/login`, and `ProtectedRoute`
waits for the stored session to resolve before deciding — so a reload on `/orders` does not
flash the sign-in page.

**Other checks**

| Area | Result |
|---|---|
| API integration | Single client; one automatic refresh on 401, then a clean session-expiry event |
| Auth state | Survives navigation and reload; expiry clears the UI rather than leaving a stale header |
| Cart state | Server-side, per user; badge updates live |
| Loading states | Skeletons render correctly — **fixed** (§1.1) |
| Error states | Typed `ApiError`, retry affordance, network errors distinguished |
| Empty states | Correct, and no longer flash during loading |
| Responsive | 375 px: `scrollWidth === innerWidth`, no horizontal overflow; filters collapse to a disclosure |
| Light/dark mode | Toggle works, both toggles stay in sync, persists to `localStorage`, stored choice overrides the system preference, `aria-label` updates |
| Accessibility | One `h1` per page, ordered headings, `alt` on all 12 images, no unnamed buttons, skip link, landmarks, `lang="en"`, **zero duplicate ids and zero unlabelled inputs after the fix** |
| Console | No errors on any route |

---

### 11. Git status

```
On branch main
Your branch is up to date with 'origin/main'.
nothing to commit, working tree clean
```

```
2434705 (HEAD -> main, origin/main) fix: close two frontend state bugs and a restock race found in audit
44f780e chore: ignore local editor tooling config
3aab68b feat: make users.full_name NOT NULL
4bb4264 feat: require a full name on registration and profile updates
a41e768 fix: darken the signal colour to meet AA on its own tint
```

- Working tree **clean**; no untracked files.
- One commit, pushed: `44f780e..2434705  main -> main`.
- **No history was rewritten.**

**Disclosure:** the working tree already held in-progress work when the audit began — the
profile-update PATCH fix, the migration backfill hardening, and a set of storefront
refinements. Four files (`README.md`, `tests/test_auth.py`, `HomePage.tsx`,
`OrderDetailPage.tsx`) ended up containing **both** that work and audit fixes, so a clean split
was not possible without interactive staging. It therefore landed as a single commit, and the
commit message says so.

---

### Summary

| Area | Result |
|---|---|
| Admin authorization | Verified across the full matrix, now fully tested |
| Authentication | Verified; forged and expired token rejection added |
| Database | All models, keys, constraints, indexes and types correct |
| Checkout transaction | Correct and atomic; verified end to end |
| Inventory consistency | One race found and fixed; three tests guard it |
| Backend tests | **132 passed, 0 failed, 0 skipped** |
| Frontend build | **Passes** — `tsc`, `oxlint` and `vite build` all clean |
| Migrations | `alembic check` clean; full round trip verified |
| Documentation | Accurate and complete |
| Git | Clean tree, committed, pushed |

**Outcome:** a complete local backend and a complete functional frontend. The
repository is ready for containerisation and cloud deployment.
