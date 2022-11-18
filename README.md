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
    {:membrane_flac_plugin, "~> 0.8.0"}
  ]
end
```

## Usage example

```elixir
defmodule Membrane.Demo.FlacPipeline do
  use Membrane.Pipeline
  alias Membrane.{Fake}
  @impl true
  def handle_init(_opts) do
    links = [
      child(:file, %Membrane.File.Source{location: "sample.flac"})
      |> child(:parser, %Membrane.FLAC.Parser{streaming?: false})
      |> child(:fake_sink, Fake.Sink.Buffers)
    ]
    {[spec: links], %{}}
  end
end
```

To run the example:
```elixir
alias Membrane.Demo.FlacPipeline
{:ok, pid} = FlacPipeline.start_link("sample.flac")
FlacPipeline.play(pid)
```

Dependencies for the example above:
```elixir
  {:membrane_file_plugin, "~> 0.13.0"},
  {:membrane_fake_plugin, "~> 0.8.0"},
  {:membrane_flac_plugin, "~> 0.8.0"}
```

## Sponsors

This project is sponsored by [Abridge AI, Inc.](https://abridge.com)

## Copyright and License

Copyright 2019, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_flac_plugin)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_flac_plugin)

Licensed under the [Apache License, Version 2.0](LICENSE)
