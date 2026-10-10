defmodule Aether.SDK.GeneratorTest do
  use ExUnit.Case, async: true
  alias Aether.SDK.Generator

  @platforms [
    {Aether.SDK.Generated.Identity, "identity", 11},
    {Aether.SDK.Generated.Events, "events", 3},
    {Aether.SDK.Generated.Notifications, "notifications", 29},
    {Aether.SDK.Generated.Storage, "storage", 18},
    {Aether.SDK.Generated.Webhooks, "webhooks", 19}
  ]

  test "all and only the 80 public operations retain the canonical methods, paths and authentication" do
    actual =
      Enum.flat_map(@platforms, fn {catalog, platform, count} ->
        operations = catalog.operations()
        assert map_size(operations) == count
        document = File.read!("contracts/openapi/#{platform}.json") |> Jason.decode!()

        namespace = Module.concat(Aether.SDK.Types, Macro.camelize(platform))

        for name <- document["components"]["schemas"] |> Map.keys() do
          assert Code.ensure_loaded?(Module.concat(namespace, name))
        end

        expected =
          for {path, item} <- document["paths"],
              {method, op} <- item,
              is_map(op),
              is_binary(op["operationId"]),
              into: %{},
              do: {op["operationId"], {method, path, op["x-aether-token-profiles"]}}

        assert map_size(expected) == count

        Enum.map(operations, fn {name, operation} ->
          assert catalog.operation(name) == operation

          assert expected[operation.name] ==
                   {Atom.to_string(operation.method), operation.path, operation.token_profiles}

          assert Enum.all?(operation.success_statuses, &(&1 >= 200 and &1 < 400))

          assert operation.response_schemas |> Map.keys() |> Enum.sort() ==
                   Enum.sort(operation.success_statuses)

          operation.name
        end)
      end)

    assert length(actual) == 80
    assert length(Enum.uniq(actual)) == 80

    assert Aether.SDK.Generated.Identity.operation(:exchange_oauth_token).idempotency ==
             "unsupported"
  end

  test "generation is deterministic and --check detects modified output without changing it" do
    first = Generator.files()
    assert first == Generator.files()
    assert :ok == Generator.run(File.cwd!(), true)
    sandbox = Path.join(System.tmp_dir!(), "aether_codegen_#{System.unique_integer([:positive])}")
    File.mkdir_p!(sandbox)
    on_exit(fn -> File.rm_rf!(sandbox) end)
    File.cp_r!("contracts", Path.join(sandbox, "contracts"))
    assert :ok == Generator.run(sandbox)
    target = "lib/aether/sdk/generated/identity.ex"
    File.write!(Path.join(sandbox, target), "stale")
    assert {:error, [^target]} = Generator.run(sandbox, true)
    assert File.read!(Path.join(sandbox, target)) == "stale"
  end

  test "declared request and success schemas use typed discriminated passwordless outcomes" do
    operation = Aether.SDK.Generated.Identity.operation(:verify_passwordless)

    assert operation.request_schema["x-elixir-module"] ==
             Aether.SDK.Types.Identity.PasswordlessVerifyRequest

    variants = operation.response_schemas[200]["oneOf"] |> Enum.map(& &1["x-elixir-module"])
    assert Aether.SDK.Types.Identity.PasswordlessAuthorized in variants
    assert Aether.SDK.Types.Identity.PasswordlessHostedCompletionRequired in variants
    assert Aether.SDK.Types.Identity.PasswordlessCustomCompletionRequired in variants
  end
end
