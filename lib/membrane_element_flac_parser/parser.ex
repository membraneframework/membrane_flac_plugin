defmodule Membrane.Element.FLACParser.Parser do
  @moduledoc """
  Stateful parser based on FLAC format specification available [here](https://xiph.org/flac/format.html#stream)
  """
  alias Membrane.{Buffer, Caps}
  alias Membrane.Caps.Audio.FLAC

  @frame_header_pattern [
    <<0b1111111111111000::16>>,
    <<0b1111111111111001::16>>
  ]

  @opaque state() :: %__MODULE__{
            queue: binary(),
            continue: atom(),
            pos: non_neg_integer()
          }

  defstruct queue: "", continue: :parse_stream, pos: 0

  @doc """
  Returns an initialized parser state
  """
  @spec init() :: state()
  def init() do
    %__MODULE__{}
  end

  @spec parse(binary(), state()) :: {:ok, [Caps.t() | Buffer.t()], state()}
  def parse(binary_data, state \\ %__MODULE__{})

  def parse(binary_data, %{queue: queue, continue: continue} = state) do
    res = apply(__MODULE__, continue, [queue <> binary_data, [], %{state | queue: ""}])

    with {:ok, acc, state} <- res do
      {:ok, acc |> Enum.reverse(), state}
    end
  end

  @spec flush(state()) :: {:ok, [Membrane.Buffer.t()], state()}
  def flush(state) do
    parse(<<0b1111111111111000::16>>, state)
  end

  @doc false
  def parse_stream(binary_data, acc, state) when byte_size(binary_data) < 4 do
    {:ok, acc, %{state | queue: binary_data, continue: :parse_stream}}
  end

  def parse_stream("fLaC" <> tail, acc, state) do
    buf = %Buffer{payload: "fLaC"}
    parse_metadata_block(tail, [buf | acc], %{state | pos: 4})
  end

  def parse_stream(_, _, state) do
    raise "Error while parsing stream at pos #{state.pos}"
  end

  @doc false
  def parse_metadata_block(
        <<is_last::1, type::7, size::24, block::binary-size(size), rest::binary>> = data,
        acc,
        %{pos: pos} = state
      ) do
    payload = binary_part(data, 0, 4 + size)
    buf = %Buffer{payload: payload}

    acc =
      case decode_metadata_block(type, block) do
        nil -> [buf | acc]
        caps -> [buf | acc] ++ [caps]
      end

    state = %{state | pos: pos + byte_size(payload)}

    if is_last == 1 do
      parse_frame(rest, acc, state)
    else
      parse_metadata_block(rest, acc, state)
    end
  end

  def parse_metadata_block(data, acc, state) do
    {:ok, acc, %{state | queue: data, continue: :parse_metadata_block}}
  end

  # STREAMDATA
  defp decode_metadata_block(
         0,
         <<min_block_size::16, max_block_size::16, min_frame_size::24, max_frame_size::24,
           sample_rate::20, channels::3, sample_size::5, total_samples::36, md5::binary-16>>
       ) do
    %FLAC{
      min_block_size: min_block_size,
      max_block_size: max_block_size,
      min_frame_size: min_frame_size,
      max_frame_size: max_frame_size,
      sample_rate: sample_rate,
      channels: channels + 1,
      sample_size: sample_size + 1,
      total_samples: total_samples,
      md5_signature: md5
    }
  end

  defp decode_metadata_block(type, _block) when type in 1..6 do
    nil
  end

  @doc false
  def parse_frame(data, acc, state) when bit_size(data) < 15 + 1 + 4 + 4 + 4 + 3 + 1 do
    {:ok, acc, %{state | queue: data, continue: :parse_frame}}
  end

  def parse_frame(
        <<0b111111111111100::15, _blocking_strategy::1, rest::binary>> = data,
        acc,
        %{pos: pos} = state
      ) do
    case find_frame_start(rest) do
      :nomatch ->
        {:ok, acc, %{state | queue: data, continue: :parse_frame}}

      match_pos ->
        frame_size = 2 + match_pos
        <<frame::binary-size(frame_size), rest::binary>> = data
        buffer = %Buffer{payload: frame}
        state = %{state | pos: pos + frame_size}

        # <<0b111111111111100::15, _blocking_strategy::1, _samples::4, _sample_rate::4,
        #  _channels::4, _sample_size::3, 0::1, rest::binary>> = data,
        parse_frame(rest, [buffer | acc], state)
    end
  end

  @spec find_frame_start(binary()) :: :nomatch | non_neg_integer()
  defp find_frame_start(data) do
    with {pos, _len} <- :binary.match(data, @frame_header_pattern) do
      pos
    end
  end
end
