defmodule Membrane.Element.FLACParser.ParserTest do
  use ExUnit.Case, async: true
  alias Membrane.Buffer
  alias Membrane.Caps.Audio.FLAC
  alias Membrane.Element.FLACParser.Parser

  defp fixture(file) do
    Path.join([__DIR__, "../fixtures/", file])
  end

  test "parse noise.flac" do
    data = File.read!(fixture("noise.flac"))
    assert %Parser{} = Parser.init()
    assert {:ok, caps_n_bufs, %Parser{} = state} = Parser.parse(data)

    verify_noise_flac_results(caps_n_bufs, state, data)
  end

  test "parse chunked noise.flac" do
    chunks = File.stream!(fixture("noise.flac"), [], 1) |> Enum.to_list()
    data = File.read!(fixture("noise.flac"))

    {caps_n_bufs, state} =
      chunks
      |> Enum.flat_map_reduce(Parser.init(), fn chunk, state ->
        assert {:ok, caps_n_bufs, %Parser{} = state} = Parser.parse(chunk, state)
        {caps_n_bufs, state}
      end)

    verify_noise_flac_results(caps_n_bufs, state, data)
  end

  defp verify_noise_flac_results(caps_n_bufs, state, reference_data) do
    assert [%FLAC{} = caps | bufs] = caps_n_bufs

    assert caps.sample_rate == 16_000
    assert caps.sample_size == 16
    assert caps.channels == 1
    assert caps.total_samples == 32_000
    assert caps.max_block_size == 1152
    assert caps.min_block_size == 1152
    assert caps.max_frame_size == 2272
    assert caps.min_frame_size == 1766

    assert caps.md5_signature ==
             <<122, 24, 145, 1, 73, 205, 50, 241, 87, 157, 176, 17, 61, 130, 183, 13>>

    frames = bufs |> Enum.drop(4)
    assert frames |> length() == 27

    frames
    |> Enum.each(fn %Buffer{metadata: meta} ->
      assert meta.samples == 1152
      assert meta.sample_rate == 16_000
      assert meta.channels == 1
      assert meta.sample_size == 16
    end)

    assert {:ok, last_buf} = Parser.flush(state)

    assert state.pos + byte_size(last_buf.payload) == 71189

    parsed_file = Enum.map_join(bufs ++ [last_buf], fn %Buffer{payload: payload} -> payload end)
    assert reference_data == parsed_file
  end
end
