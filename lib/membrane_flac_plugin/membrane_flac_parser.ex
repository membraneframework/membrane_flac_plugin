defmodule Membrane.FLAC.Parser do
  @moduledoc """
  An element parsing FLAC encoded audio stream.

  Wraps `Membrane.FLAC.Parser.Engine`, see its docs for more info.
  """
  use Membrane.Filter
  alias Membrane.Buffer
  alias Membrane.Caps.Audio.FLAC
  alias Membrane.Caps.Matcher
  alias Membrane.FLAC.Parser.Engine

  def_output_pad :output,
    caps: FLAC,
    demand_mode: :auto

  def_input_pad :input,
    caps: {Membrane.RemoteStream, content_format: Matcher.one_of([FLAC, nil])},
    demand_unit: :bytes,
    demand_mode: :auto

  def_options streaming?: [
                description: """
                This option set to `true` allows parser to accept FLAC stream,
                e.g. only frames without header
                """,
                default: false,
                type: :boolean
              ]

  @impl true
  def handle_init(opts) do
    {:ok, opts |> Map.from_struct() |> Map.merge(%{parser: nil})}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, %{streaming?: streaming?} = state) do
    state = %{state | parser: Engine.init(streaming?)}
    {:ok, state}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_playing_to_prepared(_ctx, state) do
    state = %{state | parser: nil}
    {:ok, state}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload}, _ctx, %{parser: parser} = state) do
    case Engine.parse(payload, parser) do
      {:ok, results, parser} ->
        actions =
          results
          |> Enum.map(fn
            %FLAC{} = caps -> {:caps, {:output, caps}}
            %Buffer{} = buf -> {:buffer, {:output, buf}}
          end)

        {{:ok, actions}, %{state | parser: parser}}

      {:error, reason} ->
        raise "Parsing error: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    {:ok, buffer} = Engine.flush(state.parser)

    actions = [
      buffer: {:output, buffer},
      end_of_stream: :output,
      notify: {:end_of_stream, :input}
    ]

    {{:ok, actions}, state}
  end
end
