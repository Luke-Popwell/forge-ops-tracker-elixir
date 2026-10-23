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
    iban accountnumber routingnumber bankaccount
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

  # Card numbers in any other shape, and IBANs: see sdks/PII_SCRUBBING.md, which every SDK
  # follows, and sdks/pii_scrubbing_vectors.json (a copy is in test/fixtures), which pins the
  # results. Word characters and digits are spelled out as ASCII classes rather than `\b`, `\w`
  # or `\d`, so the rule never depends on how `:re` classifies bytes outside ASCII.
  @digit_run ~r/(?<![A-Za-z0-9_])[0-9](?:[ -]?[0-9])*(?![A-Za-z0-9_])/
  @card_prefixes ~r/\A(?:4|5[1-5]|2(?:22[1-9]|2[3-9][0-9]|[3-6][0-9][0-9]|7[01][0-9]|720)|3[47]|6011|64[4-9]|65|35(?:2[89]|[3-8][0-9])|36|30[0-5]|62)/
  @iban ~r/(?<![A-Za-z0-9_])[A-Z]{2}[0-9]{2}(?:[A-Z0-9]{11,30}|(?: [A-Z0-9]{4}){2,7}(?: [A-Z0-9]{1,4})?)(?![A-Za-z0-9_])/

  @doc """
  Runs every pattern above over a single string, independent of any key: used both directly (a
  message, a stack frame's file/method) and as the leaf case of `scrub/2` below. IBANs go first
  (a spaced IBAN's middle groups look like a formatted card number), then the patterns above, then
  card numbers in any other shape.
  """
  @spec scrub_string(String.t()) :: String.t()
  def scrub_string(text) when is_binary(text) do
    text =
      Regex.replace(@iban, text, fn candidate ->
        if iban?(candidate), do: "[IBAN FILTERED]", else: candidate
      end)

    text =
      Enum.reduce(@patterns, text, fn {label, pattern}, acc ->
        Regex.replace(pattern, acc, "[#{label} FILTERED]")
      end)

    Regex.replace(@digit_run, text, fn run -> scrub_card_numbers_in(run) end)
  end

  # From each group of the run on, the longest stretch of whole groups that is a card number is
  # replaced, so a card followed by its CVV, two cards in a row, and Amex's 4-6-5 are all found.
  defp scrub_card_numbers_in(run) do
    groups =
      Regex.split(~r/([ -])/, run, include_captures: true)
      |> Enum.chunk_every(2)
      |> Enum.map(fn
        [digits, separator] -> {digits, separator}
        [digits] -> {digits, ""}
      end)
      |> List.to_tuple()

    scrub_groups(groups, 0, tuple_size(groups), [])
  end

  defp scrub_groups(_groups, i, count, out) when i >= count do
    out |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp scrub_groups(groups, i, count, out) do
    found =
      Enum.find((count - 1)..i//-1, fn last ->
        i..last//1
        |> Enum.map(fn index -> elem(elem(groups, index), 0) end)
        |> Enum.join()
        |> card_number?()
      end)

    if found do
      {_, separator} = elem(groups, found)
      scrub_groups(groups, found + 1, count, [["[CREDIT CARD FILTERED]", separator] | out])
    else
      {digits, separator} = elem(groups, i)
      scrub_groups(groups, i + 1, count, [[digits, separator] | out])
    end
  end

  defp card_number?(digits) do
    byte_size(digits) in 13..19 and Regex.match?(@card_prefixes, digits) and luhn?(digits)
  end

  defp luhn?(digits) do
    sum =
      digits
      |> String.reverse()
      |> String.to_charlist()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {char, index}, acc ->
        value = char - ?0

        cond do
          rem(index, 2) == 0 -> acc + value
          value * 2 > 9 -> acc + value * 2 - 9
          true -> acc + value * 2
        end
      end)

    rem(sum, 10) == 0
  end

  # The IBAN check, a digit at a time: the first four characters moved to the end, letters as two
  # digits (A is 10), and the remainder by 97 is 1.
  defp iban?(candidate) do
    compact = String.replace(candidate, " ", "")

    if byte_size(compact) in 15..34 do
      <<head::binary-size(4), rest::binary>> = compact

      remainder =
        (rest <> head)
        |> String.to_charlist()
        |> Enum.flat_map(fn
          char when char in ?A..?Z -> Integer.to_charlist(char - 55)
          char -> [char]
        end)
        |> Enum.reduce(0, fn digit, r -> rem(r * 10 + (digit - ?0), 97) end)

      remainder == 1
    else
      false
    end
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
