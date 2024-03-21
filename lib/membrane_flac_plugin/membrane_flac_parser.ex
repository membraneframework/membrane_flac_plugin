defmodule Membrane.FLAC.Parser do
  @moduledoc """
  An element parsing FLAC encoded audio stream.

  Wraps `Membrane.FLAC.Parser.Engine`, see its docs for more info.
  """
  use Membrane.Filter

  alias Membrane.{Buffer, FLAC, Time}
  alias Membrane.FLAC.Parser.Engine

  def_output_pad :output, accepted_format: FLAC

  def_input_pad :input,
    accepted_format: %Membrane.RemoteStream{content_format: format} when format in [FLAC, nil]

  def_options streaming?: [
                description: """
                This option set to `true` allows parser to accept FLAC stream,
                e.g. only frames without header
                """,
                default: false,
                spec: boolean()
              ],
              generate_best_effort_timestamps?: [
                spec: boolean(),
                default: false,
                description: """
                If this is set to true parser will try to generate timestamps for every frame based on sample count and sample rate,
                otherwise it will pass pts from input to output, even if it's nil.
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    {[], opts |> Map.from_struct() |> Map.merge(%{parser: nil, input_pts: nil})}
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
  def handle_buffer(
        :input,
        %Buffer{payload: payload, pts: input_pts},
        _ctx,
        %{parser: parser} = state
      ) do
    state = %{state | input_pts: input_pts}

    case Engine.parse(payload, parser) do
      {:ok, results, parser} ->
        actions =
          results
          |> Enum.map(fn
            %FLAC{} = format ->
              {:stream_format, {:output, format}}

            %Buffer{} = buf ->
              {:buffer, {:output, set_buffer_pts(buf, state)}}
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
      buffer: {:output, set_buffer_pts(buffer, state)},
      end_of_stream: :output,
      notify_parent: {:end_of_stream, :input}
    ]

    {actions, state}
  end

  # set_buffer_pts() does not take into account changing sample rate during stream, because parser engine doesn't support it.
  # If you add support for it in parser engine, this function also need to be updated.
  defp set_buffer_pts(buffer, state) do
    if state.generate_best_effort_timestamps? do
      pts =
        case buffer.metadata do
          %{sample_rate: sample_rate, starting_sample_number: starting_sample_number} ->
            Ratio.new(starting_sample_number, sample_rate) |> Time.seconds()

          _no_metadata ->
            0
        end

      %Buffer{buffer | pts: pts}
    else
      %Buffer{buffer | pts: state.input_pts}
    end
  end
end
