defmodule ForgeOpsTracker.QueryNaming do
  @moduledoc """
  A low-cardinality bucket name for a database query, for the same reason every other SDK's own
  `transaction_name` never uses the raw SQL text directly: every slightly different query shape
  would become its own bucket, and raw SQL is a real, if usually parameterized, risk of leaking a
  literal value.

  `source` (the table name) is passed separately from `sql`, not extracted from it, because
  `Ecto.Adapters.SQL`'s own `[:query]` telemetry event already hands over the table name directly
  in `metadata.source` for any query built from `Ecto.Query`, the common case: no regex needed
  there at all, unlike every other language's own DB integration in this repo so far. `source` is
  only `nil` for a raw SQL call (`Ecto.Adapters.SQL.query!/4` and friends), which is where the
  regex fallback below, a direct port of the identical one already written for the Python and PHP
  SDKs this session, actually does something: extracts "<VERB> <table>" ("SELECT auth_user",
  "INSERT INTO orders") for the two shapes that carry a table name in a predictable place, falling
  back to just the first SQL keyword ("PRAGMA", "BEGIN") for anything else, or the literal string
  "SQL" if even that fails.
  """

  @select_delete ~r/^\s*(SELECT|DELETE)\b.*?\bFROM\s+["'`]?(\w+)/is
  @insert_update ~r/^\s*(INSERT INTO|UPDATE)\s+["'`]?(\w+)/i

  @spec transaction_name(String.t(), String.t() | nil) :: String.t()
  def transaction_name(sql, source \\ nil)

  def transaction_name(sql, source) when is_binary(source) and source != "" do
    "#{first_word(sql)} #{source}"
  end

  def transaction_name(sql, _source) do
    case Regex.run(@select_delete, sql) || Regex.run(@insert_update, sql) do
      [_match, verb, table] -> "#{String.upcase(verb)} #{table}"
      nil -> first_word(sql)
    end
  end

  # The first whitespace-delimited word, upcased: the table name is already known via `source`
  # when this is called from the branch above (only SELECT vs. INSERT/UPDATE/DELETE is left to
  # determine), and it's the fallback itself, one level down, for the no-table-found branch.
  defp first_word(sql) do
    case String.trim(sql) do
      "" -> "SQL"
      trimmed -> trimmed |> String.split(~r/\s/, parts: 2) |> hd() |> String.upcase()
    end
  end
end
