defmodule Aether.SDK.SchemaTest do
  use ExUnit.Case, async: true
  alias Aether.SDK.Schema
  alias Aether.SDK.Types.Identity
  alias Aether.SDK.Types.Storage

  test "passwordless results decode to explicit variants, including denied completion" do
    assert {:ok, %Identity.PasswordlessAuthorized{code: "secret", state: nil}} =
             Schema.decode(Identity.PasswordlessVerifyResponse, %{
               "status" => "authorized",
               "code" => "secret",
               "state" => nil
             })

    assert {:ok,
            %Identity.PasswordlessHostedCompletionRequired{
              continuation_url: "https://auth.example/continue"
            }} =
             Schema.decode(Identity.PasswordlessVerifyResponse, %{
               "status" => "hosted_completion_required",
               "continuation_url" => "https://auth.example/continue",
               "expires_in" => 60
             })

    assert {:ok,
            %Identity.PasswordlessCustomCompletionRequired{
              requirements: %Identity.PasswordlessCompletionRequirements{registration: true}
            }} =
             Schema.decode(Identity.PasswordlessVerifyResponse, %{
               "status" => "custom_completion_required",
               "continuation" => "private",
               "expires_in" => 60,
               "requirements" => %{
                 "registration" => true,
                 "consent" => false,
                 "scopes" => ["openid"],
                 "aether_terms_version" => nil,
                 "aether_privacy_version" => nil
               }
             })

    assert {:error, %{code: "invalid_response"}} =
             Schema.decode(Identity.PasswordlessVerifyResponse, %{
               "status" => "future_unknown",
               "code" => "secret",
               "state" => nil
             })
  end

  test "required, nullable, enums, ranges and primitive types are validated without reflecting values" do
    schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["value"],
      "properties" => %{
        "value" => %{"type" => ["integer", "null"], "minimum" => 1, "maximum" => 5},
        "mode" => %{"type" => "string", "enum" => ["ready"]}
      }
    }

    assert {:ok, %{"value" => nil}} = Schema.encode(schema, %{value: nil})
    assert {:ok, %{"value" => 3}} = Schema.decode(schema, %{"value" => 3})

    for value <- [
          %{},
          %{"value" => "3"},
          %{"value" => 0},
          %{"value" => 6},
          %{"value" => 2, "extra" => true},
          %{"value" => 2, "mode" => "secret"}
        ] do
      assert {:error, error} = Schema.decode(schema, value)
      refute inspect(error) =~ "secret"
    end
  end

  test "unset optional fields are omitted while explicit null must be allowed" do
    request = %Identity.TokenHandleRequest{token: "private-token"}

    assert {:ok, %{"token" => "private-token"}} =
             Schema.encode(Identity.TokenHandleRequest, request)

    assert {:error, %{code: "invalid_request"}} =
             Schema.encode(Identity.TokenHandleRequest, %{request | token_type_hint: nil})

    assert {:error, %{code: "invalid_request"}} =
             Schema.encode(Identity.TokenHandleRequest, %Identity.TokenHandleRequest{})

    refute inspect(request) =~ "private-token"
  end

  test "nested Storage multipart objects preserve signed header strings and redact Inspect" do
    wire = %{
      "upload_id" => "upl_" <> String.duplicate("a", 32),
      "object_id" => "obj_" <> String.duplicate("b", 32),
      "asset_id" => nil,
      "version_number" => 1,
      "upload_strategy" => "multipart",
      "upload_url" => nil,
      "expires_at" => "2026-10-10T12:00:00Z",
      "required_headers" => %{"x-custom-header" => "signed-secret"},
      "multipart" => %{
        "provider_upload_id" => "provider-secret",
        "part_size" => 1024,
        "parts" => [
          %{"part_number" => 1, "upload_url" => "https://bucket.example/object?signature=secret"}
        ]
      }
    }

    assert {:ok,
            %Storage.UploadIntent{
              multipart: %Storage.MultipartInstructions{
                parts: [%Storage.MultipartPart{part_number: 1}]
              }
            } = decoded} = Schema.decode(Storage.UploadIntent, wire)

    assert decoded.required_headers == %{"x-custom-header" => "signed-secret"}
    refute inspect(decoded) =~ "secret"
    refute inspect(decoded.multipart.parts) =~ "signature"
    assert {:ok, ^wire} = Schema.encode(Storage.UploadIntent, decoded)
  end

  test "freeform map keys stay strings, unknown allowed properties are retained and atoms are never created" do
    unique = "aether_untrusted_" <> Integer.to_string(System.unique_integer([:positive]))
    assert_raise ArgumentError, fn -> String.to_existing_atom(unique) end
    wire = %{unique => %{"nested" => [%{"x" => true}, nil]}}
    assert {:ok, ^wire} = Schema.decode(%{"type" => "object"}, wire)
    assert_raise ArgumentError, fn -> String.to_existing_atom(unique) end

    schema = %{
      "type" => "object",
      "properties" => %{"id" => %{"type" => "integer"}},
      "additionalProperties" => %{"type" => "string"}
    }

    assert {:ok, %{"id" => 1, ^unique => "retained"}} =
             Schema.decode(schema, %{"id" => 1, unique => "retained"})

    assert {:error, _} = Schema.decode(schema, %{"id" => 1, unique => 2})
    assert {:error, _} = Schema.encode(schema, %{"id" => 2, id: 1})
  end

  test "a declared struct is loaded before decoding its fields" do
    module = Module.concat(Aether.SDK.Test, "LazySchema#{System.unique_integer([:positive])}")

    source =
      "defmodule #{inspect(module)} do\n  defstruct [:value, additional_properties: %{}]\n  def __fields__, do: %{\"value\" => :value}\nend"

    [{^module, beam}] = Code.compile_string(source)

    directory =
      Path.join(System.tmp_dir!(), "aether_lazy_schema_#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "#{module}.beam"), beam)
    Code.prepend_path(directory)

    on_exit(fn ->
      Code.delete_path(directory)
      File.rm_rf!(directory)
    end)

    :code.purge(module)
    :code.delete(module)
    assert :code.is_loaded(module) == false

    schema = %{
      "type" => "object",
      "properties" => %{"value" => %{"type" => "string"}},
      "x-elixir-module" => module
    }

    assert {:ok, %{__struct__: ^module, value: "ready"}} =
             Schema.decode(schema, %{"value" => "ready"})
  end

  test "oneOf rejects ambiguous values and allOf enforces every constraint" do
    assert {:error, _} =
             Schema.decode(%{"oneOf" => [%{"type" => "integer"}, %{"type" => "number"}]}, 1)

    schema = %{"allOf" => [%{"type" => "integer", "minimum" => 1}, %{"maximum" => 10}]}
    assert {:ok, 7} = Schema.decode(schema, 7)

    for value <- [0, 11, "7"] do
      assert {:error, _} = Schema.decode(schema, value)
    end
  end

  test "arrays validate each item, size, uniqueness and string pattern constraints" do
    schema = %{
      "type" => "array",
      "minItems" => 1,
      "maxItems" => 2,
      "uniqueItems" => true,
      "items" => %{"type" => "string", "pattern" => "^[a-z]+$", "maxLength" => 4}
    }

    assert {:ok, ["test"]} = Schema.decode(schema, ["test"])

    for values <- [[], ["a", "b", "c"], ["a", "a"], ["TOO"], ["longer"], [true]] do
      assert {:error, _} = Schema.decode(schema, values)
    end
  end
end
