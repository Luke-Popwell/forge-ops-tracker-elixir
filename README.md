# forge_ops_tracker (Elixir)

Elixir error reporting client for [ForgeOps](https://getforgeops.net).
Requires Elixir 1.18+ and an OTP install with `:inets`/`:ssl` (bundled with every standard OTP
install). Reports exceptions and process crashes anywhere in the BEAM VM, using OTP's own
supervision and logging primitives rather than anything bolted on from outside.

> For health or personal data, turn on [strict privacy](#strict-privacy): the SDK then sends only structured facts about each error (its type, stack trace, release and route), never the message, a raw path, breadcrumbs, or context you haven't allowed.

## Installation

```elixir
def deps do
  [
    {:forge_ops_tracker, "~> 0.18.1"}
  ]
end
```

## Configuration

Set a DSN (from a project's settings page in ForgeOps), either via the `FORGE_OPS_DSN` environment
variable, `config.exs`, or an explicit `init/1` call:

```elixir
# config/config.exs
config :forge_ops_tracker,
  dsn: "https://<api_key>@getforgeops.net/api/v1/events"
```

```elixir
# or, at application startup (application.ex's own start/2, before the rest of your
# supervision tree starts, is the natural place):
ForgeOpsTracker.init(dsn: "...")
ForgeOpsTracker.install_handlers()
```

`init/1` accepts the same keys as `ForgeOpsTracker.Configuration`'s struct fields and raises
`ArgumentError` for an unknown one, so a typo in a config key fails loudly at startup instead of
silently being ignored.

### Environments

Errors are only sent from the environments in `enabled_environments` (default `production` and
`staging`). The current environment is the first of these that's set:

1. `FORGE_OPS_ENVIRONMENT`
2. `config :forge_ops_tracker, environment: "..."` (or `init(environment: "...")`)
3. `MIX_ENV`, read as `"production"` for `prod`, `"development"` for `dev` and `"test"` for `test`
4. `Mix.env()`, read the same way, when the app is running under Mix (`mix run`, `iex -S mix`,
   `mix phx.server`, `mix test`)
5. `"production"`

So under Mix, `iex -S mix` or `mix phx.server` reports as `"development"` and sends nothing, the
same as before, while a Mix release, an escript or an `elixir` script (where Mix isn't running) with
nothing but a DSN reports as `"production"` and sends. To send a test error from your development
machine, run it with `FORGE_OPS_ENVIRONMENT=production`.

When a DSN is set but the environment isn't enabled, `init/1` logs one warning saying so, and
nothing is sent. To send from that environment too, add it:
`init(enabled_environments: MapSet.new(["production", "staging", "development"]))`.

## What gets reported automatically, and what doesn't

`install_handlers/0` attaches a standard `:logger_handler` (see
`ForgeOpsTracker.LoggerHandler`'s own module doc) that reports **any process crash anywhere in
the whole BEAM VM, with zero further wiring needed**: a `GenServer` callback that raises, an
unhandled message that trips `handle_info`'s catch-all, a linked process crashing another, any of
it. Erlang's own crash-reporting pipeline already forwards a structured `{reason, stacktrace}` for
every abnormal process exit into `:logger`, because that's simply how OTP's "let it crash"
supervision model already works. Attaching a handler observes that existing stream rather than
building a new one. An ordinary `Logger.error("something went wrong")` call from application code
(no crash attached) is deliberately left alone: reporting every error-level log line, not just
real crashes, would be far noisier than this client should be by default.

For an exception you've already rescued yourself and want to report explicitly (and typically
re-raise):

```elixir
try do
  charge_card(order)
rescue
  e ->
    ForgeOpsTracker.capture_exception(e, __STACKTRACE__, %{order_id: order.id})
    reraise e, __STACKTRACE__
end
```

`stacktrace` has to come from the actual rescue/catch site (`__STACKTRACE__`): an Elixir
exception value carries no trace of its own, so the special form is the only place a stacktrace is
available, and only for as long as nothing else has run since the rescue/catch.

Delivery runs through a supervised `ForgeOpsTracker.DeliveryQueue` `GenServer`: each push is
bounded (`Configuration.queue_size`, drops and logs rather than blocking the caller once full),
and the actual HTTP call for each delivery runs in its own short-lived `Task` rather than inline
in the `GenServer`'s own callback, so a slow or unreachable tracker never makes the queue itself
unresponsive to new pushes. Every failure mode (network errors, timeouts, a malformed DSN) is
caught and logged rather than propagated, so a broken tracker can never take down the host app.

An error reported just before the VM stops isn't lost. A `mix run` or `elixir` script, or an
escript, waits when it finishes for whatever is still queued to go out, and a VM stopped normally
(`System.stop/0`, a release shutting down, `Application.stop/1`) sends it from the queue's
`terminate/2`. Either way the wait is at most 5 seconds, and a VM that never reported anything
doesn't wait at all. If your program can end another way (`System.halt/1`), or you want delivery
done before moving on, call `ForgeOpsTracker.flush/1` yourself:

```elixir
ForgeOpsTracker.capture_exception(error, __STACKTRACE__)
ForgeOpsTracker.flush(2_000)  # milliseconds; returns :ok or {:error, :timeout}
```

## Identifying users

```elixir
ForgeOpsTracker.capture_exception(error, __STACKTRACE__, %{}, %{id: user.id, email: user.email})
```

Or `set_user/1` to attach it for the rest of the current process (a Phoenix request's own
connection process, a GenServer, an IEx session) rather than passing it to every
`capture_exception/4` call by hand:

```elixir
ForgeOpsTracker.set_user(%{id: conn.assigns.current_user.id, email: conn.assigns.current_user.email})
```

Stored in the process dictionary, the direct Elixir analog to `Thread.current` in
`gems/forge_ops_tracker`'s own equivalent: each Phoenix request already runs in its own process,
so this is naturally request-scoped with no extra cleanup needed. `id`/`email`/`username` are all
independently optional; call `set_user/1` with no arguments (or an empty map) to clear whatever
was set. Shows up on an issue's own detail page, and as its own affected-users count alongside the
regular event count. Also attached to a process crash `ForgeOpsTracker.LoggerHandler` reports
automatically (see "What gets reported automatically" above): confirmed directly that `:logger`
dispatches a crash report synchronously, in the crashing process's own context, so whatever
`set_user/1` last set there is exactly what a crash report for that same process picks up.

**Phoenix apps get this automatically**: add
`ForgeOpsTracker.Integrations.Phoenix.UserContextPlug` to your router's pipeline, after whatever
plug sets `conn.assigns[:current_user]`:

```elixir
pipeline :browser do
  ...
  plug :fetch_current_user
  plug ForgeOpsTracker.Integrations.Phoenix.UserContextPlug
end
```

`conn.assigns[:current_user]` is the de facto convention across Phoenix's own generated auth
(`mix phx.gen.auth`), Pow, and most hand-rolled Guardian setups alike, since Phoenix itself
(unlike Rails/Devise) has no single dominant auth library to depend on directly. `id` and `email`
are read as plain optional struct/map fields; `username` falls back to `name` if `username` itself
isn't present (`phx.gen.auth`'s own generated schema has neither by default, only `email`). A
no-op when `conn.assigns[:current_user]` is absent, or isn't a struct/map at all. Composes with the
manual API above rather than replacing it: call `set_user/1` yourself afterward (e.g. for a custom
auth setup this can't detect, or to override what was auto-detected) and it wins for the rest of
that process.

## Breadcrumbs

A bounded, ordered trail of what happened right before an exception: on by default, capped at the
30 most recent entries per process, both configurable:

```elixir
ForgeOpsTracker.init(track_breadcrumbs: false, max_breadcrumbs: 50) # defaults: true, 30
```

```elixir
ForgeOpsTracker.add_breadcrumb("charged card", "custom", "info", %{order_id: order.id})
```

`category` defaults to `"custom"` and `level` to `"info"`; `capture_exception/4` (an explicit
call, or `ForgeOpsTracker.LoggerHandler`'s own automatic crash reporting) attaches the calling
process's trail automatically, the same way it already attaches whatever `set_user/1` last set,
with no separate argument needed.

Stored in the process dictionary, the same isolation boundary `set_user/1` above already uses and
for the identical reason: each Phoenix request already runs in its own process, so a fresh trail
starts automatically with no cleanup needed there. A long-lived process handling more than one
logical unit of work on the same pid (a GenServer processing several casts, a LiveView socket
across several events) should call `clear_breadcrumbs/0` between them, or entries from an earlier
one will bleed into a later one's own report:

```elixir
ForgeOpsTracker.clear_breadcrumbs()
```

**Phoenix, Ecto, and Oban all record one automatically**, once attached (see "Performance
monitoring" below for `attach/0`/`attach/1`): a `"controller"` entry per matched route (message
`"METHOD route"`, level `"error"` on a 5xx response, `"info"` otherwise), a `"query"` entry per
Ecto query (message is the same `transaction_name` performance recording already uses), and a
`"job"` entry the moment an Oban job starts (`"started job WORKER"`). That last one is recorded at
job *start*, not alongside the duration at `:stop`/`:exception`: a job Oban ultimately discards
fires `:exception`, never `:stop`, so a breadcrumb only ever recorded at `:stop` would never make
it into that same job's own failure report, the identical design call `sdks/python`'s own Celery
integration and `sdks/php`'s own `Queue::before` already made.

## `in_app` backtrace frames

A frame is marked `in_app` when its module name (via `inspect/1`, which strips the `Elixir.`
prefix every Erlang-level module atom carries) starts with `Configuration.app_module_prefix`,
e.g. `"MyApp"` for an app whose modules are all namespaced under `MyApp.*`. Unset by default (no
frame is marked `in_app`), since a compiled BEAM release carries no reliable filesystem convention
to infer an application's own module prefix automatically.

## Source context

By default, each `in_app` backtrace frame (never a third-party dependency) is captured along with
the 5 lines of source on either side of the culprit line, read straight off disk at raise-time, so
an issue's detail page can show the actual code that broke, not just a `file:line` reference. This
never applies to a frame that isn't `in_app` (see above), and it fails silently (no context, not an
error) for any file that can't be read for whatever reason: deleted, permission denied, or simply
not present in this deployment, e.g. a release built without its own `.ex` sources bundled.

This is a real, deliberate exception to "off by default is safer": literal source code is being
transmitted, not just a reference to it, and the real protection here is not this flag. Every
project on ForgeOps has its own setting (on by default, off durably and immediately once an org
owner turns it off, regardless of what any individual app's own `capture_source_context` is still
set to) that governs whether the server will ever actually store what an SDK sends, see the in-app
help docs. Use this option if you'd rather this client never even attempt the disk read in the
first place:

```elixir
ForgeOpsTracker.init(capture_source_context: false)
```

## PII scrubbing

The message, backtrace, and any context you attach are scanned for likely personal data (email
addresses, formatted SSNs/credit cards, known API key/token formats, and anything under a
suspiciously-named key like `password`, `api_key`, or `ssn`) and redacted before the
payload ever leaves this process. ForgeOps itself scrubs again on arrival regardless, so this is a
second, earlier layer, not the only one. Elixir's `Regex` is full PCRE (via Erlang's `:re`), so
every pattern (including `\b` word boundaries) is supported as written. The user attached via the
fourth `capture_exception/4` argument or `set_user/1` above is a deliberate exception: it's never
scrubbed, since redacting it would defeat the whole point of identifying users in the first place.

To disable it:

```elixir
ForgeOpsTracker.init(scrub_pii: false)
```

## Strict privacy

For apps that can't let personal or health data (PII, PHI) leave their own servers. With strict
privacy on, an error is sent as structured facts only, never free text a person could have typed:

- no message: a `message_fingerprint` is sent instead, a one-way hash of the message (as PII
  scrubbing leaves it) with its numbers, hex ids and UUIDs taken out, computed in this VM, so
  errors still group by message;
- no breadcrumbs (`add_breadcrumb/4` records nothing), no `endpoint`, no SQL statement
  (`sql_objects`, the table and procedure names, still go), and no source context;
- the user's `id` only, never an email or username;
- `context` and `tags` keep only the keys you list in `privacy_allowed_fields`, and only when the
  value is a string, number or boolean. Atom keys match too (`%{error_code: "E42"}` is kept when
  `"error_code"` is allowed).

Spans are reduced too: an outbound HTTP span is named by method and host alone
(`GET api.example.com`), and span data keeps only `db.statement` (already masked) and `db.system`. A
raw path (one with no route parameter like `:id` or `{id}` in it) keeps only its first segment, then
`/:path` if there was more, since anything after it can name a person: `/patients/jane-doe/12` is
sent as `/patients/:path`, `/42/edit` as `/:id/:path`. A route template (`/patients/:id/notes`) is
sent as it is, so reporting routes rather than raw paths loses nothing. That applies to span names
and to the transaction name in error events and performance samples; the Phoenix integration already
reports route templates, and a worker name is kept as it is. The exception class, stack frames,
release, environment, server and trace id are unchanged, as are metrics, query plans and change
snapshots. A failed Oban job is reported like any other error, so its `job` context key is only sent
when you allow it.

```elixir
# config/config.exs
config :forge_ops_tracker,
  strict_privacy: true,
  privacy_allowed_fields: ["error_code", "feature"]
```

or `ForgeOpsTracker.init(strict_privacy: true, privacy_allowed_fields: ["error_code"])`. Both are
off and empty by default, and can be set from the environment instead:
`FORGE_OPS_STRICT_PRIVACY=true` and `FORGE_OPS_PRIVACY_ALLOWED_FIELDS=error_code,feature` (comma
separated). A value set in `config.exs` or `init/1` wins over the environment.

ForgeOps applies the same rules again on arrival when the project's own Strict privacy setting is
on, so an app with an older or misconfigured client still can't get text stored for that project.

## Performance monitoring

Times requests, database queries, and background jobs, each its own `kind`
(`"controller"`/`"query"`/`"job"`) on the same aggregate `performance` dataset, so "slowest
queries" and "slowest jobs" are just a filtered version of the same widget builder "slowest
transactions" already uses. Unlike error reporting, this needs an explicit `attach` call per
integration, since which of Phoenix/Ecto/Oban are actually in use varies by app:

Each aggregate also carries a small latency histogram (a count per fixed latency bucket: 50, 100,
250, 500, 1000, 2500, 5000 and 10000ms, plus an overflow bucket), so ForgeOps can show an
approximate p50/p95/p99 per transaction, not just an average. Percentiles are accurate to the width
of whichever bucket a duration falls into; the SDK never stores the individual durations.

```elixir
# application.ex's own start/2, before the rest of your supervision tree starts:
ForgeOpsTracker.Integrations.Phoenix.attach()
ForgeOpsTracker.Integrations.Ecto.attach(MyApp.Repo)
ForgeOpsTracker.Integrations.Oban.attach()
```

- **Phoenix**: every matched route (`kind: "controller"`), bucketed by `"<HTTP method> <route
  pattern>"` (e.g. `"GET /users/:id"`, not the literal path, so a distinct user id doesn't explode
  into its own separate transaction).
- **Ecto**: every query run through the given repo (`kind: "query"`), bucketed by `"<VERB>
  <table>"` (`"SELECT users"`, `"INSERT INTO orders"`), not the raw SQL text: a low-cardinality
  name, and never a literal value even where a query's own parameters aren't already
  placeholder-bound. Call `attach/1` once per repo if the app has more than one.
- **Oban**: every job (`kind: "job"`), bucketed by the worker's own module name. This is also this
  SDK's only error-reporting integration for Oban: a job whose retries are genuinely exhausted (or
  that explicitly returns `:discard`) is reported the same way an unhandled exception anywhere else
  already is, with the worker name attached as context, no separate wiring needed. A job that fails
  but still has retries left is timed but not reported as an error, since it hasn't actually failed
  yet.

Buckets flush as a small periodic aggregate report every `performance_flush_interval` (60 seconds
by default) rather than one network call per event:

```elixir
ForgeOpsTracker.init(
  track_performance: false,        # opt out entirely
  performance_flush_interval: 30_000  # milliseconds; default 60_000
)
```

Requires a ForgeOps plan that includes performance monitoring; on a plan that doesn't, the periodic
reports are accepted but not recorded, and the response says why.

Requires the optional `:telemetry` dependency (see Dependencies below); a host app using Phoenix,
Ecto, or Oban already carries it transitively, since all three depend on it themselves.

## Distributed tracing

A slow request's or job's own breakdown: which database queries or pieces of your code the time
went to, shown as a span tree on ForgeOps. On by default once the integrations above are attached,
no extra setup: `ForgeOpsTracker.Integrations.Phoenix` opens a trace per request (root span named
like the transaction), `Oban` one per job (`kind: "job"`), and `Ecto` adds a `"database"` span per
query into whichever trace the calling process has open, named `"SELECT users"` and carrying the
masked SQL (see [SQL on database spans](#sql-on-database-spans)). A
trace is sent to `/spans` when its root took at least `trace_capture_threshold` milliseconds (1000
by default) or when an error was captured during it, so fast, successful requests cost nothing on
the wire.

Outbound HTTP is not instrumented automatically (every HTTP client library has its own telemetry
events), so wrap a call by hand (for HTTP, prefer `http_span/4`, below), alongside anything else
you want to see:

```elixir
order = ForgeOpsTracker.span("charge card", "service", %{order_id: id}, fn -> charge(id) end)
rates = ForgeOpsTracker.span("fetch rates", "http", fn -> Req.get!(url) end)

# Something you timed yourself (kind is one of controller/service/database/redis/http/job/other;
# started_at is a DateTime):
ForgeOpsTracker.record_span("SELECT orders", "database", started_at, duration_ms)
```

`span/4` nests under whichever span is open in the same process, records even when the function
raises (the error propagates unchanged), and just runs the function outside a trace. Like
breadcrumbs and `set_user/1`, the trace lives in the process dictionary, so it follows the one
process Phoenix and Oban run the work in, not a `Task` you spawn from it. To trace something else,
such as a GenServer message, call `ForgeOpsTracker.start_trace/1` and `finish_trace/4` yourself. A
trace holds at most 500 spans. Turn span reporting off with `track_tracing: false`.

### SQL on database spans

Every database span the Ecto integration records carries the query's SQL as `db.statement`, with
every string and number replaced by `?`, plus `db.system` (`postgresql`, `mysql`, `sqlite`, and so
on, from the repo's adapter). Query params are never sent. That includes escaped and prefixed
strings (`E'o\'brien'`, `X'DEADBEEF'`), hex, binary and exponent numbers (`0x1F`, `0b101`,
`1.5E-3`), and, on MySQL and MariaDB (where `"double quotes"` hold a string, not a name),
double-quoted strings. So a slow request's waterfall shows which query was slow, not only which
table:

```
SELECT u0."id", u0."total" FROM "orders" AS u0 WHERE (u0."customer_id" = $1) AND (u0."status" = ?)
```

A query you time yourself (a driver this client doesn't instrument, or `Postgrex` directly) can
carry its SQL too. Pass `:statement` (and optionally `:db_system`) to `span/5` or `record_span/6`
for a `"database"` span; it's masked the same way:

```elixir
sql = "SELECT id, total FROM orders WHERE customer_id = $1 AND status = 'paid'"

rows =
  ForgeOpsTracker.span("Load orders", "database", %{}, [statement: sql, db_system: "postgresql"], fn ->
    Postgrex.query!(MyApp.Postgrex, sql, [customer_id]).rows
  end)

# The span's data: %{"db.statement" => "SELECT id, total FROM orders WHERE customer_id = $1 AND status = ?",
#                    "db.system" => "postgresql"}
```

### Query plans for slow PostgreSQL queries (opt-in)

With `explain_slow_queries: true`, a slow read on a PostgreSQL repo also gets its query plan, so
ForgeOps can show why it was slow (a sequential scan, a missing index) next to the query:

```elixir
ForgeOpsTracker.init(
  explain_slow_queries: true,  # default false
  explain_threshold_ms: 500    # milliseconds; default 500
)
```

What it does:

- Only for a query that took at least `explain_threshold_ms`, through a repo attached with
  `ForgeOpsTracker.Integrations.Ecto.attach/1` whose adapter is `Ecto.Adapters.Postgres`.
- Only for a single plain `SELECT`: never a write, a statement with a second statement after it, a
  `SELECT ... FOR UPDATE`/`FOR SHARE`, or a `WITH` query that modifies data.
- Runs `EXPLAIN (FORMAT JSON)`, never `EXPLAIN ANALYZE`, so the query itself is not run again. It
  runs later, in a `Task` started by the client's own supervised planner process (not by your
  process, so it never shares your connection or transaction), on a connection checked out of the
  repo's pool, inside a `READ ONLY` transaction with a 2 second `statement_timeout` that is always
  rolled back.
- At most once per distinct query every 10 minutes, at most 10 per minute, and one at a time.
- Sends the masked statement and the plan with every string in it masked the same way (a plan's
  `Filter` repeats the query's values). Your params are used for the `EXPLAIN` and then dropped;
  they are never sent. A plan over 64 KB is dropped.

What it doesn't do: it doesn't run for MySQL, SQLite, or any other adapter. It briefly uses one
connection from your pool while it runs, so if the pool is exhausted it waits for one like any
other checkout and gives up on a timeout. Any failure (a timeout, a permission error, no free
connection) is logged through your `logger` and skipped; it never raises into your app. The
database user needs no extra privileges beyond being able to run the query. Plans are stored only
for projects with performance monitoring; otherwise ForgeOps quietly declines them.

### Following a request across services

Traces use the [W3C Trace Context](https://www.w3.org/TR/trace-context/) standard (a `traceparent`
header), so an error or a slow call can be followed from one service into the next.

**Incoming**: automatic with the Phoenix integration. A request that arrives with a valid
`traceparent` header continues that trace (same trace id), and its root span records the caller's
span as its parent. A missing or malformed header just starts a new trace.

**Outgoing**: wrap each HTTP call you make during a request in `http_span/4`. It records the call
as an `"http"` span named after the method and host (never the path or query) and hands your
function the headers to add, a list of `{name, value}` tuples; the header's parent id is that span's
own id, so the called service's spans nest under it. It works with any HTTP client, records the
span even when the call raises (the error propagates unchanged), and returns what your function
returned:

```elixir
response =
  ForgeOpsTracker.http_span("POST", url, fn headers ->
    Req.post!(url, json: order, headers: headers)
  end)

# An optional data map comes before the function, like span/4's:
ForgeOpsTracker.http_span(:get, url, %{attempt: 2}, fn headers ->
  :get |> Finch.build(url, headers) |> Finch.request(MyFinch)
end)
```

Outside a trace your function gets `[]` and nothing is recorded, so the same code works anywhere.
`ForgeOpsTracker.current_trace_id/0` returns the calling process's trace id, for your own logs. To
continue a trace in work that isn't a request (a job carrying the header it was enqueued with,
say), pass that header to `ForgeOpsTracker.start_trace/1`.

A trace id exists for every request even with `track_tracing: false`, and the header is still
sent, since the trace id is also what links an error here to an error in the service you called
(see [Where an error happened](#where-an-error-happened)); only span reporting stops. The service on
the other end must also report to ForgeOps, and both projects must be linked in ForgeOps to see
their errors and traces connected.

Narrow or turn off where the header goes, for example if a third-party API rejects unknown headers:

```elixir
ForgeOpsTracker.init(
  dsn: "...",
  # never send traceparent (default true)
  propagate_traces: false,
  # Default nil: every host. A string matches that host and its subdomains on a dot boundary
  # ("internal.example" matches "orders.internal.example", not "notinternal.example"); a Regex is
  # matched against the host.
  trace_propagation_targets: ["internal.example", ~r/\A10\.0\./]
)
```

### Where an error happened

An error reported during a Phoenix request (a crash, or your own `capture_exception/4` from inside
the controller) carries three extra fields:

- `transaction_name`: the same name performance monitoring and traces use, `"GET /users/:id"`.
- `endpoint`: the HTTP method and the route as declared in your router, `"GET /users/:id"`. Never
  the literal path, so an id or a token in the URL never ends up here.
- `trace_id`: the request's W3C trace id, which ForgeOps uses to link this error to errors that
  other services reported for the same trace.

They're set as soon as the router has matched the route, before your pipeline and controller run.
An error captured inside an Oban job, or inside your own `start_trace/1`, carries `trace_id` only.
They're left out entirely outside a trace, and they're never PII-scrubbed: they're structured
fields, not free text. A request that crashes keeps them even though the crash is only reported
after Phoenix's router has finished with the request: the integration remembers them for that
exception on its way out.

## Custom metrics and infrastructure monitoring

Two explicit calls (nothing is automatic, so there is no `track_metrics` option): a business event you
name yourself, and a reading from one of your own hosts.

```elixir
ForgeOpsTracker.capture_metric("signup")          # value defaults to 1.0: a bare counter
ForgeOpsTracker.capture_metric("payment", 49.0)   # a real magnitude; it may be negative (a refund)

ForgeOpsTracker.capture_infrastructure_metric("cpu", 0.42)          # hostname defaults to server_name
ForgeOpsTracker.capture_infrastructure_metric("disk", 0.81, "db-1")
ForgeOpsTracker.flush_metrics()                                     # optional: send right now
```

Each capture is buffered in a supervised `GenServer` (one per kind) and flushed as one batch every
`metric_flush_interval` / `infrastructure_metric_flush_interval` milliseconds (60,000 by default), and
once more from `terminate/2` on a normal supervised shutdown, so a short-lived cron script that
captures a few readings and lets the VM stop needs nothing more; call `flush_metrics/0` if it might
exit another way (`System.halt/1`). Every entry is stored as it was captured (a signup is a row, not a
running total), so a count or sum you compute later is exact. Both are a no-op when the client isn't
enabled for the environment.

A delivery that fails for now (a network error, a timeout, a 5xx, a 408 or a 429) keeps every entry
for the next flush, and an entry captured while a delivery is in flight simply waits in the server's
mailbox and is handled right after, so nothing is lost. A batch the server rejects (any other 4xx,
such as the 403 a plan without the feature answers) is dropped rather than sent again, and so is one
that has failed 5 flushes in a row. The buffer holds at most 1000 entries per kind and drops further
ones until a flush lets go of them. A non-numeric value is dropped at capture. Requires a ForgeOps plan that includes custom metrics /
infrastructure monitoring.

## Recording changes

Tell ForgeOps when something changes, so it shows up next to the errors that followed:

```elixir
ForgeOpsTracker.record_change(:feature_flag, "Enabled new checkout",
  details: %{flag: "new_checkout", rollout: 25},
  actor: "alice@example.com"
)

ForgeOpsTracker.record_change(:migration, "Add index on orders.user_id",
  url: "https://github.com/acme/shop/pull/412",
  id: "20260925120000"   # optional idempotency key
)
```

`kind` is one of `:feature_flag`, `:config`, `:migration`, `:dependency`, `:infrastructure`,
`:other` (anything else is sent as `"other"`). Other options: `:environment` (defaults to the
configured one), `:service`, `:occurred_at` (a `DateTime`, defaults to now). Like error reports,
it's queued and delivered in the background, never raises, and does nothing when the client isn't
enabled.

The client also sends one snapshot per VM at startup: the runtime and every loaded OTP application
with its version. ForgeOps compares it with the previous one for the same environment and records
what changed, so a dependency upgrade shows up without any call from you. It's sent from its own
`Task`, so it never delays or breaks startup.

```elixir
ForgeOpsTracker.init(
  dsn: "...",
  environment: "production",
  detect_changes: true,        # default true; false sends no snapshot
  track_env_var_names: true    # default false; adds variable names (never values)
)
```

With `track_env_var_names` on, host-specific names (`HOSTNAME`, `PATH`, `HOME`, `LC_*`,
`KUBERNETES_*`, service discovery variables, `FORGE_OPS_*` and similar) are left out so a fleet of
identical nodes doesn't look like it's changing. Requires a ForgeOps plan that includes change
tracking; on other plans both are dropped silently.

## Dependencies

No required Hex dependencies. HTTP delivery uses `:httpc`/`:ssl` (bundled with every OTP install,
not a Hex package, with `ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]` for
proper TLS certificate verification); JSON encoding uses Elixir's own `JSON` module, part of the
standard library since 1.18 (this SDK's real version floor, not an arbitrary pin); PII scrubbing
uses Elixir's built-in `Regex`. Two optional dependencies: `:telemetry`, needed only by
`ForgeOpsTracker.Integrations.Phoenix`/`Ecto`/`Oban` (see Performance monitoring above), and
`:plug`, needed only by `ForgeOpsTracker.Integrations.Phoenix.UserContextPlug` (see Identifying
users above), since it's a real `Plug` module compiled directly against `Plug.Conn`/the `Plug`
behaviour. A host app using Phoenix already carries both transitively; nothing else here needs a
dependency the standard library doesn't already cover.

## Database errors

When an error carries the SQL behind a failed database call, the event includes the names of the stored procedure, table and view that SQL touched, so the issue tells you where to start looking. This is on by default and sends identifiers only, never values. The statement is read from a `:statement`, `:sql` or `:query` field on the exception struct, which covers `Postgrex.Error` and `MyXQL.Error`.

To also send the SQL statement itself, opt in. Every string and number is replaced by `?` before it
leaves your process (`WHERE email = 'a@b.co' AND id = 42` is sent as `WHERE email = ? AND id = ?`),
and ForgeOps masks it again on arrival:

```elixir
ForgeOpsTracker.init(capture_sql_statement: true)   # default false
# ForgeOpsTracker.init(capture_sql_objects: false)  # default true; false stops even the names
```

Each ForgeOps project also has its own "Capture the SQL behind database errors" setting. Turn it off
there and the statement is never stored for that project, whatever this flag says; the names are
still kept. A view and a table are written the same way in SQL, so both show as tables/views; the
database's own error message usually settles which it was.

## Running the tests

```bash
cd sdks/elixir
mix deps.get   # fetches :telemetry (needed by the Integrations.* tests) and the dev-only ex_doc
mix test
mix format --check-formatted
mix compile --warnings-as-errors
```

Client/DeliveryQueue/Reporter/LoggerHandler tests run against a real local HTTP server
(`test/support/test_http_server.ex`, a small hand-rolled `:gen_tcp`-based server) rather than a
mock, so delivery is verified against something real rather than an assumption about how the HTTP
client behaves.
