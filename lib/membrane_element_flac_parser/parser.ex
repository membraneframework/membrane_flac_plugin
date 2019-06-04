defmodule Membrane.Element.FLACParser.Parser do
  @moduledoc """
  Stateful parser based on FLAC format specification available [here](https://xiph.org/flac/format.html#stream)

  The parser outputs:
  1. `Membrane.Caps.Audio.FLAC`
  2. `Membrane.Buffer` with "fLaC" - the FLAC stream marker in ASCII
  3. At least one `Membrane.Buffer` with metadata block(s)
  4. `Membrane.Buffer`s containing one frame each, with decoded metadata from its header

  The parsing is done by calling `init/0` and than `parse/2` with the data to parse.
  The last buffer can be obtained by calling `flush/1`
  """
  alias Membrane.{Buffer, Caps}
  alias Membrane.Caps.Audio.FLAC

  @blocking_stg_fixed 0
  @blocking_stg_variable 1

  @fixed_frame_start <<0b1111111111111000::16>>
  @variable_frame_start <<0b1111111111111001::16>>

  @typedoc """
  Opaque struct containing state of the parser.
  """
  @opaque state() :: %__MODULE__{
            queue: binary(),
            continue: atom(),
            pos: non_neg_integer(),
            caps: %FLAC{} | nil,
            blocking_strategy: 0 | 1 | nil,
            current_metadata: FLAC.FrameMetadata.t() | nil
          }

  defstruct queue: "",
            continue: :parse_stream,
            pos: 0,
            caps: nil,
            blocking_strategy: nil,
            current_metadata: nil

  @doc """
  Returns an initialized parser state
  """
  @spec init() :: state()
  def init() do
    %__MODULE__{}
  end

  @doc """
  Parses FLAC stream, splitting it into `Membrane.Buffer`s and providing caps.

  See moduledoc (`#{inspect(__MODULE__)}`) for more info

  The call without `state` provided is an equivalent of using `init/0` as `state`
  """
  @spec parse(binary(), state()) :: {:ok, [Caps.t() | Buffer.t()], state()}
  def parse(binary_data, state \\ init())

  def parse(binary_data, %{queue: queue, continue: continue} = state) do
    res = apply(__MODULE__, continue, [queue <> binary_data, [], %{state | queue: ""}])

    with {:ok, acc, state} <- res do
      {:ok, acc |> Enum.reverse(), state}
    end
  end

  @doc """
  Outputs the last buffer queued in parser. Should be called afer providing
  all data to the parser.
  """
  @spec flush(state()) :: {:ok, Membrane.Buffer.t()}
  def flush(%{current_metadata: metadata, queue: queue}) do
    buf = %Buffer{payload: queue, metadata: metadata}
    {:ok, buf}
  end

  @doc false
  # Don't start parsing until we have at least streaminfo header
  def parse_stream(binary_data, acc, state) when byte_size(binary_data) < 42 do
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

  def parse_frame(data, acc, %{caps: %{min_frame_size: min_frame_size}} = state)
      when min_frame_size != nil and byte_size(data) < min_frame_size do
    {:ok, acc, %{state | queue: data, continue: :parse_frame}}
  end

  # no frame parsed yet
  def parse_frame(
        <<0b111111111111100::15, blocking_strategy::1, _::binary>> = data,
        acc,
        %{blocking_strategy: nil} = state
      ) do
    state = %{state | blocking_strategy: blocking_strategy}

    parse_frame(data, acc, state)
  end

  # no full header parsed yet
  def parse_frame(
        <<0b111111111111100::15, blocking_strategy::1, _::binary>> = data,
        acc,
        %{blocking_strategy: blocking_strategy, current_metadata: nil} = state
      ) do
    case parse_frame_header(data, state) do
      :nodata ->
        {:ok, acc, %{state | queue: data, continue: :parse_frame}}

      {:error, _reason} = e ->
        e

      {:ok, metadata} ->
        parse_frame(data, acc, %{state | current_metadata: metadata})
    end
  end

  def parse_frame(
        <<0b111111111111100::15, blocking_strategy::1, _::binary>> = data,
        acc,
        %{blocking_strategy: blocking_strategy, current_metadata: current_metadata, pos: pos} =
          state
      ) do
    # TODO: include pos
    search_start = max(2, state.caps.min_frame_size || 0)

    search_end =
      case state.caps.max_frame_size do
        nil -> byte_size(data)
        max_frame_size -> min(byte_size(data), max_frame_size + 2)
      end

    search_scope = {search_start, search_end - search_start}

    matches =
      case blocking_strategy do
        @blocking_stg_fixed ->
          :binary.matches(data, @fixed_frame_start, scope: search_scope)

        @blocking_stg_variable ->
          :binary.matches(data, @variable_frame_start, scope: search_scope)
      end

    next_frame_search =
      matches
      |> Enum.find_value(:nomatch, fn {pos, _len} ->
        <<frame::binary-size(pos), next_frame_candidate::binary>> = data

        case parse_frame_header(next_frame_candidate, state) do
          :nodata ->
            :nodata

          {:error, _reason} ->
            false

          {:ok, metadata} ->
            if is_metadata_valid(metadata, state) do
              {frame, next_frame_candidate, metadata}
            else
              false
            end
        end
      end)

    case next_frame_search do
      :nomatch when search_end + 2 < byte_size(data) ->
        # At this point next frame start should've been found
        # because `search_end` was set to max_frame_size + 2
        {:error, {:invalid_frame, pos: state.pos}, acc}

      :nomatch ->
        # `search_end` was limited by the size of data
        {:ok, acc, %{state | queue: data, continue: :parse_frame}}

      :nodata ->
        {:ok, acc, %{state | queue: data, continue: :parse_frame}}

      {frame, rest, next_metadata} ->
        buf = %Buffer{payload: frame, metadata: current_metadata}

        parse_frame(rest, [buf | acc], %{
          state
          | pos: pos + byte_size(frame),
            queue: "",
            continue: :parse_frame,
            current_metadata: next_metadata
        })
    end
  end

  def parse_frame(_data, acc, state) do
    {:error, {:invalid_frame, pos: state.pos}, acc}
  end

  @spec parse_frame_header(binary(), state()) ::
          :nodata
          | {:ok, FLAC.FrameMetadata.t()}
          | {:error, reason}
        when reason:
               :invalid_block_size
               | :invalid_header_crc
               | :invalid_sample_rate
               | :invalid_utf8_num
               | {:invalid_header, any()}
  defp parse_frame_header(
         <<0b111111111111100::15, blocking_strategy::1, block_size::4, sample_rate::4,
           channels::4, sample_size::3, 0::1, rest::binary>> = data,
         %{blocking_strategy: blocking_strategy} = state
       )
       when block_size != 0 and sample_rate != 0b1111 and channels not in 0b1011..0b1111 and
              sample_size not in [0b011, 0b111] do
    with {:ok, number, consumed_utf8, rest} <- decode_utf8_num(rest),
         {:ok, block_size, consumed_bs, rest} <- decode_block_size(block_size, rest),
         {:ok, sample_rate, consumed_sr, rest} <- decode_sample_rate(sample_rate, rest, state),
         <<crc8::8, _rest::binary>> <- if(byte_size(rest) < 1, do: :nodata, else: rest),
         header_size = 4 + consumed_utf8 + consumed_bs + consumed_sr,
         <<header::binary-size(header_size), _::binary>> = data,
         :ok <- verify_crc(header, crc8) do
      sample_number =
        case blocking_strategy do
          0 -> number * state.caps.min_block_size
          1 -> number
        end

      sample_size =
        case sample_size do
          0b000 -> state.caps.sample_size
          0b001 -> 8
          0b010 -> 12
          0b100 -> 16
          0b101 -> 20
          0b110 -> 24
        end

      {channels, channel_mode} =
        case channels do
          0b1000 -> {2, :left_side}
          0b1001 -> {2, :right_side}
          0b1010 -> {2, :mid_side}
          _ -> {channels + 1, :independent}
        end

      {:ok,
       %FLAC.FrameMetadata{
         channels: channels,
         channel_mode: channel_mode,
         starting_sample_number: sample_number,
         samples: block_size,
         sample_rate: sample_rate,
         sample_size: sample_size
       }}
    end
  end

  defp parse_frame_header(_data, state) do
    {:error, {:invalid_header, pos: state.pos}}
  end

  defp is_metadata_valid(metadata, %{caps: caps, current_metadata: last_meta}) do
    metadata.starting_sample_number == last_meta.starting_sample_number + last_meta.samples and
      metadata.channels == caps.channels and
      metadata.sample_rate == caps.sample_rate and
      metadata.sample_size == caps.sample_size and
      (caps.max_block_size == nil or metadata.samples <= caps.max_block_size)

    # cannot test for min_block_size because last frame in fixed blocking strategy
    # is smaller than rest
  end

  @spec decode_block_size(byte(), binary()) ::
          :nodata
          | {:ok, pos_integer(), non_neg_integer(), binary()}
          | {:error, :invalid_block_size}
  defp decode_block_size(0b0000, _rest) do
    {:error, :invalid_block_size}
  end

  defp decode_block_size(0b0001, rest) do
    {:ok, 192, 0, rest}
  end

  defp decode_block_size(0b0110, rest) when byte_size(rest) < 1 do
    :nodata
  end

  defp decode_block_size(0b0110, <<block_size::8, rest::binary>>) do
    {:ok, block_size + 1, 1, rest}
  end

  defp decode_block_size(0b0111, rest) when byte_size(rest) < 2 do
    :nodata
  end

  defp decode_block_size(0b0111, <<block_size::16, rest::binary>>) do
    {:ok, block_size + 1, 2, rest}
  end

  defp decode_block_size(block_size, rest) when block_size in 0b0010..0b0101 do
    use Bitwise
    {:ok, 576 <<< (block_size - 2), 0, rest}
  end

  defp decode_block_size(block_size, rest) when block_size in 0b1000..0b1111 do
    use Bitwise
    {:ok, 1 <<< block_size, 0, rest}
  end

  @spec decode_sample_rate(byte, binary(), state()) ::
          {:ok, sample_rate :: non_neg_integer(), consumed :: non_neg_integer(), rest :: binary()}
          | {:error, :invalid_sample_rate}
          | :nodata
  defp decode_sample_rate(0b0000, rest, state) do
    {:ok, state.caps.sample_rate, 0, rest}
  end

  defp decode_sample_rate(0b0001, rest, _state) do
    {:ok, 88_200, 0, rest}
  end

  defp decode_sample_rate(0b0010, rest, _state) do
    {:ok, 176_400, 0, rest}
  end

  defp decode_sample_rate(0b0011, rest, _state) do
    {:ok, 192_000, 0, rest}
  end

  defp decode_sample_rate(0b0100, rest, _state) do
    {:ok, 8000, 0, rest}
  end

  defp decode_sample_rate(0b0101, rest, _state) do
    {:ok, 16_000, 0, rest}
  end

  defp decode_sample_rate(0b0110, rest, _state) do
    {:ok, 22_050, 0, rest}
  end

  defp decode_sample_rate(0b0111, rest, _state) do
    {:ok, 24_000, 0, rest}
  end

  defp decode_sample_rate(0b1000, rest, _state) do
    {:ok, 32_000, 0, rest}
  end

  defp decode_sample_rate(0b1001, rest, _state) do
    {:ok, 44_100, 0, rest}
  end

  defp decode_sample_rate(0b1010, rest, _state) do
    {:ok, 48_000, 0, rest}
  end

  defp decode_sample_rate(0b1011, rest, _state) do
    {:ok, 96_000, 0, rest}
  end

  defp decode_sample_rate(0b1100, rest, _state) when byte_size(rest) < 1 do
    :nodata
  end

  defp decode_sample_rate(0b1100, <<sample_rate::8, rest::binary>>, _state) do
    {:ok, sample_rate * 1000, 1, rest}
  end

  defp decode_sample_rate(raw_sample_rate, rest, _state)
       when raw_sample_rate in [0b1101, 0b1110] and byte_size(rest) < 2 do
    :nodata
  end

  defp decode_sample_rate(0b1101, <<sample_rate::16, rest::binary>>, _state) do
    {:ok, sample_rate, 2, rest}
  end

  defp decode_sample_rate(0b1110, <<sample_rate::16, rest::binary>>, _state) do
    {:ok, sample_rate * 10, 2, rest}
  end

  defp decode_sample_rate(0b1111, _rest, _state) do
    {:error, :invalid_sample_rate}
  end

  @spec decode_utf8_num(binary()) ::
          {:ok, decoded_num :: non_neg_integer(), consumed :: non_neg_integer(), rest :: binary()}
          | {:error, :invalid_utf8_num}
          | :nodata
  defp decode_utf8_num(data) when byte_size(data) < 1 do
    :nodata
  end

  defp decode_utf8_num(<<0::1, num::7, rest::binary>>) do
    {:ok, num, 1, rest}
  end

  defp decode_utf8_num(<<0b110::3, _::bitstring>> = data) when byte_size(data) < 2 do
    :nodata
  end

  defp decode_utf8_num(<<0b110::3, a::5, 0b10::2, b::6, rest::binary>>) do
    <<num::11>> = <<a::5, b::6>>
    {:ok, num, 2, rest}
  end

  defp decode_utf8_num(<<0b1110::4, _::bitstring>> = data) when byte_size(data) < 3 do
    :nodata
  end

  defp decode_utf8_num(<<0b1110::4, a::4, 0b10::2, b::6, 0b10::2, c::6, rest::binary>>) do
    <<num::16>> = <<a::4, b::6, c::6>>
    {:ok, num, 3, rest}
  end

  defp decode_utf8_num(<<0b11110::5, _::bitstring>> = data) when byte_size(data) < 4 do
    :nodata
  end

  defp decode_utf8_num(
         <<0b11110::5, a::3, 0b10::2, b::6, 0b10::2, c::6, 0b10::2, d::6, rest::binary>>
       ) do
    <<num::21>> = <<a::3, b::6, c::6, d::6>>
    {:ok, num, 4, rest}
  end

  defp decode_utf8_num(<<0b111110::6, _::bitstring>> = data) when byte_size(data) < 5 do
    :nodata
  end

  defp decode_utf8_num(
         <<0b111110::6, a::2, 0b10::2, b::6, 0b10::2, c::6, 0b10::2, d::6, 0b10::2, e::6,
           rest::binary>>
       ) do
    <<num::26>> = <<a::2, b::6, c::6, d::6, e::6>>
    {:ok, num, 5, rest}
  end

  defp decode_utf8_num(<<0b1111110::7, _::bitstring>> = data) when byte_size(data) < 6 do
    :nodata
  end

  defp decode_utf8_num(
         <<0b1111110::7, a::1, 0b10::2, b::6, 0b10::2, c::6, 0b10::2, d::6, 0b10::2, e::6,
           0b10::2, f::6, rest::binary>>
       ) do
    <<num::31>> = <<a::1, b::6, c::6, d::6, e::6, f::6>>
    {:ok, num, 6, rest}
  end

  defp decode_utf8_num(<<0b11111110::8, _::bitstring>> = data) when byte_size(data) < 7 do
    :nodata
  end

  defp decode_utf8_num(
         <<0b11111110::8, 0b10::2, a::6, 0b10::2, b::6, 0b10::2, c::6, 0b10::2, d::6, 0b10::2,
           e::6, 0b10::2, f::6, rest::binary>>
       ) do
    <<num::36>> = <<a::6, b::6, c::6, d::6, e::6, f::6>>
    {:ok, num, 7, rest}
  end

  defp decode_utf8_num(_) do
    {:error, :invalid_utf8_num}
  end

  defp verify_crc(header, crc8) do
    if CRC.calculate(header, :crc_8) == crc8 do
      :ok
    else
      {:error, :invalid_header_crc}
    end
  end
end
