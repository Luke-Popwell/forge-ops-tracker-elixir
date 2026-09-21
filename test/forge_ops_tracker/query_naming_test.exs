defmodule ForgeOpsTracker.QueryNamingTest do
  use ExUnit.Case, async: true

  alias ForgeOpsTracker.QueryNaming

  test "uses the given source directly, deriving only the verb from the sql" do
    assert QueryNaming.transaction_name("SELECT u0.\"id\" FROM \"users\" AS u0", "users") ==
             "SELECT users"

    assert QueryNaming.transaction_name("INSERT INTO \"orders\" (\"id\") VALUES ($1)", "orders") ==
             "INSERT orders"
  end

  test "extracts the table from a select with a where clause when no source is given" do
    sql = ~s(SELECT "auth_user"."id" FROM "auth_user" WHERE "auth_user"."id" = $1)

    assert QueryNaming.transaction_name(sql) == "SELECT auth_user"
  end

  test "extracts the table from a delete" do
    sql = ~s(DELETE FROM "sessions" WHERE "sessions"."id" = $1)

    assert QueryNaming.transaction_name(sql) == "DELETE sessions"
  end

  test "extracts the table from an insert" do
    sql = ~s{INSERT INTO "orders" ("id", "total") VALUES ($1, $2)}

    assert QueryNaming.transaction_name(sql) == "INSERT INTO orders"
  end

  test "extracts the table from an update" do
    sql = ~s(UPDATE "orders" SET "total" = $1 WHERE "orders"."id" = $2)

    assert QueryNaming.transaction_name(sql) == "UPDATE orders"
  end

  test "extracts the table regardless of quoting style" do
    assert QueryNaming.transaction_name("SELECT * FROM users WHERE id = $1") == "SELECT users"
    assert QueryNaming.transaction_name("SELECT * FROM `users` WHERE id = $1") == "SELECT users"
  end

  test "falls back to the first keyword when no table name is found" do
    assert QueryNaming.transaction_name("SELECT 1") == "SELECT"
    assert QueryNaming.transaction_name("BEGIN") == "BEGIN"
    assert QueryNaming.transaction_name("begin") == "BEGIN"
  end

  test "falls back to a literal SQL for a blank string" do
    assert QueryNaming.transaction_name("") == "SQL"
    assert QueryNaming.transaction_name("   ") == "SQL"
  end
end
