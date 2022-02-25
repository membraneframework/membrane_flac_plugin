# Membrane FLAC plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_flac_plugin.svg)](https://hex.pm/packages/membrane_flac_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_flac_plugin/)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_flac_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_flac_plugin)

This package provides an element for parsing FLAC encoded audio stream.
More info can be found in [the docs for element module](https://hexdocs.pm/membrane_flac_plugin).

## Installation

The package can be installed by adding `membrane_flac_plugin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_flac_plugin, "~> 0.7.0"}
  ]
end
```

## Usage
```elixir
defmodule Membrane.Demo.FlacPipeline do
  use Membrane.Pipeline

  @impl true
  def handle_init(_opts) do
    children = %{
      file: %Membrane.File.Source{location: "sample.flac"},
      parser: %Membrane.FLAC.Parser{streaming?: false},
      sink: %Membrane.File.Sink{location: "out.flac"}
    }

    links = [
      link(:file) |> to(:parser) |> to(:sink)
    ]

    {{:ok, spec: %ParentSpec{children: children, links: links}}, %{}}
  end
end
```

Dependencies for the example above:
```elixir
  {:membrane_file_plugin, "~> 0.7.0"},
  {:membrane_flac_plugin, "~> 0.7.0"}
```

## Sponsors

This project is sponsored by [Abridge AI, Inc.](https://abridge.com)

## Copyright and License

Copyright 2019, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_flac_plugin)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_flac_plugin)

Licensed under the [Apache License, Version 2.0](LICENSE)
