defmodule ForgeOpsTracker.Integrations.Phoenix.UserContextPlug do
  @moduledoc """
  Automatically identifies the affected user for every error reported during this request, when
  `conn.assigns[:current_user]` is present: the de facto convention across Phoenix's own generated
  auth (`mix phx.gen.auth`), Pow, and most hand-rolled Guardian setups alike, since Phoenix itself
  (unlike Rails/Devise) has no single dominant auth library this could depend on directly.

  Add to your router's pipeline, after whatever plug actually sets
  `conn.assigns[:current_user]` (`phx.gen.auth`'s own `fetch_current_user`, Pow's
  `Pow.Plug.Session`, or your own):

      pipeline :browser do
        ...
        plug :fetch_current_user
        plug ForgeOpsTracker.Integrations.Phoenix.UserContextPlug
      end

  Duck-types rather than assuming a specific schema: `id` and `email` as plain optional
  struct/map fields, and `username` falling back to `name` if `username` itself isn't present
  (Ecto's own generated `phx.gen.auth` schema has neither by default, only `email`, so both are
  genuinely optional here, not just formally so). A struct/map missing some of these just gets
  whatever subset applies, the same "duck-type, don't require a specific shape" approach every
  other framework auto-detection in this repo takes for its own language's dominant auth
  convention.

  Stores into the process dictionary via `ForgeOpsTracker.set_user/1`, the same "one process per
  request" isolation Phoenix itself already gives every request (see that function's own doc): no
  explicit cleanup plug is needed the way a thread-pool-reusing server would need, since this
  connection's own process is discarded once the request finishes, never returned to a pool and
  reused for an unrelated later request the way a Puma/Tomcat worker thread would be.

  Never raises back into the request: a `conn.assigns[:current_user]` that isn't a map or struct
  at all (an unusual custom auth setup) just means this is a no-op, not a broken request.
  """

  @behaviour Plug

  alias ForgeOpsTracker.Configuration

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Map.get(conn.assigns, :current_user) do
      nil -> conn
      user -> attach_user(conn, user)
    end
  end

  defp attach_user(conn, user) do
    ForgeOpsTracker.set_user(%{
      id: field(user, :id),
      email: field(user, :email),
      username: field(user, :username) || field(user, :name)
    })

    conn
  rescue
    e ->
      Configuration.log(
        Configuration.get(),
        "[forge_ops_tracker] UserContextPlug failed to read the current user: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      conn
  end

  defp field(%{} = user, key), do: Map.get(user, key)
  defp field(_user, _key), do: nil
end
