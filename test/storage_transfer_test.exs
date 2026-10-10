defmodule Aether.SDK.Storage.TransferTest do
  use ExUnit.Case, async: true
  alias Aether.SDK.Storage.Transfer

  test "shared multipart range vectors" do
    path = Path.expand("../contracts/sdk/v1/storage-transfer-vectors.json", __DIR__)

    path =
      if File.exists?(path),
        do: path,
        else: Path.expand("../../../contracts/sdk/v1/storage-transfer-vectors.json", __DIR__)

    for vector <- Jason.decode!(File.read!(path))["cases"] do
      intent = %{
        upload_strategy: "multipart",
        multipart: %{
          part_size: vector["part_size"],
          parts:
            Enum.map(
              vector["part_numbers"],
              &%{part_number: &1, upload_url: "https://provider.example/#{&1}"}
            )
        }
      }

      result = Transfer.multipart_ranges(intent, vector["size"])

      if vector["valid"] do
        assert {:ok, ranges} = result

        assert Enum.map(ranges, fn {_, start, length} -> [start, start + length] end) ==
                 vector["ranges"]
      else
        assert {:error, _} = result
      end
    end
  end

  test "provider headers are isolated, ETags remain exact, redirects never follow" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.req_headers == [{"content-length", "5"}, {"x-provider-signature", "signed"}]
      {:ok, "hello", conn} = Plug.Conn.read_body(conn)
      conn |> Plug.Conn.put_resp_header("etag", "\"exact\"") |> Plug.Conn.send_resp(200, "")
    end)

    opts = [
      req_options: [
        plug: {Req.Test, __MODULE__},
        headers: [{"authorization", "not-forwarded"}],
        auth: {:bearer, "not-forwarded"}
      ]
    ]

    assert {:ok, %{etag: "\"exact\""}} =
             Transfer.upload(
               "https://provider.example/signed?secret=xyz",
               "hello",
               %{"x-provider-signature" => "signed"},
               opts
             )

    for header <-
          ~w(authorization Authorization proxy-authorization x-request-id x-correlation-id cookie) do
      assert {:error, %{code: "invalid_provider_headers"}} =
               Transfer.upload("https://provider.example", "x", %{header => "secret"}, opts)
    end

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://foreign.example")
      |> Plug.Conn.send_resp(302, "secret")
    end)

    assert {:error, %{code: "transfer_failed", status: 302} = error} =
             Transfer.upload("https://provider.example?secret=xyz", "hello", %{}, opts)

    refute inspect(error) =~ "xyz"
    refute error.message =~ "secret"
  end

  test "file uploads stream and multipart concurrency is bounded" do
    path = Path.join(System.tmp_dir!(), "aether-upload-#{System.unique_integer([:positive])}")
    File.write!(path, "abcdefghij")
    on_exit(fn -> File.rm(path) end)
    {:ok, activity} = Agent.start_link(fn -> %{active: 0, peak: 0, bodies: %{}} end)

    Req.Test.stub(__MODULE__, fn conn ->
      number = conn.request_path |> String.trim_leading("/") |> String.to_integer()

      Agent.update(activity, fn state ->
        %{state | active: state.active + 1, peak: max(state.peak, state.active + 1)}
      end)

      Process.sleep(20)
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      Agent.update(activity, fn state ->
        %{state | active: state.active - 1, bodies: Map.put(state.bodies, number, body)}
      end)

      conn
      |> Plug.Conn.put_resp_header("etag", "\"part-#{number}\"")
      |> Plug.Conn.send_resp(200, "")
    end)

    intent = %{
      upload_strategy: "multipart",
      required_headers: %{},
      multipart: %{
        part_size: 3,
        parts:
          Enum.map(
            [4, 2, 1, 3],
            &%{part_number: &1, upload_url: "https://provider.example/#{&1}"}
          )
      }
    }

    assert {:ok, parts} =
             Transfer.upload_multipart(intent, {:file, path},
               concurrency: 2,
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    assert Enum.map(parts, & &1.part_number) == [1, 2, 3, 4]
    assert Enum.map(parts, & &1.etag) == Enum.map(1..4, &"\"part-#{&1}\"")

    assert %{active: 0, peak: 2, bodies: %{1 => "abc", 2 => "def", 3 => "ghi", 4 => "j"}} =
             Agent.get(activity, & &1)
  end

  test "a failed multipart part stops other provider requests" do
    owner = self()
    {:ok, started} = Agent.start_link(fn -> false end)

    Req.Test.stub({__MODULE__, :part_failure}, fn conn ->
      case conn.request_path do
        "/1" ->
          assert Enum.reduce_while(1..1_000, false, fn _, _ ->
                   if Agent.get(started, & &1) do
                     {:halt, true}
                   else
                     Process.sleep(1)
                     {:cont, false}
                   end
                 end)

          Plug.Conn.send_resp(conn, 403, "provider detail")

        "/2" ->
          send(owner, {:other_worker, self()})
          Agent.update(started, fn _ -> true end)
          Process.sleep(5_000)
          Plug.Conn.send_resp(conn, 200, "late")
      end
    end)

    intent = %{
      upload_strategy: "multipart",
      required_headers: %{},
      multipart: %{
        part_size: 1,
        parts: Enum.map(1..2, &%{part_number: &1, upload_url: "https://provider.example/#{&1}"})
      }
    }

    assert {:error, %{code: "transfer_failed", status: 403}} =
             Transfer.upload_multipart(intent, "ab",
               concurrency: 2,
               req_options: [plug: {Req.Test, {__MODULE__, :part_failure}}]
             )

    assert_received {:other_worker, worker}
    refute Process.alive?(worker)
  end

  test "downloads stream raw bytes and validate sizes; error responses do not reach sinks" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.req_headers == []

      conn
      |> Plug.Conn.put_resp_header("content-length", "6")
      |> Plug.Conn.send_resp(200, "abcdef")
    end)

    opts = [req_options: [plug: {Req.Test, __MODULE__}]]

    assert {:ok, 6} =
             Transfer.download(
               "https://provider.example/file",
               fn bytes ->
                 send(owner, {:bytes, bytes})
                 :ok
               end,
               opts
             )

    assert_received {:bytes, "abcdef"}
    assert {:ok, "abcdef"} = Transfer.download_binary("https://provider.example/file", opts)

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-length", "7")
      |> Plug.Conn.send_resp(200, "abcdef")
    end)

    assert {:error, %{code: "size_mismatch"}} =
             Transfer.download_binary("https://provider.example/file", opts)

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 403, "provider secret") end)

    assert {:error, %{code: "transfer_failed"}} =
             Transfer.download(
               "https://provider.example/file",
               fn bytes ->
                 send(owner, {:bytes, bytes})
                 :ok
               end,
               opts
             )

    refute_received {:bytes, _}
  end

  test "timeout and cancellation cover response bodies and suppress adapter secrets" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:worker, self()})
      Process.sleep(200)
      Plug.Conn.send_resp(conn, 200, "secret")
    end)

    assert {:error, %{code: "request_timeout"}} =
             Transfer.download_binary("https://provider.example?token=secret",
               timeout: 20,
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    assert_received {:worker, worker}
    refute Process.alive?(worker)

    assert {:error, %{code: "aborted"}} =
             Transfer.download_binary("https://provider.example", cancelled?: fn -> true end)

    Req.Test.stub(__MODULE__, fn _ -> raise "adapter leaked provider secret" end)

    assert {:error, error} =
             Transfer.download_binary("https://provider.example",
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    assert error.cause == nil
    refute Exception.message(error) =~ "secret"
  end

  test "a provider request stops when its caller exits normally" do
    owner = self()
    {:ok, started} = Agent.start_link(fn -> false end)

    Req.Test.stub({__MODULE__, :owner_exit}, fn conn ->
      send(owner, {:provider_worker, self()})
      Agent.update(started, fn _ -> true end)
      Process.sleep(10_000)
      Plug.Conn.send_resp(conn, 200, "late")
    end)

    caller =
      spawn(fn ->
        receive do
          :go -> :ok
        end

        send(owner, :caller_started)

        result =
          Transfer.download_binary("https://provider.example/file",
            timeout: 8_000,
            cancelled?: fn ->
              if Agent.get(started, & &1), do: exit(:normal), else: false
            end,
            req_options: [plug: {Req.Test, {__MODULE__, :owner_exit}}]
          )

        send(owner, {:caller_result, result})
      end)

    assert :ok = Req.Test.allow({__MODULE__, :owner_exit}, self(), caller)
    caller_ref = Process.monitor(caller)
    send(caller, :go)

    assert_receive :caller_started, 1_000

    worker =
      receive do
        {:provider_worker, worker} ->
          worker

        {:caller_result, result} ->
          flunk("caller finished before provider ran: #{inspect(result)}")
      after
        5_000 -> flunk("provider did not start")
      end

    worker_ref = Process.monitor(worker)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}, 1_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
  end
end
