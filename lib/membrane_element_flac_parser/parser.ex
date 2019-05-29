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
            pos: non_neg_integer(),
            caps: %FLAC{} | nil
          }

  defstruct queue: "", continue: :parse_stream, pos: 0, caps: nil

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
    with {:ok, acc, state} <- parse(<<0b1111111111111000::16>>, state) do
      {:ok, acc, %{state | queue: ""}}
    end
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
    {:error, {:not_stream, pos: state.pos}}
  end

  @doc false
  def parse_metadata_block(
        <<is_last::1, type::7, size::24, block::binary-size(size), rest::binary>> = data,
        acc,
        %{pos: pos} = state
      ) do
    payload = binary_part(data, 0, 4 + size)
    buf = %Buffer{payload: payload}

    caps = decode_metadata_block(type, block)

    {acc, state} =
      case caps do
        nil -> {[buf | acc], state}
        caps -> {[buf | acc] ++ [caps], %{state | caps: caps}}
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
        metadata = decode_frame_metadata(frame, state)
        buffer = %Buffer{payload: frame, metadata: metadata}
        state = %{state | pos: pos + frame_size}

        parse_frame(rest, [buffer | acc], state)
    end
  end

  def parse_frame(data, _acc, state) do
    {:error, {:invalid_frame, pos: state.pos, data: data}}
  end

  def decode_frame_metadata(
        <<0b111111111111100::15, blocking_strategy::1, block_size::4, sample_rate::4, channels::4,
          _sample_size::3, 0::1, rest::binary>>,
        state
      ) do
    {number, rest} = decode_utf8_num(rest)
    {block_size, rest} = decode_block_size(block_size, rest)
    {sample_rate, rest} = decode_sample_rate(sample_rate, rest, state)

    <<crc8::8, _rest::binary>> = rest

    sample_number =
      case blocking_strategy do
        0 -> number * state.caps.min_block_size
        1 -> number
      end

    %{
      starting_sample_number: sample_number,
      samples: block_size,
      sample_rate: sample_rate,
      crc8: crc8
    }
  end

  def decode_block_size(0b0001, rest) do
    {192, rest}
  end

  def decode_block_size(0b0110, <<block_size::8, rest::binary>>) do
    {block_size + 1, rest}
  end

  def decode_block_size(0b0111, <<block_size::16, rest::binary>>) do
    {block_size + 1, rest}
  end

  def decode_block_size(block_size, rest) when block_size in 0b0010..0b0101 do
    use Bitwise
    {576 <<< (block_size - 2), rest}
  end

  def decode_block_size(block_size, rest) when block_size in 0b1000..0b1111 do
    use Bitwise
    {1 <<< block_size, rest}
  end

  def decode_sample_rate(0b0000, rest, state) do
    {state.caps.sample_rate, rest}
  end

  def decode_sample_rate(0b0001, rest, _state) do
    {88_200, rest}
  end

  def decode_sample_rate(0b0010, rest, _state) do
    {176_400, rest}
  end

  def decode_sample_rate(0b0011, rest, _state) do
    {192_000, rest}
  end

  def decode_sample_rate(0b0100, rest, _state) do
    {8000, rest}
  end

  def decode_sample_rate(0b0101, rest, _state) do
    {16_000, rest}
  end

  def decode_sample_rate(0b0110, rest, _state) do
    {22_050, rest}
  end

  def decode_sample_rate(0b0111, rest, _state) do
    {24_000, rest}
  end

  def decode_sample_rate(0b1000, rest, _state) do
    {32_000, rest}
  end

  def decode_sample_rate(0b1001, rest, _state) do
    {44_100, rest}
  end

  def decode_sample_rate(0b1010, rest, _state) do
    {48_000, rest}
  end

  def decode_sample_rate(0b1011, rest, _state) do
    {96_000, rest}
  end

  def decode_sample_rate(0b1100, <<sample_rate::8, rest::binary>>, _state) do
    {sample_rate * 1000, rest}
  end

  def decode_sample_rate(0b1101, <<sample_rate::16, rest::binary>>, _state) do
    {sample_rate, rest}
  end

  def decode_sample_rate(0b1110, <<sample_rate::16, rest::binary>>, _state) do
    {sample_rate * 10, rest}
  end

  @spec decode_utf8_num(binary()) :: {non_neg_integer(), binary()}
  def decode_utf8_num(<<0::1, num::7, rest::binary>>) do
    {num, rest}
  end

  def decode_utf8_num(<<0b110::3, a::5, 0b10::2, b::6, rest::binary>>) do
    <<num::11>> = <<a::5, b::6>>
    {num, rest}
  end

  def decode_utf8_num(<<0b1110::4, a::4, 0b10::2, b::6, 0b10::2, c::6, rest::binary>>) do
    <<num::16>> = <<a::4, b::6, c::6>>
    {num, rest}
  end

  def decode_utf8_num(
        <<0b11110::5, a::3, 0b10::2, b::6, 0b10::2, c::6, 0b10::2, d::6, rest::binary>>
      ) do
    <<num::21>> = <<a::3, b::6, c::6, d::6>>
    {num, rest}
  end

  def decode_utf8_num(
        <<0b111110::6, a::2, 0b10::2, b::6, 0b10::2, c::6, 0b10::2, d::6, 0b10::2, e::6,
          rest::binary>>
      ) do
    <<num::26>> = <<a::2, b::6, c::6, d::6, e::6>>
    {num, rest}
  end

  def decode_utf8_num(
        <<0b1111110::7, a::1, 0b10::2, b::6, 0b10::2, c::6, 0b10::2, d::6, 0b10::2, e::6, 0b10::2,
          f::6, rest::binary>>
      ) do
    <<num::31>> = <<a::1, b::6, c::6, d::6, e::6, f::6>>
    {num, rest}
  end

  def decode_utf8_num(
        <<0b11111110::8, 0b10::2, a::6, 0b10::2, b::6, 0b10::2, c::6, 0b10::2, d::6, 0b10::2,
          e::6, 0b10::2, f::6, rest::binary>>
      ) do
    <<num::36>> = <<a::6, b::6, c::6, d::6, e::6, f::6>>
    {num, rest}
  end

  @spec find_frame_start(binary()) :: :nomatch | non_neg_integer()
  defp find_frame_start(data) do
    with {pos, _len} <- :binary.match(data, @frame_header_pattern) do
      pos
    end
  end
end
