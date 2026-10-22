defmodule ForgeOpsTracker.SqlStatementTest do
  use ExUnit.Case, async: true

  alias ForgeOpsTracker.{Configuration, EventBuilder, SqlStatement}

  # Stand in for Postgrex.Error (:query as a string or a %Postgrex.Query{}) and MyXQL.Error
  # (:statement), without depending on either driver.
  defmodule FakePostgrexError do
    defexception message: "boom", query: nil
  end

  defmodule FakeMyxqlError do
    defexception message: "boom", statement: nil
  end

  defp build(reason, overrides \\ %{}) do
    config = struct(%Configuration{environment: "production"}, overrides)
    EventBuilder.build(config, reason, [])
  end

  describe "find_in/1" do
    test "reads :query (a string or a query struct) and :statement off the exception" do
      assert SqlStatement.find_in(%FakePostgrexError{query: "SELECT 1"}) == "SELECT 1"

      assert SqlStatement.find_in(%FakePostgrexError{query: %{statement: ["SELECT ", "2"]}}) ==
               "SELECT 2"

      assert SqlStatement.find_in(%FakeMyxqlError{statement: "SELECT 3"}) == "SELECT 3"
    end

    test "returns nil without SQL" do
      assert SqlStatement.find_in(%RuntimeError{message: "nope"}) == nil
      assert SqlStatement.find_in(%FakePostgrexError{query: "  "}) == nil
      assert SqlStatement.find_in(:not_a_struct) == nil
    end
  end

  # The server's canonical masking cases ({statement, db.system, expected}), copied in whole so
  # every SDK's port is checked against exactly the same set.
  @corpus [
    {"SELECT * FROM orders WHERE email = 'a@b.co' AND id = 42 LIMIT 10", nil,
     "SELECT * FROM orders WHERE email = ? AND id = ? LIMIT ?"},
    {"EXEC sp_note @text = 'it''s broken'", nil, "EXEC sp_note @text = ?"},
    {"SELECT 1 WHERE name = 'unterminated", nil, "SELECT ? WHERE name = ?"},
    {"DO $body$ BEGIN PERFORM 1; END $body$", nil, "DO ?"},
    {"SELECT \"user id\" FROM orders2 WHERE id = $1 AND v = sp_v2(?)", nil,
     "SELECT \"user id\" FROM orders2 WHERE id = $1 AND v = sp_v2(?)"},
    {"SELECT price * 1.5 FROM t", nil, "SELECT price * ? FROM t"},
    {"SELECT * FROM users WHERE name = E'o\\'brien' AND id = 1", nil,
     "SELECT * FROM users WHERE name = ? AND id = ?"},
    {"SELECT * FROM users WHERE name = 'o\\'brien' AND id = 1", nil,
     "SELECT * FROM users WHERE name = ? AND id = ?"},
    {"SELECT * FROM t WHERE b = X'DEADBEEF' AND s = N'uni' AND u = U&'d\\0061t' AND e = e'x'",
     nil, "SELECT * FROM t WHERE b = ? AND s = ? AND u = ? AND e = ?"},
    {"SELECT * FROM t WHERE a LIKE'%secret%'", nil, "SELECT * FROM t WHERE a LIKE?"},
    {"SELECT * FROM t WHERE f = 0x1F AND b = 0b101 AND n = 3e10 AND m = 1.5E-3 AND k = .5", nil,
     "SELECT * FROM t WHERE f = ? AND b = ? AND n = ? AND m = ? AND k = ?"},
    {"SELECT e, t.col, 1e5e FROM t", nil, "SELECT e, t.col, 1e5e FROM t"},
    {"SELECT \"user id\" FROM t WHERE token = \"abc123secret\"", "mysql",
     "SELECT ? FROM t WHERE token = ?"},
    {"SELECT \"user id\" FROM t WHERE token = \"abc123secret\"", "MariaDB",
     "SELECT ? FROM t WHERE token = ?"},
    {"SELECT \"user id\" FROM t WHERE token = \"abc123secret\"", "postgresql",
     "SELECT \"user id\" FROM t WHERE token = \"abc123secret\""},
    {"SELECT \"user id\" FROM t WHERE token = \"abc123secret\"", nil,
     "SELECT \"user id\" FROM t WHERE token = \"abc123secret\""},
    {"SELECT * FROM t WHERE a = 'x' AND b = 9", nil, "SELECT * FROM t WHERE a = ? AND b = ?"},
    {"SELECT * FROM t WHERE a = ? AND b = ?", nil, "SELECT * FROM t WHERE a = ? AND b = ?"},
    {"SELECT * FROM t WHERE path = 'C:\\\\dir\\\\' AND n = 5", nil,
     "SELECT * FROM t WHERE path = ? AND n = ?"},
    {"INSERT INTO t (a, b) VALUES (-5, +3.25e+2)", nil, "INSERT INTO t (a, b) VALUES (-?, +?)"},
    {"SELECT * FROM t WHERE a = 'secret\\", nil, "SELECT * FROM t WHERE a = ?"},
    {"SELECT * FROM t WHERE a = \"secret\\", "mysql", "SELECT * FROM t WHERE a = ?"}
  ]

  describe "mask/2 against the server's cases" do
    for {{statement, system, expected}, index} <- Enum.with_index(@corpus) do
      @statement statement
      @system system
      @expected expected

      test "case #{index}: #{statement}" do
        assert SqlStatement.mask(@statement, system: @system) == @expected
        assert SqlStatement.mask(@expected, system: @system) == @expected
      end
    end
  end

  describe "mask/1" do
    test "replaces strings and numbers, leaving identifiers and placeholders" do
      assert SqlStatement.mask(
               "SELECT * FROM orders2 WHERE email = 'a@b.co' AND id = 42 AND x = $1"
             ) == "SELECT * FROM orders2 WHERE email = ? AND id = ? AND x = $1"

      assert SqlStatement.mask("SELECT price * 1.5 FROM t") == "SELECT price * ? FROM t"
    end

    test "handles an escaped quote, a cut-off string and a dollar-quoted body" do
      assert SqlStatement.mask("EXEC sp_x @t = 'it''s'") == "EXEC sp_x @t = ?"
      assert SqlStatement.mask("SELECT 1 WHERE n = 'oops") == "SELECT ? WHERE n = ?"
      assert SqlStatement.mask("DO $b$ BEGIN PERFORM 1; END $b$") == "DO ?"
    end

    test "is idempotent, truncates, and returns nil for blank input" do
      once = SqlStatement.mask("SELECT * FROM t WHERE a = 'x' AND b = 9")
      assert SqlStatement.mask(once) == once

      assert String.length(SqlStatement.mask("SELECT " <> String.duplicate("a, ", 3000) <> " b")) ==
               4003

      assert SqlStatement.mask("  ") == nil
      assert SqlStatement.mask(nil) == nil
    end
  end

  describe "objects/1" do
    test "finds a stored procedure with its schema" do
      assert SqlStatement.objects("EXEC dbo.sp_refund_order @id = ?") ==
               %{
                 "operation" => "EXEC",
                 "procedures" => ["dbo.sp_refund_order"],
                 "relations" => []
               }

      assert SqlStatement.objects("CALL refund_order(?, ?)")["procedures"] == ["refund_order"]
      assert SqlStatement.objects("SELECT refund_order(?, ?)")["procedures"] == ["refund_order"]
    end

    test "finds views, joined tables and table functions" do
      assert SqlStatement.objects(
               "SELECT * FROM v_totals t JOIN public.customers c ON c.id = t.id"
             )[
               "relations"
             ] == ["v_totals", "public.customers"]

      assert SqlStatement.objects("SELECT * FROM get_open_orders(?) o")["procedures"] ==
               ["get_open_orders"]
    end

    test "does not misread column lists or builtins, and returns nil for garbage" do
      assert SqlStatement.objects("INSERT INTO audit_log (a) VALUES (?)")["procedures"] == []
      assert SqlStatement.objects("SELECT count(*) FROM orders")["procedures"] == []
      assert SqlStatement.objects("garbage") == nil
    end
  end

  describe "EventBuilder" do
    defp error do
      %FakePostgrexError{query: "EXEC dbo.sp_refund_order @order_id = 8814, @note = 'a@b.co'"}
    end

    test "sends the procedure name but not the statement by default" do
      payload = build(error())
      assert payload["sql_objects"]["procedures"] == ["dbo.sp_refund_order"]
      refute Map.has_key?(payload, "sql_statement")
    end

    test "sends the masked statement when opted in, and nothing when both are off" do
      assert build(error(), %{capture_sql_statement: true})["sql_statement"] ==
               "EXEC dbo.sp_refund_order @order_id = ?, @note = ?"

      off = build(error(), %{capture_sql_objects: false})
      refute Map.has_key?(off, "sql_objects")
      refute Map.has_key?(off, "sql_statement")
      refute Map.has_key?(build(%RuntimeError{message: "nope"}), "sql_objects")
    end
  end
end
