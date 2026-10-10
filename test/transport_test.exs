defmodule Aether.SDK.TransportTest do
  use ExUnit.Case, async: true
  alias Aether.SDK.{Client, Error, Transport}

  defmodule FailingInvalidation do
    def get_token(_),
      do: {:ok, %Aether.SDK.AccessToken{value: "secret", expires_at: 0}}

    def invalidate(_), do: raise("provider secret")
  end

  defmodule RotatingProvider do
    def get_token(agent),
      do:
        Agent.get(agent, fn generation ->
          {:ok, %Aether.SDK.AccessToken{value: "token-#{generation}", expires_at: 0}}
        end)

    def invalidate(agent), do: Agent.update(agent, &(&1 + 1))
  end

  def mark_cancel_after_second(_, _, %{operation: "cancelDelay", attempt: 2}, flag),
    do: Agent.update(flag, fn _ -> true end)

  def mark_cancel_after_second(_, _, _, _), do: :ok

  defp operation(attrs \\ %{}) do
    Map.merge(
      %{
        name: "testRead",
        platform: :events,
        method: :get,
        path: "/v1/test",
        parameters: [],
        idempotency: "not_applicable",
        content_type: nil,
        request_schema: nil,
        request_required: false,
        success_statuses: [200],
        response_schemas: %{
          200 => %{
            "type" => "object",
            "required" => ["ok"],
            "properties" => %{"ok" => %{"type" => "boolean"}}
          }
        }
      },
      attrs
    )
  end

  defp client(plug, opts \\ []) do
    {:ok, client} =
      Client.new(
        Keyword.merge(
          [base_url: "https://api.example", token: "secret", req_options: [plug: plug]],
          opts
        )
      )

    client
  end

  defp vectors(name),
    do:
      File.read!("contracts/sdk/v1/#{name}-vectors.json")
      |> Jason.decode!()
      |> Map.fetch!("cases")

  test "canonical retry decisions and URL encoding" do
    for vector <- vectors("retry") do
      op =
        operation(%{
          method: vector["method"] |> String.downcase() |> String.to_existing_atom(),
          idempotency: vector["idempotency"]
        })

      headers = if vector["has_idempotency_key"], do: %{"idempotency-key" => "key"}, else: %{}
      error = Error.new(vector["code"], "failure", status: vector["status"])

      assert (Transport.retry_safe?(op, headers, nil) and Transport.retryable?(error)) ==
               vector["retry"],
             vector["name"]
    end

    for vector <- vectors("transport") do
      result =
        Transport.build_url(
          vector["base_url"],
          vector["path"],
          vector["path_values"],
          vector["query"]
        )

      if vector["error"],
        do: assert(match?({:error, %{code: "missing_path_parameter"}}, result)),
        else: assert(result == {:ok, vector["expected"]})
    end
  end

  test "canonical error fields preserve case and quota metadata" do
    for vector <- vectors("error") do
      error = Error.from_response(vector["status"], vector["headers"], vector["body"])
      expected = vector["expected"]
      assert error.code == expected["code"]
      assert error.message == expected["message"]
      assert (error.request_id || "") == expected["request_id"]

      for key <-
            ~w(retry_after_seconds rate_limit_limit rate_limit_remaining rate_limit_reset quota_reset) do
        if expected[key], do: assert(error.retry[String.to_existing_atom(key)] == expected[key])
      end
    end

    assert Error.from_response(403, %{}, %{
             "error" => %{"code" => "INSUFFICIENT_CAPABILITY", "message" => "Missing scope"}
           }).code == "INSUFFICIENT_CAPABILITY"

    malformed =
      Error.from_response(
        429,
        %{"x-request-id" => 42, "retry-after" => 2},
        %{
          "error" => %{
            "code" => "rate_limited",
            "message" => %{"secret" => "x"},
            "request_id" => ["bad"]
          }
        }
      )

    assert malformed.message == "Aether request failed with HTTP 429"
    assert malformed.request_id == nil
    assert malformed.retry == %{}
  end

  test "required contract headers are validated before sending" do
    op =
      operation(%{
        method: :post,
        request_required: true,
        request_schema: %{"type" => "object"},
        parameters: [
          %{
            "in" => "header",
            "name" => "Idempotency-Key",
            "required" => true,
            "schema" => %{"type" => "string", "minLength" => 1}
          }
        ]
      })

    plug = fn conn ->
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["upload-once"]
      Req.Test.json(conn, %{ok: true})
    end

    assert {:error, %Error{code: "invalid_request"}} =
             Transport.request(client(plug), op, %{body: %{}})

    assert {:ok, %{"ok" => true}} =
             Transport.request(client(plug), op, %{
               body: %{},
               headers: %{"Idempotency-Key" => "upload-once"}
             })
  end

  test "safe requests obey two retries, opt-out, quota and redirects" do
    {:ok, count} = Agent.start_link(fn -> 0 end)

    plug = fn conn ->
      Agent.update(count, &(&1 + 1))
      Plug.Conn.send_resp(conn, 503, "unavailable")
    end

    assert {:error, %{attempts: 3, status: 503}} =
             Transport.request(client(plug), operation(), %{})

    assert Agent.get(count, & &1) == 3

    assert {:error, %{attempts: 1}} =
             Transport.request(client(plug), operation(), %{}, max_retries: 0)

    for {status, body} <- [
          {429, ~s({"error":{"code":"quota_exceeded","message":"Full"}})},
          {302, ""}
        ] do
      redirect = fn conn ->
        Plug.Conn.put_resp_header(conn, "location", "https://evil.example/token")
        |> Plug.Conn.send_resp(status, body)
      end

      assert {:error, %{attempts: 1}} = Transport.request(client(redirect), operation(), %{})
    end
  end

  test "zero Retry-After is immediate and invalid retry settings return an error" do
    owner = self()
    {:ok, count} = Agent.start_link(fn -> 0 end)
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:aether, :sdk, :request, :retry],
      fn _, measurements, _, pid -> send(pid, {:retry_delay, measurements.delay}) end,
      owner
    )

    on_exit(fn -> :telemetry.detach(id) end)

    plug = fn conn ->
      case Agent.get_and_update(count, fn n -> {n, n + 1} end) do
        0 ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.send_resp(429, ~s({"error":{"code":"rate_limited"}}))

        _ ->
          Req.Test.json(conn, %{ok: true})
      end
    end

    assert {:ok, %{"ok" => true}} = Transport.request(client(plug), operation(), %{})
    assert_received {:retry_delay, 0}
    assert Agent.get(count, & &1) == 2

    for options <- [[retry: :sometimes], [sensitive: :maybe]] do
      assert {:error, %{code: "invalid_request_options"}} =
               Transport.request(client(plug), operation(), %{}, options)
    end
  end

  test "failed token invalidation preserves the original unauthorized response" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 401, ~s({"error":"invalid_token"})) end

    {:ok, configured} =
      Client.new(
        base_url: "https://api.example",
        token_provider: {FailingInvalidation, nil},
        req_options: [plug: plug]
      )

    assert {:error, %Error{status: 401, code: "invalid_token", attempts: 1} = error} =
             Transport.request(configured, operation(), %{})

    refute Exception.message(error) =~ "provider secret"
  end

  test "a 401 invalidates a cached token even with retries disabled" do
    {:ok, generation} = Agent.start_link(fn -> 1 end)

    plug = fn conn ->
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer token-1"] -> Plug.Conn.send_resp(conn, 401, ~s({"error":"invalid_token"}))
        ["Bearer token-2"] -> Req.Test.json(conn, %{ok: true})
      end
    end

    {:ok, configured} =
      Client.new(
        base_url: "https://api.example",
        token_provider: {RotatingProvider, generation},
        req_options: [plug: plug],
        max_retries: 0
      )

    assert {:error, %Error{status: 401, attempts: 1}} =
             Transport.request(configured, operation(), %{})

    assert Agent.get(generation, & &1) == 2
    assert {:ok, %{"ok" => true}} = Transport.request(configured, operation(), %{})
  end

  test "cancellation during a retry delay preserves completed attempt count" do
    {:ok, count} = Agent.start_link(fn -> 0 end)
    {:ok, cancelled} = Agent.start_link(fn -> false end)
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:aether, :sdk, :request, :stop],
      &__MODULE__.mark_cancel_after_second/4,
      cancelled
    )

    on_exit(fn -> :telemetry.detach(id) end)

    plug = fn conn ->
      Agent.update(count, &(&1 + 1))

      conn
      |> Plug.Conn.put_resp_header("retry-after", "0")
      |> Plug.Conn.send_resp(503, "unavailable")
    end

    assert {:error, %Error{code: "request_aborted", attempts: 2}} =
             Transport.request(client(plug), operation(%{name: "cancelDelay"}), %{},
               max_retries: 2,
               cancelled?: fn -> Agent.get(cancelled, & &1) end
             )

    assert Agent.get(count, & &1) == 2
  end

  test "serialized idempotency fields control mutations and bodies remain identical across retries" do
    owner = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:body, body, Plug.Conn.get_req_header(conn, "x-request-id")})
      Plug.Conn.send_resp(conn, 503, "unavailable")
    end

    op =
      operation(%{
        method: :post,
        idempotency: "request_field",
        content_type: "application/json",
        request_schema: %{"type" => "object"}
      })

    assert {:error, %{attempts: 3}} =
             Transport.request(client(plug), op, %{body: %{idempotency_key: "stable"}})

    assert_receive {:body, body, id}
    assert_receive {:body, ^body, ^id}
    assert_receive {:body, ^body, ^id}

    assert {:error, %{attempts: 1}} =
             Transport.request(client(plug), op, %{body: %{other_key: "x"}})

    assert {:error, %{attempts: 1}} =
             Transport.request(client(plug), %{op | idempotency: "unsupported"}, %{
               body: %{idempotency_key: "x"}
             })
  end

  test "malformed JSON, delayed response and cancellation stay in the lifecycle" do
    assert {:error, %{code: "invalid_response"}} =
             Transport.request(
               client(fn conn -> Plug.Conn.send_resp(conn, 200, "{") end),
               operation(),
               %{}
             )

    slow = fn conn ->
      Process.sleep(500)
      Req.Test.json(conn, %{ok: true})
    end

    assert {:error, %{code: "request_timeout", attempts: 1}} =
             Transport.request(client(slow), operation(), %{}, timeout: 30, max_retries: 0)

    start = System.monotonic_time(:millisecond)

    assert {:error, %{code: "request_aborted"}} =
             Transport.request(client(slow), operation(), %{},
               cancelled?: fn -> System.monotonic_time(:millisecond) - start > 25 end
             )
  end

  test "a delayed socket body is bounded and an interrupted body fails" do
    for mode <- [:slow, :interrupted] do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, {_, port}} = :inet.sockname(listener)

      server =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener)
          :gen_tcp.recv(socket, 0, 1000)

          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{"
          )

          if mode == :slow do
            receive do
              :finish -> :ok
            end
          end

          :gen_tcp.close(socket)
        end)

      {:ok, client} =
        Client.new(
          base_url: "http://127.0.0.1:#{port}",
          token: "x",
          timeout: 3_000,
          max_retries: 0
        )

      assert {:error, %{code: code}} = Transport.request(client, operation(), %{})
      assert code == if(mode == :slow, do: "request_timeout", else: "network_error")
      send(server.pid, :finish)
      Task.await(server)
      :gen_tcp.close(listener)
    end
  end

  test "caller termination cancels its in-flight request" do
    owner = self()

    plug = fn conn ->
      send(owner, {:worker, self()})
      Process.sleep(5000)
      Req.Test.json(conn, %{ok: true})
    end

    requester = spawn(fn -> Transport.request(client(plug), operation(), %{}) end)
    assert_receive {:worker, worker}, 2_000
    ref = Process.monitor(worker)
    Process.exit(requester, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 2_000
  end

  test "telemetry contains operation status and timing without remote details or credentials" do
    owner = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:aether, :sdk, :request, :stop],
      fn _, measurements, metadata, pid -> send(pid, {:telemetry, measurements, metadata}) end,
      owner
    )

    on_exit(fn -> :telemetry.detach(id) end)

    plug = fn conn ->
      Plug.Conn.send_resp(conn, 400, ~s({"error":{"code":"token-secret","message":"OTP-secret"}}))
    end

    assert {:error, error} =
             Transport.request(client(plug), operation(), %{}, sensitive: true, max_retries: 0)

    assert error.code == "request_failed"
    refute error.message =~ "OTP"
    assert_receive {:telemetry, measurements, metadata}
    assert is_integer(measurements.duration)
    refute inspect(metadata) =~ "secret"
  end
end
