defmodule ForgeOpsTracker.Client do
  @moduledoc """
  Delivers one payload over HTTP via `:httpc` (Erlang's own HTTP client, part of the `:inets`
  application bundled with every OTP install: no Hex dependency needed, same reasoning as
  `net/http` in the Ruby gem and `java.net.http.HttpClient` in the Java/Kotlin clients). Every
  failure mode (DNS, connection, timeout, TLS, a non-2xx response) is caught here and turned
  into `false` rather than a raised exception, since a broken or unreachable tracker must never be
  able to break the host app.

  Every `deliver*` function answers `true` only when the payload was delivered. The `attempt_*`
  functions next to the batch ones answer a `ForgeOpsTracker.DeliveryStatus` instead, which is what
  tells a flusher whether a batch that did not go out is worth another attempt.
  """

  alias ForgeOpsTracker.{Configuration, DeliveryStatus}

  @spec deliver(Configuration.t(), map()) :: boolean()
  def deliver(%Configuration{} = config, payload),
    do: deliver_to(config, Configuration.ingestion_uri(config), payload)

  # Same delivery contract as deliver/2, its own sibling endpoint under the same DSN (see
  # Configuration.performance_samples_uri/1); samples is a list of the small aggregate reports
  # ForgeOpsTracker.PerformanceFlusher batches up, delivered as one request rather than one call
  # per bucket, matching PerformanceSamplesController's own batch-shaped ingestion contract.
  @spec deliver_performance_samples(Configuration.t(), [map()]) :: boolean()
  def deliver_performance_samples(%Configuration{} = config, samples),
    do: attempt_performance_samples(config, samples) == :delivered

  @spec attempt_performance_samples(Configuration.t(), [map()]) :: DeliveryStatus.t()
  def attempt_performance_samples(%Configuration{} = config, samples),
    do: attempt(config, Configuration.performance_samples_uri(config), %{samples: samples})

  # Delivers a batch of individual capture_metric/2 entries as %{metrics: [...]}, and infrastructure
  # readings the same way (see ForgeOpsTracker.MetricBuffer).
  @spec deliver_metrics(Configuration.t(), [map()]) :: boolean()
  def deliver_metrics(%Configuration{} = config, entries),
    do: attempt_metrics(config, entries) == :delivered

  @spec attempt_metrics(Configuration.t(), [map()]) :: DeliveryStatus.t()
  def attempt_metrics(%Configuration{} = config, entries),
    do: attempt(config, Configuration.custom_metrics_uri(config), %{metrics: entries})

  @spec deliver_infrastructure_metrics(Configuration.t(), [map()]) :: boolean()
  def deliver_infrastructure_metrics(%Configuration{} = config, entries),
    do: attempt_infrastructure_metrics(config, entries) == :delivered

  @spec attempt_infrastructure_metrics(Configuration.t(), [map()]) :: DeliveryStatus.t()
  def attempt_infrastructure_metrics(%Configuration{} = config, entries),
    do: attempt(config, Configuration.infrastructure_metrics_uri(config), %{metrics: entries})

  # Delivers one finished trace, %{trace_id: ..., spans: [...]}, to the DSN's spans endpoint.
  @spec deliver_spans(Configuration.t(), map()) :: boolean()
  def deliver_spans(%Configuration{} = config, trace),
    do: deliver_to(config, Configuration.spans_uri(config), trace)

  # One explicit change (ForgeOpsTracker.record_change/3) and the startup change snapshot, each to
  # its own sibling endpoint. A 403 (a plan without change tracking) is just a false return here,
  # like any other non-2xx.
  @spec deliver_change(Configuration.t(), map()) :: boolean()
  def deliver_change(%Configuration{} = config, change),
    do: deliver_to(config, Configuration.changes_uri(config), change)

  @spec deliver_change_snapshot(Configuration.t(), map()) :: boolean()
  def deliver_change_snapshot(%Configuration{} = config, snapshot),
    do: deliver_to(config, Configuration.change_snapshots_uri(config), snapshot)

  # One EXPLAIN plan for a slow query (see ForgeOpsTracker.QueryPlanner). A project without
  # performance monitoring answers 403, which is just a false return here like any other non-2xx.
  @spec deliver_query_plan(Configuration.t(), map()) :: boolean()
  def deliver_query_plan(%Configuration{} = config, plan),
    do: deliver_to(config, Configuration.query_plans_uri(config), plan)

  defp deliver_to(config, uri, payload), do: attempt(config, uri, payload) == :delivered

  # One POST, answered as a DeliveryStatus. No DSN (so no uri or api key) is :failed, not
  # :rejected: nothing was refused, there was nowhere to send it.
  defp attempt(config, uri, payload) do
    with uri when is_binary(uri) <- uri,
         api_key when is_binary(api_key) <- Configuration.api_key(config) do
      request(config, uri, api_key, payload)
    else
      _ -> :failed
    end
  end

  defp request(config, uri, api_key, payload) do
    body = JSON.encode!(payload)

    headers = [
      {~c"Authorization", String.to_charlist("Bearer #{api_key}")},
      {~c"Content-Type", ~c"application/json"}
    ]

    http_options = [
      timeout: config.timeout,
      connect_timeout: config.timeout,
      # Verifying the tracker's own TLS certificate is the correct default for delivering
      # potentially sensitive event payloads: deliberately not made configurable down to
      # verify_none, the same "no easy footgun" stance the other clients in this repo take by
      # simply having no such option at all.
      ssl: ssl_options(uri)
    ]

    case :httpc.request(
           :post,
           {String.to_charlist(uri), headers, ~c"application/json", body},
           http_options,
           []
         ) do
      {:ok, {{_http_version, code, _reason_phrase}, _headers, _body}} ->
        status = DeliveryStatus.for_code(code)
        log_status(config, status, code)
        status

      {:error, reason} ->
        Configuration.log(config, "[forge_ops_tracker] delivery failed: #{inspect(reason)}")
        :failed
    end
  rescue
    e ->
      Configuration.log(
        config,
        "[forge_ops_tracker] delivery failed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      :failed
  end

  defp log_status(_config, :delivered, _code), do: :ok

  defp log_status(config, :rejected, code) do
    Configuration.log(
      config,
      "[forge_ops_tracker] delivery rejected: HTTP #{code}, the server will not accept a retry"
    )
  end

  defp log_status(config, :failed, code),
    do: Configuration.log(config, "[forge_ops_tracker] delivery failed: HTTP #{code}")

  # The trust store is only read for an https DSN (:httpc ignores these options for http anyway).
  # :public_key.cacerts_get/0 loads the :public_key application the first time it runs, which fails
  # while the VM is stopping applications: a plain http DSN (a local or test endpoint) should never
  # depend on that during DeliveryQueue's shutdown drain.
  defp ssl_options("https" <> _), do: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
  defp ssl_options(_uri), do: []
end
