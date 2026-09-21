defmodule ForgeOpsTracker.PiiScrubber do
  @moduledoc """
  Redacts likely-sensitive content out of a payload before it ever leaves this process: the
  same patterns ForgeOps itself applies again on arrival (defense in depth: this layer keeps the
  data off the wire and out of any request logging in between; the server-side layer is what
  actually protects the database, and doesn't depend on every reporting app running an up-to-date
  version of this client). Ported from
  `gems/forge_ops_tracker/lib/forge_ops_tracker/pii_scrubber.rb`: same key list, same 8 regex
  patterns, unmodified from the Ruby original: Elixir's `Regex` is Erlang's `:re` module, itself a
  PCRE implementation, so unlike this repo's own C client (which had to adapt every pattern to
  POSIX Extended Regular Expressions: no `\\d`/`\\s`/`\\b`), nothing here needed translating.

  Can be turned off via `Configuration.scrub_pii = false` for a host app that already scrubs its
  own data before it ever reaches error context, or that has its own reasons to want the raw
  payload. Off by default is not an option: the safe default has to be "on."
  """

  @redacted "[FILTERED]"
  def redacted, do: @redacted

  @sensitive_keys ~w(
    password passwd pwd
    secret apisecret clientsecret secretkey
    token accesstoken refreshtoken apikey apitoken authorization authtoken bearer
    sessiontoken csrftoken
    creditcard cardnumber cardnum cvv cvv2 cvc
    ssn socialsecuritynumber socialsecurity
    privatekey
  )

  @patterns [
    {"EMAIL", ~r/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/},
    {"SSN", ~r/\b\d{3}-\d{2}-\d{4}\b/},
    {"CREDIT CARD", ~r/\b\d{4}[ -]\d{4}[ -]\d{4}[ -]\d{1,4}\b/},
    {"BEARER TOKEN", ~r/\bBearer\s+[A-Za-z0-9\-._~+\/]+=*/i},
    {"JWT", ~r/\bey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/},
    {"AWS KEY", ~r/\bAKIA[0-9A-Z]{16}\b/},
    {"STRIPE KEY", ~r/\b[sr]k_(?:live|test)_[A-Za-z0-9]{10,}\b/},
    {"GITHUB TOKEN", ~r/\bgh[pousr]_[A-Za-z0-9]{20,}\b/}
  ]

  @doc """
  Runs every pattern above over a single string, independent of any key: used both directly (a
  message, a stack frame's file/method) and as the leaf case of `scrub/2` below.
  """
  @spec scrub_string(String.t()) :: String.t()
  def scrub_string(text) when is_binary(text) do
    Enum.reduce(@patterns, text, fn {label, pattern}, acc ->
      Regex.replace(pattern, acc, "[#{label} FILTERED]")
    end)
  end

  @doc """
  Redacts `value` based on `key` (an entire value redacted wholesale if key looks sensitive,
  regardless of type) and recurses into maps/lists, matching every other client's behavior in this
  repo. `key` is the enclosing map key `value` was found under (`nil` for a bare top-level value
  or a list element), and is what the key-name check runs against.
  """
  @spec scrub(term(), String.t() | atom() | nil) :: term()
  def scrub(value, key \\ nil)

  def scrub(value, key) when not is_nil(value) do
    if sensitive_key?(key) do
      @redacted
    else
      do_scrub(value)
    end
  end

  def scrub(value, _key), do: value

  defp do_scrub(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, scrub(v, k)} end)
  end

  defp do_scrub(value) when is_list(value) do
    Enum.map(value, &do_scrub_list_item/1)
  end

  defp do_scrub(value) when is_binary(value), do: scrub_string(value)
  defp do_scrub(value), do: value

  # A list element has no key of its own (matches every other client's "key is nil for an array
  # element" behavior): do_scrub, not scrub, since scrub's sensitive-key check would otherwise
  # run again against whatever key the *list itself* was found under, incorrectly propagating it
  # to every element.
  defp do_scrub_list_item(value), do: do_scrub(value)

  defp sensitive_key?(nil), do: false

  defp sensitive_key?(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "")

    Enum.any?(@sensitive_keys, &String.contains?(normalized, &1))
  end
end
