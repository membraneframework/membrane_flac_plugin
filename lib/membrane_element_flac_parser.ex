defmodule Membrane.Element.FLACParser do
  @moduledoc """
  An element parsing FLAC encoded audio stream.

  Wraps `Membrane.Element.FLACParser.Parser`, see it's docs for more info.
  """
  use Membrane.Element.Base.Filter
  alias Membrane.Caps.Audio.FLAC
  alias Membrane.Buffer
  alias Membrane.Event.EndOfStream
  alias Membrane.Element.FLACParser.Parser

  @initial_demand 1024

  def_output_pad :output,
    caps: FLAC

  def_input_pad :input,
    caps: :any,
    demand_unit: :bytes

  @impl true
  def handle_init(_opts) do
    {:ok, %{parser: nil}}
  end

  @impl true
  def handle_stopped_to_prepared(_, state) do
    state = %{state | parser: Parser.init()}
    {:ok, state}
  end

  @impl true
  def handle_prepared_to_stopped(_, state) do
    state = %{state | parser: nil}
    {:ok, state}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload}, _ctx, %{parser: parser} = state) do
    {:ok, results, parser} = Parser.parse(payload, parser)

    actions =
      results
      |> Enum.map(fn
        %FLAC{} = caps -> {:caps, {:output, caps}}
        %Buffer{} = buf -> {:buffer, {:output, buf}}
      end)

    {{:ok, actions ++ [redemand: :output]}, %{state | parser: parser}}
  end

  @impl true
  def handle_demand(:output, size, :bytes, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  def handle_demand(:output, size, :buffers, ctx, state) do
    caps = ctx.pads.output.caps

    demand =
      if caps == nil do
        @initial_demand
      else
        caps.mix_frame_size * size
      end

    {{:ok, demand: {:input, demand}}, state}
  end

  @impl true
  def handle_event(:input, %EndOfStream{}, _ctx, state) do
    {:ok, buffer} = Parser.flush(state.parser)

    actions = [
      buffer: {:output, buffer},
      event: {:output, %EndOfStream{}},
      notify: {:end_of_stream, :input}
    ]

    {{:ok, actions}, state}
  end

  def handle_event(pad, event, ctx, state) do
    super(pad, event, ctx, state)
  end
end
