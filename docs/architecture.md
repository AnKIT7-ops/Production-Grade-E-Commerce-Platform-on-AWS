# Architecture

## Current shape

```
                        Browser
                           │
                           │  REST over HTTP, JWT bearer tokens
                           ▼
            ┌──────────────────────────────┐
            │   Frontend (Vite dev :5173)  │
            │                              │
            │   pages/       one per route │
            │   components/  reusable UI   │
            │   context/     auth, cart    │
            │   services/    API client    │
            │   types/       API contract  │
            └───────────────┬──────────────┘
                            │  one fetch wrapper, no scattered calls
                            ▼
            ┌──────────────────────────────┐
            │   Backend (uvicorn :8000)    │
            │                              │
            │   api/       HTTP + validation
            │     ▼                        │
            │   services/  business logic  │
            │     ▼                        │
            │   models/    persistence     │
            │                              │
            │   schemas/   edge contract   │
            │   core/      hashing, JWT    │
            └───────────────┬──────────────┘
                            │  SQLAlchemy 2.0, psycopg2
                            ▼
            ┌──────────────────────────────┐
            │   PostgreSQL 18              │
            │   schema owned by Alembic    │
            └──────────────────────────────┘
```

## Layering

Requests move **router → service → model**, and never skip backwards.

| Layer | Owns | Does not |
|---|---|---|
| `api/` | Routing, status codes, request/response types, authorization | Contain multi-table logic |
| `services/` | Logic spanning more than one table, transactions | Know about HTTP beyond raising `HTTPException` |
| `models/` | Schema, constraints, relationships | Contain business rules |
| `schemas/` | The public contract at the edge | Touch the database |

Only three services exist, because only three pieces of logic are non-trivial:
`users` (registration and authentication), `cart` (stock-aware mutation and totals)
and `checkout` (the transactional conversion of a cart into an order). A five-line
list endpoint lives in its router; inventing a service for it would add a file and
no clarity.

Dependencies are injected as reusable annotated aliases — `DbDep`, `CurrentUserDep`,
`AdminDep` — so a router signature states its own security requirements.

## Data model

```
users ─────┬──< carts ──< cart_items >── products >── categories
           │                                  │
           └──< orders ──< order_items >───────┘
```

| Table | Notes |
|---|---|
| `users` | `email` unique + indexed, `role` (`customer`/`admin`), bcrypt hash in `String(60)` |
| `categories` | `name` and `slug` unique |
| `products` | `price NUMERIC(10,2)`, `slug` unique, `category_id` indexed, CHECKs on price and stock |
| `carts` | 1:1 with a user (`user_id` unique) |
| `cart_items` | `UNIQUE(cart_id, product_id)` so a repeat add increments rather than duplicating |
| `orders` | Status enum as `VARCHAR + CHECK`, `total_amount NUMERIC(10,2)`, shipping fields |
| `order_items` | Snapshots `unit_price` **and** `product_name`; `product_id` is `RESTRICT` |

Constraints live in the database wherever they can: `stock_quantity >= 0`,
`price >= 0` and `quantity > 0` turn a future logic bug into an `IntegrityError`
rather than corrupt data. Every foreign key is explicitly indexed, since Postgres
does not do so automatically.

## Request lifecycle

Taking `POST /api/orders` (checkout) as the most involved example:

1. **CORS middleware** checks the origin against `settings.cors_origin_list`.
2. **`get_current_user`** decodes the bearer token, asserts `type == "access"`,
   loads the user and rejects disabled accounts.
3. **Pydantic** validates the shipping payload; failures become a 422 carrying
   per-field messages.
4. **`create_order_from_cart`** runs the whole conversion in one transaction:
   cart lines sorted by `product_id` (deadlock avoidance), a conditional `UPDATE`
   per line that both checks and decrements stock, `flush()` for `order.id`, line
   items inserted, cart emptied, then a single `commit()`.
5. **The response type** filters and serializes the result — money as strings.
6. **Exception handlers** catch anything unhandled, log the traceback server-side
   and return a generic 500.

Any raise between steps 4 and the commit leaves the session dirty; `get_db()`'s
teardown rolls it back, so partial orders cannot exist.

## Frontend structure

State is React Context plus hooks — no Redux, which would be scaffolding at this
size.

- **`AuthProvider`** holds the user, restores the session from `localStorage` on
  mount, and listens for an expiry event from the API client so a session that dies
  mid-visit clears the UI instead of leaving a stale signed-in header.
- **`CartProvider`** mirrors the server cart. Every mutation returns the whole cart,
  so the server stays the single source of truth for quantities and stock rather
  than being patched optimistically.
- **`services/api.ts`** is the only module that calls `fetch`. It owns the base URL,
  bearer injection, one automatic refresh on 401 (retrying twice would loop on a
  revoked token), and conversion of error bodies into a typed `ApiError`.

Catalogue filter state lives in the URL, so views are shareable and the back button
works. Route protection is a `ProtectedRoute` wrapper that waits for the session
check before deciding, which stops a reload on `/orders` flashing the sign-in page.

## Security posture

| Concern | Handling |
|---|---|
| Passwords | bcrypt, byte-length validated at the edge, never logged or returned |
| Tokens | HS256, short-lived access + longer refresh, mandatory `type` claim |
| Authorization | `require_admin` dependency on every catalogue write |
| Ownership | Another user's order or cart item returns 404, not 403 |
| Account enumeration | Login returns an identical 401 for unknown email and wrong password |
| CORS | Explicit origin list from configuration, never `*` |
| SQL injection | SQLAlchemy ORM and bound parameters throughout |
| Error leakage | Handlers log tracebacks server-side and return `{"detail": ...}` |
| Secrets | Environment only; `SECRET_KEY` has no default and rejects placeholders |

Not yet addressed: rate limiting, refresh-token revocation, email verification,
audit logging. See the limitations section of the README.

## Deployment

The application runs on AWS: ECS Fargate behind an Application Load Balancer, with
RDS PostgreSQL, all defined in Terraform. The README's
[AWS deployment](../README.md#aws-deployment) section covers the infrastructure,
the security model and operations.

Three properties of the application make that deployment simple:

- **All configuration comes from the environment.** ECS injects it, including
  secrets from SSM Parameter Store.
- **The schema is migration-driven.** The container runs `alembic upgrade head`
  before serving.
- **The frontend and API share an origin.** The frontend calls relative `/api`
  paths, and something in front routes them to the backend:
  - the Vite dev server in development
  - nginx under Docker Compose
  - the ALB on AWS

  So `VITE_API_URL` stays empty, and there is no CORS configuration to manage.
