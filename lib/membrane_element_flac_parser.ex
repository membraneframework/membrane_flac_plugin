defmodule Membrane.Element.FLACParser do
  use Membrane.Element.Base.Filter
  alias Membrane.Caps.Audio.FLAC

  def_output_pad :output,
    caps: FLAC

  def_input_pad :input,
    caps: :any,
    demand_unit: :bytes

  @impl true
  def handle_process(_pad, _payload, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_demand(_output_pad, _size, _unit, _ctx, state) do
    {:ok, state}
  end
end
