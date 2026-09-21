defmodule ForgeOpsTracker.ConfigurationTest do
  # async: false: Configuration is a single named GenServer, shared process-wide (started once
  # by ForgeOpsTracker.Application), not a fresh instance per test the way a plain struct would
  # be; concurrent tests mutating it via update/1 would race each other.
  use ExUnit.Case, async: false

  alias ForgeOpsTracker.Configuration

  setup do
    on_exit(fn -> Configuration.update(fn _ -> %Configuration{} end) end)
    :ok
  end

  describe "pure functions over a plain struct" do
    test "api_key and ingestion_uri" do
      config = %Configuration{dsn: "https://abc123@forgeops.example/api/v1/events"}

      assert Configuration.api_key(config) == "abc123"
      assert Configuration.ingestion_uri(config) == "https://forgeops.example/api/v1/events"
    end

    test "api_key url-decodes the userinfo" do
      config = %Configuration{dsn: "https://ab%2Fc@forgeops.example/api/v1/events"}

      assert Configuration.api_key(config) == "ab/c"
    end

    test "empty or malformed dsn has no api_key or ingestion_uri" do
      for dsn <- [nil, "", "not-a-url"] do
        config = %Configuration{dsn: dsn}
        assert Configuration.api_key(config) == nil, "dsn = #{inspect(dsn)}"
        assert Configuration.ingestion_uri(config) == nil, "dsn = #{inspect(dsn)}"
      end
    end

    test "dsn with no userinfo has no api_key but still has an ingestion_uri" do
      config = %Configuration{dsn: "https://forgeops.example/no-userinfo"}

      assert Configuration.api_key(config) == nil
      assert Configuration.ingestion_uri(config) == "https://forgeops.example/no-userinfo"
    end

    test "enabled? requires dsn, api_key, and an enabled environment" do
      config = %Configuration{dsn: "https://key@host/path", environment: "production"}
      assert Configuration.enabled?(config)

      assert not Configuration.enabled?(%{config | environment: "development"})
      assert not Configuration.enabled?(%{config | dsn: nil})
    end

    test "log calls the configured logger" do
      test_pid = self()
      config = %Configuration{logger: fn message -> send(test_pid, {:logged, message}) end}

      Configuration.log(config, "something happened")

      assert_received {:logged, "something happened"}
    end

    test "log does nothing when no logger is configured" do
      assert Configuration.log(%Configuration{}, "should not raise") == :ok
    end
  end

  describe "the shared GenServer" do
    test "get returns the current shared configuration" do
      assert %Configuration{} = Configuration.get()
    end

    test "update replaces the shared configuration and returns the new value" do
      updated = Configuration.update(fn config -> %{config | dsn: "https://key@host/events"} end)

      assert updated.dsn == "https://key@host/events"
      assert Configuration.get().dsn == "https://key@host/events"
    end
  end
end
