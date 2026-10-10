defmodule Aether.SDK.ClientCredentialsTest do
  use ExUnit.Case, async: true
  alias Aether.SDK.{AccessToken, Client, ClientCredentials, Error}

  defp config(plug, extra \\ []) do
    Keyword.merge(
      [
        token_url: "https://identity.example/oauth/token",
        client_id: "client:id",
        client_secret: "secret:marker",
        audience: "storage",
        capabilities: ["storage.objects.read"],
        req_options: [plug: plug],
        max_retries: 0
      ],
      extra
    )
  end

  test "single flight, expiry-aware cache, explicit invalidation and secret redaction" do
    {:ok, count} = Agent.start_link(fn -> 0 end)

    plug = fn conn ->
      n = Agent.get_and_update(count, fn n -> {n + 1, n + 1} end)

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Basic " <> Base.encode64("client%3Aid:secret%3Amarker")
             ]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert URI.decode_query(body)["grant_type"] == "client_credentials"
      Process.sleep(40)
      Req.Test.json(conn, %{access_token: "token-#{n}", token_type: "Bearer", expires_in: 120})
    end

    provider = start_supervised!({ClientCredentials, config(plug)})

    results =
      1..20
      |> Task.async_stream(fn _ -> ClientCredentials.get_token(provider) end, max_concurrency: 20)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %AccessToken{value: "token-1"}}, &1))
    assert Agent.get(count, & &1) == 1
    assert {:ok, token} = ClientCredentials.get_token(provider)
    refute inspect(token) =~ "token-1"
    refute inspect(:sys.get_status(provider)) =~ "secret:marker"
    assert :ok = ClientCredentials.invalidate(provider)
    assert {:ok, %{value: "token-2"}} = ClientCredentials.get_token(provider)

    assert {:ok, client} =
             Client.new(
               base_url: "https://api.example",
               token_provider: {ClientCredentials, provider}
             )

    refute inspect(client) =~ "token"
  end

  test "two named audience providers can share a supervisor" do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      audience = URI.decode_query(body)["audience"]
      Req.Test.json(conn, %{access_token: audience, token_type: "Bearer", expires_in: 120})
    end

    storage =
      start_supervised!(
        {ClientCredentials,
         config(plug,
           name: {:global, {__MODULE__, :storage, make_ref()}},
           audience: "storage"
         )}
      )

    events =
      start_supervised!(
        {ClientCredentials,
         config(plug,
           name: {:global, {__MODULE__, :events, make_ref()}},
           audience: "events"
         )}
      )

    assert {:ok, %AccessToken{value: "storage"}} = ClientCredentials.get_token(storage)
    assert {:ok, %AccessToken{value: "events"}} = ClientCredentials.get_token(events)
  end

  test "expired cache and invalidation during acquisition cannot retain stale credentials" do
    {:ok, count} = Agent.start_link(fn -> 0 end)
    owner = self()

    plug = fn conn ->
      n = Agent.get_and_update(count, fn n -> {n + 1, n + 1} end)
      send(owner, {:acquiring, n})
      Process.sleep(40)
      Req.Test.json(conn, %{access_token: "t-#{n}", token_type: "Bearer", expires_in: 1})
    end

    provider = start_supervised!({ClientCredentials, config(plug)})
    task = Task.async(fn -> ClientCredentials.get_token(provider) end)
    assert_receive {:acquiring, 1}, 2_000
    :ok = ClientCredentials.invalidate(provider)
    assert {:ok, %{value: "t-2"}} = Task.await(task)
    assert {:ok, %{value: "t-3"}} = ClientCredentials.get_token(provider)
  end

  test "invalidation replaces a failing flight for all waiting callers" do
    {:ok, count} = Agent.start_link(fn -> 0 end)
    owner = self()

    plug = fn conn ->
      n = Agent.get_and_update(count, fn n -> {n + 1, n + 1} end)

      if n == 1 do
        send(owner, {:old_worker, self()})
        Process.sleep(5_000)
        Plug.Conn.send_resp(conn, 503, "old failure")
      else
        Req.Test.json(conn, %{access_token: "fresh", token_type: "Bearer", expires_in: 120})
      end
    end

    provider = start_supervised!({ClientCredentials, config(plug)})

    callers = for _ <- 1..5, do: Task.async(fn -> ClientCredentials.get_token(provider) end)
    assert_receive {:old_worker, old_worker}, 2_000
    old_ref = Process.monitor(old_worker)
    assert :ok = ClientCredentials.invalidate(provider)

    assert Enum.all?(callers, &match?({:ok, %AccessToken{value: "fresh"}}, Task.await(&1)))
    assert_receive {:DOWN, ^old_ref, :process, ^old_worker, _}, 1_000
    assert Agent.get(count, & &1) == 2
  end

  test "normal provider shutdown stops its token request" do
    owner = self()

    plug = fn conn ->
      send(owner, {:token_worker, self()})
      Process.sleep(5_000)
      Req.Test.json(conn, %{access_token: "late", token_type: "Bearer", expires_in: 120})
    end

    {:ok, provider} = ClientCredentials.start_link(config(plug))
    caller = Task.async(fn -> catch_exit(ClientCredentials.get_token(provider)) end)
    assert_receive {:token_worker, worker}, 2_000
    worker_ref = Process.monitor(worker)

    assert :ok = GenServer.stop(provider, :normal)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
    assert Task.await(caller)
  end

  test "credential retries honor Retry-After from rate limiting" do
    {:ok, count} = Agent.start_link(fn -> 0 end)

    plug = fn conn ->
      case Agent.get_and_update(count, fn n -> {n, n + 1} end) do
        0 ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "1")
          |> Plug.Conn.send_resp(429, ~s({"error":{"code":"rate_limited"}}))

        _ ->
          Req.Test.json(conn, %{access_token: "fresh", token_type: "Bearer", expires_in: 120})
      end
    end

    provider = start_supervised!({ClientCredentials, config(plug, max_retries: 1)})
    started = System.monotonic_time(:millisecond)
    assert {:ok, %AccessToken{value: "fresh"}} = ClientCredentials.get_token(provider)
    assert System.monotonic_time(:millisecond) - started >= 900
    assert Agent.get(count, & &1) == 2
  end

  test "concurrent failures are shared and never cached or leaked" do
    {:ok, count} = Agent.start_link(fn -> 0 end)

    plug = fn conn ->
      Agent.update(count, &(&1 + 1))
      Process.sleep(40)

      Plug.Conn.send_resp(
        conn,
        401,
        ~s({"error":{"code":"secret-code","message":"secret:marker","details":{"token":"secret"}}})
      )
    end

    provider = start_supervised!({ClientCredentials, config(plug)})

    results =
      1..10
      |> Task.async_stream(fn _ -> ClientCredentials.get_token(provider) end, max_concurrency: 10)
      |> Enum.to_list()

    assert Enum.all?(
             results,
             &match?({:ok, {:error, %Error{code: "request_failed", details: nil}}}, &1)
           )

    assert Agent.get(count, & &1) == 1
    assert {:error, _} = ClientCredentials.get_token(provider)
    assert Agent.get(count, & &1) == 2
  end

  test "invalid and mixed client configuration returns errors" do
    for options <- [
          [42],
          [base_url: "https://x", token: "x", req_options: [42]],
          [base_url: "https://x", token: "x", client_id: "x"],
          [base_url: "https://x", token_provider: :invalid]
        ] do
      assert {:error, %Error{}} = Client.new(options)
    end

    assert {:error, %Error{}} = ClientCredentials.start_link([])
  end
end
