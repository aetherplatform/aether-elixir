defmodule Aether.SDK.Webhooks.SignatureTest do
  use ExUnit.Case, async: true
  alias Aether.SDK.Webhooks.Signature

  test "canonical HMAC vectors" do
    path = Path.expand("../contracts/webhooks/signatures/v1/vectors.json", __DIR__)

    path =
      if File.exists?(path),
        do: path,
        else: Path.expand("../../../contracts/webhooks/signatures/v1/vectors.json", __DIR__)

    vectors = Jason.decode!(File.read!(path))

    for vector <- vectors["valid"] do
      assert {:ok, %{timestamp: timestamp}} =
               Signature.verify(vector["payload"], vector["header"], vector["secret"],
                 now: vector["now_seconds"]
               )

      assert timestamp == vector["timestamp"]
    end

    for vector <- vectors["invalid"] do
      assert {:error, error} =
               Signature.verify(vector["payload"], vector["header"], vector["secret"],
                 now: vector["now_seconds"]
               )

      assert error.code == vector["error"], vector["name"]
    end
  end

  test "rotation, raw binary bodies, exact tolerance and malformed headers" do
    payload = <<0, 255, 10>>

    signature =
      :crypto.mac(:hmac, :sha256, "old", ["1000.", payload]) |> Base.encode16(case: :lower)

    header = "t=1000,v1=" <> signature

    assert {:ok, %{timestamp: 1000}} =
             Signature.verify(payload, header, ["new", "old"], now: 1300)

    assert {:error, %{code: "timestamp_expired"}} =
             Signature.verify(payload, header, "old", now: 1301)

    for bad <- [
          String.upcase(header),
          "t=01000,v1=" <> signature,
          header <> ",x=1",
          "t=-1,v1=" <> signature
        ] do
      assert {:error, %{code: "invalid_signature_format"}} =
               Signature.verify(payload, bad, "old", now: 1000)
    end

    assert {:error, %{code: "invalid_signature_options"}} =
             Signature.verify(payload, header, [], now: 1000)

    assert {:error, %{code: "missing_signature"}} =
             Signature.verify(payload, "", "old", now: 1000)
  end
end
