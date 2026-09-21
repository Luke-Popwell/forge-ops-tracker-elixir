defmodule ForgeOpsTracker.Client do
  @moduledoc """
  Delivers one payload over HTTP via `:httpc` (Erlang's own HTTP client, part of the `:inets`
  application bundled with every OTP install: no Hex dependency needed, same reasoning as
  `net/http` in the Ruby gem and `java.net.http.HttpClient` in the Java/Kotlin clients). Every
  failure mode (DNS, connection, timeout, TLS, a non-2xx response) is caught here and turned
  into `false` rather than a raised exception, since a broken or unreachable tracker must never be
  able to break the host app.
  """

  alias ForgeOpsTracker.Configuration

  @spec deliver(Configuration.t(), map()) :: boolean()
  def deliver(%Configuration{} = config, payload) do
    with uri when is_binary(uri) <- Configuration.ingestion_uri(config),
         api_key when is_binary(api_key) <- Configuration.api_key(config) do
      request(config, uri, api_key, payload)
    else
      _ -> false
    end
  end

  # Same delivery contract as deliver/2, its own sibling endpoint under the same DSN (see
  # Configuration.performance_samples_uri/1); samples is a list of the small aggregate reports
  # ForgeOpsTracker.PerformanceFlusher batches up, delivered as one request rather than one call
  # per bucket, matching PerformanceSamplesController's own batch-shaped ingestion contract.
  @spec deliver_performance_samples(Configuration.t(), [map()]) :: boolean()
  def deliver_performance_samples(%Configuration{} = config, samples) do
    with uri when is_binary(uri) <- Configuration.performance_samples_uri(config),
         api_key when is_binary(api_key) <- Configuration.api_key(config) do
      request(config, uri, api_key, %{samples: samples})
    else
      _ -> false
    end
  end

  # Delivers a batch of individual capture_metric/2 entries as %{metrics: [...]}, and infrastructure
  # readings the same way (see ForgeOpsTracker.MetricBuffer).
  @spec deliver_metrics(Configuration.t(), [map()]) :: boolean()
  def deliver_metrics(%Configuration{} = config, entries),
    do: deliver_batch(config, Configuration.custom_metrics_uri(config), entries)

  @spec deliver_infrastructure_metrics(Configuration.t(), [map()]) :: boolean()
  def deliver_infrastructure_metrics(%Configuration{} = config, entries),
    do: deliver_batch(config, Configuration.infrastructure_metrics_uri(config), entries)

  defp deliver_batch(config, uri, entries) do
    with uri when is_binary(uri) <- uri,
         api_key when is_binary(api_key) <- Configuration.api_key(config) do
      request(config, uri, api_key, %{metrics: entries})
    else
      _ -> false
    end
  end

  # Delivers one finished trace, %{trace_id: ..., spans: [...]}, to the DSN's spans endpoint.
  @spec deliver_spans(Configuration.t(), map()) :: boolean()
  def deliver_spans(%Configuration{} = config, trace) do
    with uri when is_binary(uri) <- Configuration.spans_uri(config),
         api_key when is_binary(api_key) <- Configuration.api_key(config) do
      request(config, uri, api_key, trace)
    else
      _ -> false
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
      ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
    ]

    case :httpc.request(
           :post,
           {String.to_charlist(uri), headers, ~c"application/json", body},
           http_options,
           []
         ) do
      {:ok, {{_http_version, status, _reason_phrase}, _headers, _body}} ->
        status >= 200 and status < 300

      {:error, reason} ->
        Configuration.log(config, "[forge_ops_tracker] delivery failed: #{inspect(reason)}")
        false
    end
  rescue
    e ->
      Configuration.log(
        config,
        "[forge_ops_tracker] delivery failed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      false
  end
end
