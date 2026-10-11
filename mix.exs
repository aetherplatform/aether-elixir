defmodule Aether.SDK.MixProject do
  use Mix.Project

  @version "0.1.0-beta.1"
  @source "https://github.com/aetherplatform/aether-elixir"

  def project do
    [
      app: :aether_sdk,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: deps(),
      description:
        "Official Elixir SDK for Aether Identity, Events, Notifications, Storage and Webhooks",
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => @source, "Aether" => "https://useaether.co"},
        files:
          (Path.wildcard("lib/**/*") ++
             Path.wildcard("guides/*.md") ++
             ~w(mix.exs README.md CHANGELOG.md RELEASING.md LICENSE NOTICE))
          |> Enum.filter(&File.regular?/1)
          |> Enum.sort()
      ],
      source_url: @source,
      homepage_url: "https://useaether.co",
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        extras: ["README.md", "RELEASING.md"] ++ Path.wildcard("guides/*.md")
      ],
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp deps do
    [
      {:req, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:plug, "~> 1.16", only: :test},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end
end
