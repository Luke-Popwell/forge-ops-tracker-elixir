defmodule ForgeOpsTracker.Integrations.Phoenix.UserContextPlugTest do
  # async: false: reads/writes ForgeOpsTracker's own process-dictionary current-user state, which
  # (being process-scoped, not shared) is naturally test-isolated regardless, but the module's
  # own conventions elsewhere in this file mirror LoggerHandlerTest's async: false for consistency
  # with tests that do share state.
  use ExUnit.Case, async: false

  alias ForgeOpsTracker.Integrations.Phoenix.UserContextPlug

  defmodule FakeUser do
    defstruct [:id, :email, :username, :name]
  end

  setup do
    on_exit(fn -> ForgeOpsTracker.set_user(%{}) end)
    :ok
  end

  test "attaches the current user's id/email/username to the process when present" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.assign(:current_user, %FakeUser{
        id: 42,
        email: "ada@example.com",
        username: "ada"
      })

    result = UserContextPlug.call(conn, UserContextPlug.init([]))

    assert result == conn
    assert ForgeOpsTracker.current_user() == %{id: 42, email: "ada@example.com", username: "ada"}
  end

  test "falls back to name when username is not present, the phx.gen.auth-shaped case" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.assign(:current_user, %FakeUser{id: 42, name: "Ada Lovelace"})

    UserContextPlug.call(conn, UserContextPlug.init([]))

    # email is nil here (FakeUser's own default), and set_user/1 already strips nil values
    # (see its own doc comment), so it's absent from the map entirely, not present-and-nil.
    assert ForgeOpsTracker.current_user() == %{id: 42, username: "Ada Lovelace"}
  end

  test "does nothing when conn.assigns has no current_user at all" do
    conn = Plug.Test.conn(:get, "/")

    UserContextPlug.call(conn, UserContextPlug.init([]))

    assert ForgeOpsTracker.current_user() == nil
  end

  test "never raises when current_user is assigned to something that isn't a struct or map" do
    conn = Plug.Test.conn(:get, "/") |> Plug.Conn.assign(:current_user, "not-a-struct")

    result = UserContextPlug.call(conn, UserContextPlug.init([]))

    assert result == conn
    assert ForgeOpsTracker.current_user() == nil
  end
end
