defmodule ForgeOpsTracker.QueryPlans do
  @moduledoc """
  The pure pieces of the opt-in EXPLAIN (see `ForgeOpsTracker.QueryPlanner`): which statements are
  safe to EXPLAIN, the rate limits, masking a plan, and building the `POST /api/v1/query_plans`
  body. Also the `db.system` name for an Ecto adapter, and the data a database span carries.
  """

  alias ForgeOpsTracker.{Configuration, SqlStatement}

  @statement_timeout "2s"
  @max_plan_bytes 65_536
  @per_statement_ms 600_000
  @max_per_minute 10

  # One pass over the statement, leftmost match wins, so a quote inside a comment or a comment
  # marker inside a string can't hide anything: string literals (including dollar-quoted ones)
  # become "?", line and block comments become a space.
  @literals_and_comments ~r/'(?:[^']|'')*(?:'|\z)|(?<tag>\$[A-Za-z_]*\$).*?(?:\k<tag>|\z)|(?<comment>--[^\n]*|\/\*.*?(?:\*\/|\z))/s
  @starts_with_select ~r/\A\s*SELECT\b/i
  @locking_clause ~r/\bFOR\s+(?:NO\s+KEY\s+UPDATE|UPDATE|KEY\s+SHARE|SHARE)\b/i
  @data_modifying ~r/\b(?:INSERT|UPDATE|DELETE|MERGE)\b/i

  @adapters %{
    "Ecto.Adapters.Postgres" => "postgresql",
    "Ecto.Adapters.MyXQL" => "mysql",
    "Ecto.Adapters.SQLite3" => "sqlite",
    "Ecto.Adapters.Tds" => "mssql"
  }

  @doc "The `SET LOCAL statement_timeout` value the EXPLAIN runs under."
  @spec statement_timeout() :: String.t()
  def statement_timeout, do: @statement_timeout

  @doc "The largest serialized plan that's sent; a bigger one is dropped."
  @spec max_plan_bytes() :: pos_integer()
  def max_plan_bytes, do: @max_plan_bytes

  @doc """
  The lowercase `db.system` for an Ecto adapter module (`Ecto.Adapters.Postgres` is
  `"postgresql"`, `MyXQL` is `"mysql"`, `SQLite3` is `"sqlite"`, `Tds` is `"mssql"`) or a name
  given as a string, or `nil` when unknown.
  """
  @spec db_system(module() | String.t() | nil) :: String.t() | nil
  def db_system(nil), do: nil

  def db_system(name) when is_binary(name) do
    case name |> String.trim() |> String.downcase() do
      "" -> nil
      "postgres" -> "postgresql"
      "pgsql" -> "postgresql"
      other -> other
    end
  end

  def db_system(adapter) when is_atom(adapter) do
    name = inspect(adapter)
    Map.get(@adapters, name) || name |> String.split(".") |> List.last() |> db_system()
  end

  def db_system(_other), do: nil

  @doc "The db system of an Ecto repo, from its adapter; `nil` when it can't be told."
  @spec repo_db_system(module() | nil) :: String.t() | nil
  def repo_db_system(repo) when is_atom(repo) and not is_nil(repo) do
    if Code.ensure_loaded?(repo) and function_exported?(repo, :__adapter__, 0),
      do: db_system(repo.__adapter__())
  end

  def repo_db_system(_repo), do: nil

  @doc """
  `data` plus `"db.statement"` (already masked) and `"db.system"`, each only when known.
  """
  @spec span_data(String.t() | nil, String.t() | module() | nil, map()) :: map()
  def span_data(masked_statement, db_system, data \\ %{}) do
    data = if masked_statement, do: Map.put(data, "db.statement", masked_statement), else: data

    case db_system(db_system) do
      nil -> data
      system -> Map.put(data, "db.system", system)
    end
  end

  @doc """
  The masked statement a database span carries as `"db.statement"`: `SqlStatement.mask/2`, capped
  at exactly 4000 characters. `db_system` (an adapter module or a name, as `db_system/1` takes) is
  passed on so a MySQL or MariaDB query's "double quoted" strings are masked too.
  """
  @spec mask_for_span(String.t() | nil, String.t() | module() | nil) :: String.t() | nil
  def mask_for_span(statement, db_system \\ nil) do
    case SqlStatement.mask(statement, system: db_system(db_system)) do
      nil -> nil
      masked -> String.slice(masked, 0, 4000)
    end
  end

  @doc """
  Whether a statement is safe to EXPLAIN: after comments and leading whitespace it starts with
  SELECT, has no second statement (no `;` except one at the very end), no locking clause (`FOR
  UPDATE`, `FOR SHARE`, `FOR NO KEY UPDATE`, `FOR KEY SHARE`), and no INSERT, UPDATE, DELETE or
  MERGE anywhere (a data-modifying CTE).
  """
  @spec explainable?(String.t() | nil) :: boolean()
  def explainable?(statement) when is_binary(statement) do
    sql =
      Regex.replace(@literals_and_comments, statement, fn match, _tag, comment ->
        if comment != "" and match == comment, do: " ", else: "?"
      end)

    body = sql |> String.trim_trailing() |> String.replace_suffix(";", "")

    Regex.match?(@starts_with_select, sql) and not String.contains?(body, ";") and
      not Regex.match?(@locking_clause, sql) and not Regex.match?(@data_modifying, sql)
  end

  def explainable?(_statement), do: false

  @doc """
  Every string in the plan masked with `SqlStatement.mask/1` (a plan's `"Filter"` or
  `"Index Cond"` repeats the query's literals); numbers, keys and structure unchanged.
  """
  @spec mask_plan(term()) :: term()
  def mask_plan(value) when is_binary(value), do: SqlStatement.mask(value) || value
  def mask_plan(value) when is_list(value), do: Enum.map(value, &mask_plan/1)

  def mask_plan(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, item} -> {key, mask_plan(item)} end)

  def mask_plan(value), do: value

  @doc """
  The `POST /api/v1/query_plans` body, or `nil` when the plan isn't usable (not the JSON array
  Postgres returns) or its serialized form is over 64 KB. `plan` is that JSON text or already
  decoded.
  """
  @spec payload(Configuration.t(), String.t(), String.t(), term(), number(), DateTime.t()) ::
          map() | nil
  def payload(config, masked_statement, db_system, plan, duration_ms, %DateTime{} = captured_at) do
    with {:ok, [_ | _] = plan} <- decode(plan),
         plan = mask_plan(plan),
         {:ok, encoded} <- encode(plan),
         true <- byte_size(encoded) <= @max_plan_bytes do
      %{
        statement: masked_statement,
        db_system: db_system,
        plan: plan,
        duration_ms: Float.round(duration_ms * 1.0, 2),
        environment: config.environment,
        captured_at: captured_at |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
      }
    else
      _ -> nil
    end
  end

  defp decode(plan) when is_binary(plan), do: JSON.decode(plan)
  defp decode(plan) when is_list(plan), do: {:ok, plan}
  defp decode(_plan), do: :error

  defp encode(plan) do
    {:ok, JSON.encode!(plan)}
  rescue
    _ -> :error
  end

  @typedoc "Rate limit state: last EXPLAIN time per masked statement, and recent EXPLAIN times."
  @type limits :: %{statements: %{String.t() => integer()}, recent: [integer()]}

  @doc "Empty rate limit state."
  @spec new_limits() :: limits()
  def new_limits, do: %{statements: %{}, recent: []}

  @doc """
  Whether `key` (a masked statement) may be EXPLAINed at `now_ms` (a monotonic millisecond time):
  each key at most once per 10 minutes, and at most 10 per rolling minute overall. Returns the
  decision and the updated state.
  """
  @spec allow(limits(), String.t(), integer()) :: {boolean(), limits()}
  def allow(%{statements: statements, recent: recent}, key, now_ms) do
    statements = Map.filter(statements, fn {_key, at} -> now_ms - at < @per_statement_ms end)
    recent = Enum.filter(recent, &(now_ms - &1 < 60_000))
    state = %{statements: statements, recent: recent}

    cond do
      Map.has_key?(statements, key) -> {false, state}
      length(recent) >= @max_per_minute -> {false, state}
      true -> {true, %{statements: Map.put(statements, key, now_ms), recent: [now_ms | recent]}}
    end
  end
end
