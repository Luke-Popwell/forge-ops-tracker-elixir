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
