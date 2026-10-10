defmodule Mix.Tasks.Aether.Generate do
  @moduledoc "Regenerates Elixir bindings from bundled public JSON contracts. Use --check in CI."
  @shortdoc "Generate public API bindings and types"
  use Mix.Task

  @impl true
  def run(args) do
    {options, positional, invalid} = OptionParser.parse(args, strict: [check: :boolean])
    if positional != [] or invalid != [], do: Mix.raise("Usage: mix aether.generate [--check]")
    Mix.Task.run("compile")

    case Aether.SDK.Generator.run(File.cwd!(), options[:check] || false) do
      :ok -> Mix.shell().info("Public API bindings are current (80 operations).")
      {:error, paths} -> Mix.raise("Generated files are stale:\n" <> Enum.join(paths, "\n"))
    end
  end
end
