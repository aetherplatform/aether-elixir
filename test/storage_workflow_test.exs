defmodule Aether.SDK.Storage.WorkflowTest do
  use ExUnit.Case, async: true
  alias Aether.SDK.{Client, Storage.Workflow}

  defp client do
    {:ok, client} =
      Client.new(
        base_url: "https://api.example",
        token: "api-secret",
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    client
  end

  defp intent do
    %{
      "upload_id" => "upl_00000000000000000000000000000001",
      "object_id" => "obj_00000000000000000000000000000001",
      "asset_id" => nil,
      "version_number" => 1,
      "upload_strategy" => "single",
      "upload_url" => "https://provider.example/signed?secret=token",
      "expires_at" => "2026-10-10T00:00:00Z",
      "required_headers" => %{},
      "multipart" => nil
    }
  end

  defp object(status) do
    %{
      "id" => "obj_00000000000000000000000000000001",
      "asset_id" => nil,
      "namespace_id" => "ns_00000000000000000000000000000001",
      "organization_id" => "organization",
      "application_id" => "application",
      "account_mode" => "sandbox",
      "logical_key" => "hello.txt",
      "version_number" => 1,
      "filename" => "hello.txt",
      "content_type" => "text/plain",
      "detected_content_type" => nil,
      "expected_size" => 5,
      "actual_size" => 5,
      "sha256" => nil,
      "metadata" => %{},
      "visibility" => "private",
      "status" => status,
      "created_at" => "2026-10-10T00:00:00Z",
      "available_at" => nil,
      "deleted_at" => nil
    }
  end

  defp body do
    %{
      namespace_id: "ns_00000000000000000000000000000001",
      logical_key: "hello.txt",
      filename: "hello.txt",
      content_type: "text/plain",
      expected_size: 5
    }
  end

  test "single upload completes with independent idempotency keys and waits for availability" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer api-secret"]

      send(
        owner,
        {:api, conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "idempotency-key")}
      )

      case {conn.method, conn.request_path} do
        {"POST", "/v1/storage/upload-intents"} ->
          Req.Test.json(conn, intent())

        {"POST", "/v1/storage/uploads/upl_00000000000000000000000000000001/complete"} ->
          Req.Test.json(conn, object("quarantined"))

        {"GET", "/v1/storage/objects/obj_00000000000000000000000000000001"} ->
          Req.Test.json(conn, object("available"))
      end
    end)

    Req.Test.stub({__MODULE__, :provider}, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      {:ok, "hello", conn} = Plug.Conn.read_body(conn)
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, result} =
             Workflow.upload_object(client(), body(), "hello",
               provider_options: [req_options: [plug: {Req.Test, {__MODULE__, :provider}}]],
               wait_for_availability: true
             )

    assert result.object.status == "available"
    refute inspect(result) =~ "signed?secret"
    assert_received {:api, "POST", "/v1/storage/upload-intents", [create]}

    assert_received {:api, "POST",
                     "/v1/storage/uploads/upl_00000000000000000000000000000001/complete",
                     [complete]}

    assert create != complete
  end

  test "failed transfer aborts; cleanup failure preserves the original transfer failure" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/v1/storage/upload-intents" ->
          Req.Test.json(conn, intent())

        "/v1/storage/uploads/upl_00000000000000000000000000000001/abort" ->
          send(owner, :cleanup_attempted)
          Plug.Conn.send_resp(conn, 503, "cleanup unavailable")
      end
    end)

    Req.Test.stub({__MODULE__, :provider}, fn conn ->
      Plug.Conn.send_resp(conn, 403, "secret provider details")
    end)

    assert {:error, error} =
             Workflow.upload_object(client(), body(), "hello",
               provider_options: [req_options: [plug: {Req.Test, {__MODULE__, :provider}}]],
               request_options: [max_retries: 0]
             )

    assert error.code == "transfer_failed"
    assert error.status == 403
    assert error.details == %{stage: :transfer, cleanup_succeeded: false}
    assert_received :cleanup_attempted
    refute error.message =~ "secret"
  end

  test "size mismatch prevents API calls and polling handles deleted, timeout, cancellation" do
    assert {:error, %{code: "size_mismatch"}} =
             Workflow.upload_object(client(), body(), "wrong length")

    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, :unexpected_poll)
      Req.Test.json(conn, object("available"))
    end)

    assert {:error, %{code: "availability_timeout"}} =
             Workflow.wait_for_object_available(client(), object("deleted")["id"], timeout: 0)

    refute_received :unexpected_poll

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, object("deleted")) end)

    assert {:error, %{code: "object_deleted"}} =
             Workflow.wait_for_object_available(client(), object("deleted")["id"])

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, object("quarantined")) end)

    assert {:error, %{code: "availability_timeout"}} =
             Workflow.wait_for_object_available(client(), object("deleted")["id"],
               timeout: 50,
               poll_interval: 5
             )

    assert {:error, %{code: "aborted"}} =
             Workflow.wait_for_object_available(client(), object("deleted")["id"],
               cancelled?: fn -> true end
             )
  end
end
