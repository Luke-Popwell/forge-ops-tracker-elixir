defmodule ForgeOpsTracker.SqlStatement do
  @moduledoc """
  Finds the SQL behind a database error and reduces it to something safe to send: the names of
  the stored procedures, tables and views it touched, and (only if
  `capture_sql_statement` is on) the statement itself with every string and number replaced by
  `?`. Ported from gems/forge_ops_tracker's `SqlStatement`, which is itself ported from the
  server's own `SqlStatementMasker`/`SqlObjectExtractor`: same rules everywhere, and the server
  applies them again on arrival, so a difference here can only ever mean less is masked
  client-side, never that something unmasked gets stored.

  Deliberately a single pass over a few patterns, not a SQL parser.
  """

  @mask "?"
  @max_length 4000
  @max_names 10
  @max_name_length 200

  @literal ~r/'(?:[^']|'')*(?:'|\z)|(?<tag>\$[A-Za-z_]*\$).*?(?:\k<tag>|\z)|(?<![\w$.])\d+(?:\.\d+)?(?!\w)/s

  @part ~S{(?:[\w$#@]+|"[^"]+"|\[[^\]]+\]|`[^`]+`)}
  @name @part <> ~S{(?:\.} <> @part <> ")*"
  @operations ~w(SELECT INSERT UPDATE DELETE MERGE WITH CALL EXEC EXECUTE CREATE ALTER DROP TRUNCATE)
  @procedure_call Regex.compile!(
                    ~S{\b(?:CALL|EXEC(?:UTE)?|PERFORM)\s+(?!IMMEDIATE\b|FUNCTION\b|PROCEDURE\b)(} <>
                      @name <> ")",
                    "i"
                  )
  @relation Regex.compile!(~S{\b(FROM|JOIN|INTO|UPDATE|TABLE)\s+(} <> @name <> ~S{)(\s*\()?}, "i")
  @select_function Regex.compile!(~S{\A\s*SELECT\s+(} <> @name <> ~S{)\s*\(}, "i")
  @builtins ~w(count sum min max avg now coalesce nullif lower upper length concat cast date_trunc
               current_timestamp current_date row_number rank json_build_object json_agg array_agg)
  @from_inside_function ~r/\b(?:EXTRACT|SUBSTRING|TRIM|OVERLAY)\s*\([^()]*\)/i
  @keywords_not_names ~w(select set values where lateral only unnest generate_series)
  @full_name Regex.compile!(~S{\A} <> @name <> ~S{\z})
  @from_word ~r/\bFROM\b/i

  # Fields the Elixir database drivers put the failing statement on: MyXQL.Error and Exqlite.Error
  # use :statement, Postgrex.Error uses :query (a string, or a %Postgrex.Query{} whose own
  # :statement holds it). Read generically off any exception struct, so this client never depends
  # on a driver.
  @statement_fields [:statement, :sql, :query]

  @doc """
  The raw statement off the exception itself, or `nil` when it carries none.
  """
  @spec find_in(term()) :: String.t() | nil
  def find_in(reason) when is_map(reason) do
    Enum.find_value(@statement_fields, fn field -> statement_from(Map.get(reason, field)) end)
  end

  def find_in(_reason), do: nil

  defp statement_from(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  # A %Postgrex.Query{}: its :statement is iodata.
  defp statement_from(%{statement: statement}) when is_binary(statement) or is_list(statement) do
    statement |> IO.iodata_to_binary() |> statement_from()
  rescue
    ArgumentError -> nil
  end

  defp statement_from(_other), do: nil

  @spec mask(String.t() | nil) :: String.t() | nil
  def mask(statement) when is_binary(statement) do
    if String.trim(statement) == "" do
      nil
    else
      masked = Regex.replace(@literal, statement, @mask)

      if String.length(masked) > @max_length,
        do: String.slice(masked, 0, @max_length) <> "...",
        else: masked
    end
  end

  def mask(_statement), do: nil

  @doc """
  Takes an already-masked statement (so a keyword inside a string value can't be mistaken for
  SQL). Returns `nil` when nothing recognizable was found.
  """
  @spec objects(String.t() | nil) :: map() | nil
  def objects(masked) when is_binary(masked) do
    if String.trim(masked) == "" do
      nil
    else
      sql = Regex.replace(@from_inside_function, masked, " ")

      calls = for [_, name] <- Regex.scan(@procedure_call, sql), do: name

      {procedures, relations} =
        @relation
        |> Regex.scan(sql)
        |> Enum.reduce({Enum.reverse(calls), []}, fn [_, keyword, name | rest], {procs, rels} ->
          cond do
            String.downcase(name) in @keywords_not_names ->
              {procs, rels}

            rest != [] and hd(rest) != "" and String.upcase(keyword) in ["FROM", "JOIN"] ->
              {[name | procs], rels}

            true ->
              {procs, [name | rels]}
          end
        end)

      procedures = Enum.reverse(procedures)
      relations = Enum.reverse(relations)

      procedures =
        case Regex.run(@select_function, sql) do
          [_, function] ->
            if String.downcase(function) not in @builtins and not Regex.match?(@from_word, sql),
              do: procedures ++ [function],
              else: procedures

          _ ->
            procedures
        end

      operation =
        case Regex.run(~r/\A\s*(\w+)/, sql) do
          [_, word] -> String.upcase(word)
          _ -> ""
        end

      result = if operation in @operations, do: %{"operation" => operation}, else: %{}

      result =
        Map.merge(result, %{"procedures" => clean(procedures), "relations" => clean(relations)})

      if result["procedures"] == [] and result["relations"] == [] and
           not Map.has_key?(result, "operation"),
         do: nil,
         else: result
    end
  end

  def objects(_masked), do: nil

  defp clean(names) do
    names
    |> Enum.map(&(&1 |> String.trim() |> String.slice(0, @max_name_length)))
    |> Enum.filter(&Regex.match?(@full_name, &1))
    |> Enum.uniq()
    |> Enum.take(@max_names)
  end
end
