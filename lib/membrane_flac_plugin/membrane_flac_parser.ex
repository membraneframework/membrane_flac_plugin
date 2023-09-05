defmodule Membrane.FLAC.Parser do
  @moduledoc """
  An element parsing FLAC encoded audio stream.

  Wraps `Membrane.FLAC.Parser.Engine`, see its docs for more info.
  """
  use Membrane.Filter
  alias Membrane.{Buffer, FLAC}
  alias Membrane.FLAC.Parser.Engine

  def_output_pad :output,
    accepted_format: FLAC,
    demand_mode: :auto

  def_input_pad :input,
    accepted_format: %Membrane.RemoteStream{content_format: format} when format in [FLAC, nil],
    demand_unit: :bytes,
    demand_mode: :auto

  def_options streaming?: [
                description: """
                This option set to `true` allows parser to accept FLAC stream,
                e.g. only frames without header
                """,
                default: false,
                spec: boolean()
              ]

  @impl true
  def handle_init(_ctx, opts) do
    {[], opts |> Map.from_struct() |> Map.merge(%{parser: nil})}
  end

  @impl true
  def handle_playing(_ctx, %{streaming?: streaming?} = state) do
    state = %{state | parser: Engine.init(streaming?)}
    {[], state}
  end

  @impl true
  def handle_stream_format(:input, _format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload}, _ctx, %{parser: parser} = state) do
    case Engine.parse(payload, parser) do
      {:ok, results, parser} ->
        actions =
          results
          |> Enum.map(fn
            %FLAC{} = format -> {:stream_format, {:output, format}}
            %Buffer{} = buf -> {:buffer, {:output, buf}}
          end)

        {actions, %{state | parser: parser}}

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
      notify_parent: {:end_of_stream, :input}
    ]

    {actions, state}
  end
end
