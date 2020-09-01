defmodule Membrane.Element.FLACParser.MixProject do
  use Mix.Project

  @version "0.3.0"
  @github_url "https://github.com/membraneframework/membrane-element-flac-parser"

  def project do
    [
      app: :membrane_element_flac_parser,
      version: @version,
      elixir: "~> 1.7",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Membrane Multimedia Framework (FlacParser Element)",
      package: package(),
      name: "Membrane Element: FlacParser",
      source_url: @github_url,
      docs: docs(),
      homepage_url: "https://membraneframework.org",
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [Membrane.Element.FLACParser],
      before_closing_head_tag: &sidebar_fix/1
    ]
  end

  defp sidebar_fix(_) do
    """
      <style type="text/css">
      .sidebar div.sidebar-header {
        margin: 15px;
      }
      </style>
    """
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache 2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membraneframework.org"
      }
    ]
  end

  defp deps do
    [
      {:membrane_core, "~> 0.5.0"},
      {:membrane_caps_audio_flac, "~> 0.1.1"},
      {:crc, "~> 0.10.1"},
      {:ex_doc, "~> 0.19", only: :dev, runtime: false},
      {:dialyxir, "~> 1.0.0-rc.7", only: :dev, runtime: false},
      {:membrane_element_file, "~> 0.3.0", only: :test}
    ]
  end
end
