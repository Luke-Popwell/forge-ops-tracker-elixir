defmodule ForgeOpsTracker.PiiScrubberTest do
  use ExUnit.Case, async: true

  alias ForgeOpsTracker.PiiScrubber

  test "redacts an email address embedded in free text" do
    assert PiiScrubber.scrub_string("contact user@example.com for help") ==
             "contact [EMAIL FILTERED] for help"
  end

  test "redacts a formatted credit card but leaves an ordinary long numeric id alone" do
    refute PiiScrubber.scrub_string("charged card 4242-4242-4242-4242 successfully") ==
             "charged card 4242-4242-4242-4242 successfully"

    text = "order id 1234567890123456"
    assert PiiScrubber.scrub_string(text) == text
  end

  test "redacts a formatted ssn" do
    assert PiiScrubber.scrub_string("ssn on file: 123-45-6789") == "ssn on file: [SSN FILTERED]"
  end

  test "redacts known api key and token formats" do
    cases = [
      "Authorization: Bearer abc123DEF.456-xyz",
      "aws key AKIAABCDEFGHIJKLMNOP in use",
      "stripe key sk_live_abcdefghijklmnop",
      "github token ghp_abcdefghijklmnopqrstuvwxyz0123456789",
      "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dQw4w9WgXcQ"
    ]

    for text <- cases do
      refute PiiScrubber.scrub_string(text) == text, "expected #{inspect(text)} to be redacted"
    end
  end

  test "redacts whole value under sensitive key regardless of type or casing" do
    assert PiiScrubber.scrub(12345, "apiKey") == PiiScrubber.redacted()
    assert PiiScrubber.scrub("hunter2", "X-Api-Key") == PiiScrubber.redacted()
  end

  test "recurses into maps and lists" do
    input = %{
      "password" => "hunter2",
      "note" => "email me at user@example.com",
      "items" => [%{"token" => "abc"}, "visit user@example.com"]
    }

    scrubbed = PiiScrubber.scrub(input)

    assert scrubbed["password"] == PiiScrubber.redacted()
    assert scrubbed["note"] == "email me at [EMAIL FILTERED]"
    [first, second] = scrubbed["items"]
    assert first["token"] == PiiScrubber.redacted()
    assert second == "visit [EMAIL FILTERED]"
  end

  test "sensitive key check ignores case and punctuation" do
    for key <- ["API_KEY", "Api-Key", "apiKey", "X-Api-Key"] do
      assert PiiScrubber.scrub("value", key) == PiiScrubber.redacted(),
             "expected #{key} to be treated as sensitive"
    end

    assert PiiScrubber.scrub("bob", "username") == "bob"
  end
end
