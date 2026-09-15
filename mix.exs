defmodule EctoMiddleware.MixProject do
  use Mix.Project

  def project do
    [
      aliases: aliases(),
      app: :ecto_middleware,
      version: "2.1.0",
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix, :ex_unit]
      ],
      preferred_cli_env: [
        test: :test,
        "test.watch": :test,
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.github": :test,
        precommit: :test
      ],
      test_coverage: [tool: ExCoveralls],
      package: package(),
      description: description(),
      source_url: "https://github.com/vereis/ecto_middleware",
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Runtime dependencies
      {:telemetry, "~> 1.0"},

      # Lint dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.2", only: [:dev, :test], runtime: false},

      # Test dependencies
      {:ecto_sql, "~> 3.11", only: :test},
      {:ecto_sqlite3, "~> 0.17", only: :test},
      {:ex_machina, "~> 2.8", only: :test},
      {:mix_test_watch, "~> 1.1", only: :test, runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},

      # Misc dependencies
      {:ex_doc, "~> 0.14", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      lint: [
        "deps.unlock --unused",
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer"
      ],
      precommit: [
        "deps.unlock --unused",
        "format",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "test"
      ]
    ]
  end

  defp description do
    """
    Implements a generic `middleware/2` callback for any module that uses `Ecto.Repo` to customize behaviour.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/vereis/ecto_middleware"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "guides/migration_v1_to_v2.md"
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ]
    ]
  end
end
