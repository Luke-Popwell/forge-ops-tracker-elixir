# Changelog

## 0.20.0 (2026-10-23)

- PII scrubbing catches card numbers however they're grouped (bare, 4-4-4-4, Amex's 4-6-5, or next to a
  security code) when the digits have a card network's prefix and pass the Luhn check, so long ids stay
  readable; IBANs, compact or in groups of four, by their own check digits; and fields named `iban`,
  `account_number`, `routing_number` or `bank_account`. The rules are in sdks/PII_SCRUBBING.md, the same in
  every SDK.

## 0.19.0 (2026-10-22)

- Strict privacy: the message fingerprint now also replaces email addresses with `<email>` and quoted
  values (`"..."`, and `'...'` when the quotes aren't part of a word) with `<str>`, before the existing
  steps. `KeyError: 'Jane Doe'` and `KeyError: 'Bob Smith'` now group together, and no guessable value sits
  behind the hash. Errors whose messages contain quotes or emails get new fingerprints once, so they open
  new issues after upgrading.

## 0.18.1 (2026-10-22)

- Strict privacy now also turns off slow query plans (`explain_slow_queries`): no EXPLAIN is run and no
  plan is sent, since a plan carries the SQL. Before, a plan could still be sent, with its values masked.
- The README says what strict privacy does in its opening lines.
- The source is public at https://github.com/Luke-Popwell/forge-ops-tracker-elixir, and the package links to it.

## 0.18.0 (2026-10-20)

- Changed: with `strict_privacy: true`, a span name or transaction name that is a raw path (one with no route parameter such as `:id` or `{id}`) used to keep every segment without a digit, so `/patients/jane-doe` went out as written. It is now cut to its first segment, then `/:path` if there was more: `GET /patients/jane-doe/12` is sent as `GET /patients/:path`. A route template (`GET /patients/:id/notes`, what the Phoenix integration reports) is sent as it is. With strict privacy off, nothing changes.
- `ForgeOpsTracker.StrictPrivacy.path_without_ids/1` is deprecated in favour of the new `strict_path/1`, which it now calls.

## 0.17.0 (2026-10-20)

- New: strict privacy, for apps that can't let personal or health data leave their own servers. With `strict_privacy: true` (off by default) an error is sent as structured facts only: no message (a `message_fingerprint` computed in this VM instead, so errors still group), no breadcrumbs (`add_breadcrumb/4` records nothing), no `endpoint`, no SQL statement, no source context, the user's `id` only, and only the `context` and `tags` keys listed in the new `privacy_allowed_fields`, when their value is a string, number or boolean. Spans are named by method and host for outbound calls, with ids stripped from paths, and keep only `db.statement` and `db.system` as data. Both can be set in `config.exs`, with `init/1`, or with `FORGE_OPS_STRICT_PRIVACY=true` and `FORGE_OPS_PRIVACY_ALLOWED_FIELDS=error_code,feature`; config wins over the environment. With it off, nothing changes. See the README's "Strict privacy" section. A transaction name that's a raw path rather than a route has its ids stripped the same way in error events and performance samples. Span names, outbound hosts included, are read by hand rather than with a URL parser, so an address a parser would reject still loses its path.

## 0.16.0 (2026-10-13)

- Fixed: a batch the server refused was re-sent at every flush for as long as the node lived, with everything recorded since added to it. Performance samples and custom and infrastructure metrics are now dropped when the server answers with a 4xx other than 408 or 429 (a 400, 401, 403, 413 or 422, for example), since sending the same batch again can only fail the same way. Once a metric buffer had filled up behind such a batch, every new metric was dropped too; that no longer happens.
- A batch that could not be delivered for now (a network error, a timeout, a 5xx, a 408 or a 429) is still kept for the next flush, but only for 5 flushes in a row. After the fifth it is dropped and the buffer starts clean, so a long outage no longer holds the same data in memory forever. Error events, traces, changes and query plans were already sent once and never re-sent; that is unchanged.
- With a `logger`, each dropped batch is logged once with how many entries were dropped and why, and any 4xx or 5xx answer is logged with its status code and whether it will be retried.
- New `ForgeOpsTracker.Client.attempt_performance_samples/2`, `attempt_metrics/2` and `attempt_infrastructure_metrics/2` return `:delivered`, `:rejected` or `:failed` (see `ForgeOpsTracker.DeliveryStatus`). Every `Client.deliver*` function still returns the same boolean.

## 0.15.1 (2026-10-03)

- The "Not sending" warning now also appears the first time an error is dropped because the environment isn't enabled, not only from `init/1`. An app configured through `config.exs` or `FORGE_OPS_DSN` alone never calls `init/1`, so under Mix on a development machine (`mix run`, `iex -S mix`, `mix phx.server`) its errors were dropped without a word. Still one warning per VM, through `Logger`, and still nothing without a DSN.

## 0.15.0 (2026-10-02)

- **Changed default:** the environment is now `FORGE_OPS_ENVIRONMENT`, then `config :forge_ops_tracker, environment:`, then `MIX_ENV` (`prod` read as `"production"`, `dev` as `"development"`, `test` as `"test"`), then `Mix.env()` read the same way when the app runs under Mix, and `"production"` when none of those applies. It used to fall back to `"development"` and never looked at `MIX_ENV` or Mix, so a release, an escript or a script with nothing but a DSN, and even a release run with `MIX_ENV=prod`, reported as `"development"`, which isn't enabled: nothing was ever sent, and nothing said so. Under Mix (`iex -S mix`, `mix phx.server`) with no `MIX_ENV`, the environment is still `"development"`, as before. An empty value now counts as unset. To keep the old behavior everywhere, set `FORGE_OPS_ENVIRONMENT=development` or `config :forge_ops_tracker, environment: "development"` wherever you don't want to send.
- `init/1` now logs one warning through `Logger` (once per VM) when a DSN is set but the environment isn't one of `enabled_environments`, naming the environment and how to send from it. Nothing is logged when no DSN is set.
- New `ForgeOpsTracker.Configuration.resolve_environment/3` and `disabled_environment_warning/1`.

## 0.14.1 (2026-10-01)

- An error reported just before the VM stops is no longer lost. A `mix run` or `elixir` script, or an escript, now waits when it finishes for queued errors, changes and traces to go out, and a VM stopped normally sends them as the client shuts down. The wait is at most 5 seconds, and a VM that never reported anything doesn't wait at all.
- New `ForgeOpsTracker.flush(timeout \\ 5000)` waits until everything queued so far has been sent, returning `:ok` or `{:error, :timeout}`. Use it before `System.halt/1`, which skips the automatic wait.
- A delivery that crashes no longer stops later deliveries from going out.

## 0.14.0 (2026-09-29)

- SQL masking now also catches strings with a backslash-escaped quote (`'o\'brien'`, `E'o\'brien'`), prefixed strings (`E''`, `X''`, `N''`, `B''`, `U&''`, prefix included), hex, binary and exponent numbers (`0x1F`, `0b101`, `3e10`, `1.5E-3`, `.5`), and, on MySQL and MariaDB, `"double-quoted"` strings. `SqlStatement.mask/2` takes an optional `system:`, and database spans (including the `db_system:` option on `span/5` and `record_span/6`) and EXPLAIN plans pass their `db.system` to it.

## 0.13.0 (2026-09-25)

- Database spans now carry their SQL. Every span the Ecto integration records for a query has `"db.statement"` in its data, with every string and number replaced by `?` (capped at 4000 characters), and `"db.system"` (`postgresql`, `mysql`, `sqlite`, ...) from the repo's adapter. Query params are never sent.
- `ForgeOpsTracker.span/5` and `record_span/6` take `statement:` and `db_system:` options for a `"database"` span you time yourself; the statement is masked the same way.
- New opt-in `explain_slow_queries` (default `false`) and `explain_threshold_ms` (default `500`). When on, a single plain `SELECT` on a PostgreSQL repo that took at least the threshold gets an `EXPLAIN (FORMAT JSON)` (never `EXPLAIN ANALYZE`), run later in a `Task` started by the client's own supervised planner, on a pooled connection inside a `READ ONLY` transaction with a 2 second `statement_timeout`, then rolled back. The masked statement and the plan, with every string in it masked, are sent to ForgeOps. At most once per distinct statement every 10 minutes and 10 per minute. Any failure is logged and skipped.

## 0.12.0 (2026-09-25)

- `ForgeOpsTracker.record_change(kind, title, opts \\ [])` records one change to your system (a feature flag flipped, a config edit, a migration run) so ForgeOps can show it next to the errors that followed. `kind` is one of `:feature_flag`, `:config`, `:migration`, `:dependency`, `:infrastructure`, `:other` (atom or string; anything else is sent as `"other"`). Options: `:details`, `:environment` (defaults to the configured one), `:service`, `:actor`, `:url`, `:id` (an idempotency key), `:occurred_at`. Queued through the same delivery queue as error reports, so it never blocks the caller and never raises; a no-op when the client isn't enabled.
- Startup change snapshot: once the client is enabled (through `init/1`, or at application start when configured through `config.exs` or `FORGE_OPS_DSN`), a snapshot of the runtime (`elixir 1.18.4 / otp 27`) and every loaded OTP application with its version is sent once per VM from its own `Task`, never delaying or failing startup. ForgeOps records what changed since the previous snapshot for the same project and environment. Turn it off with `detect_changes: false`.
- `track_env_var_names` (default false) adds environment variable names, never values, to that snapshot, minus host-specific ones like `HOSTNAME`, `PATH`, `LC_*`, `KUBERNETES_*`, service discovery variables, and this client's own `FORGE_OPS_*`.
- A plan without change tracking answers 403; both calls treat that like any other failed delivery, silently.

## 0.11.0

- Distributed tracing across services, using the W3C Trace Context standard (`traceparent`). Every Phoenix request (with `ForgeOpsTracker.Integrations.Phoenix` attached) now gets a trace id; one that arrives with a valid `traceparent` header continues that trace, and its root span points at the caller's span. A missing or malformed header starts a fresh trace. `ForgeOpsTracker.current_trace_id/0` returns it, and `start_trace/1` takes an optional `traceparent` to continue one in work that isn't a request.
- Every error reported during a Phoenix request now says where it happened: `trace_id`, `transaction_name` (the same `GET /users/:id` name performance samples and traces already use), and `endpoint` (the HTTP method plus the route pattern as declared in the router; never the raw path). Set as soon as the router has matched the route, so an error captured from inside a controller already has them. An error captured inside an Oban job or your own trace carries `trace_id`. Left out outside a trace. Structured fields, so they're never PII-scrubbed.
- A request that crashes keeps that context: the crash is reported by the `:logger` handler only after the router's `:exception` event has already finished the request's trace, so the integration now remembers the request's context for that exception on its way out, and the crash report picks it up.
- `ForgeOpsTracker.http_span(method, url, data \\ %{}, fun)` records an outgoing HTTP call as an `http` span named after the method and host, and calls `fun` with the headers to add to it (`[{"traceparent", "00-..."}]`); its parent id is the span's own id, so the called service's root span nests under it. This client doesn't instrument an HTTP client itself. New `propagate_traces` (default true) and `trace_propagation_targets` (default nil, meaning every host; or a list of host strings, each matching that host and its subdomains, and/or `Regex`es) control where the header goes. `set_request_route/2` names a request yourself outside Phoenix.
- An errored request's trace is always sent, however fast it was: a crash, or any error captured with `capture_exception` while the request ran. An Oban job that fails for good is now reported before its trace is finished, so the report carries the job's trace id and the job's trace is sent too. Fast, successful requests are unchanged.
- With `track_tracing: false`, requests still get a trace id (attached to errors and handed out by `http_span`, since that is also what links errors across services); only span reporting stops.
- Trace and span ids were already W3C shaped (32 and 16 lowercase hex characters); they are now also guaranteed never to be all zeros, the one value the standard reserves as invalid.

This package has earlier Hex releases (see `mix.exs`'s own version history in source control), but no `CHANGELOG.md` existed for it before this entry; like `sdks/java`'s, it starts here without backfilling earlier versions.
