defmodule Membrane.FLAC.Parser.EngineTest do
  use ExUnit.Case, async: true
  alias Membrane.Buffer
  alias Membrane.FLAC
  alias Membrane.FLAC.Parser.Engine

  defp fixture(file) do
    Path.join([__DIR__, "../fixtures/", file])
  end

  test "parse noise.flac" do
    data = File.read!(fixture("noise.flac"))
    assert %Engine{} = Engine.init()
    assert {:ok, format_n_bufs, %Engine{} = state} = Engine.parse(data)

    verify_noise_flac_results(format_n_bufs, state, data)
  end

  test "parse chunked noise.flac" do
    chunks = File.stream!(fixture("noise.flac"), [], 1) |> Enum.to_list()
    data = File.read!(fixture("noise.flac"))

    {format_n_bufs, state} =
      chunks
      |> Enum.flat_map_reduce(Engine.init(), fn chunk, state ->
        assert {:ok, format_n_bufs, %Engine{} = state} = Engine.parse(chunk, state)
        {format_n_bufs, state}
      end)

    verify_noise_flac_results(format_n_bufs, state, data)
  end

  test "parse two_meta_blocks.flac" do
    data = File.read!(fixture("two_meta_blocks.flac"))
    assert %Engine{} = Engine.init()
    assert {:ok, format_n_bufs, %Engine{} = state} = Engine.parse(data)

    assert [%FLAC{} = format | bufs] = format_n_bufs
    assert format.sample_rate == 44_100
    assert format.sample_size == 16
    assert format.channels == 1
    assert format.total_samples == nil
    assert format.max_block_size == 4096
    assert format.min_block_size == 4096
    assert format.max_frame_size == nil
    assert format.min_frame_size == nil
    assert format.md5_signature == nil

    # "fLaC" + 2 metadata blocks + 2 frames
    assert bufs |> length() == 5

    assert {:ok, last_buf} = Engine.flush(state)

    assert state.pos + byte_size(last_buf.payload) == byte_size(data)

    parsed_file = Enum.map_join(bufs ++ [last_buf], fn %Buffer{payload: payload} -> payload end)
    assert data == parsed_file
  end

  defp verify_noise_flac_results(format_n_bufs, state, reference_data) do
    assert [%FLAC{} = format | bufs] = format_n_bufs

    assert format.sample_rate == 16_000
    assert format.sample_size == 16
    assert format.channels == 1
    assert format.total_samples == 32_000
    assert format.max_block_size == 1152
    assert format.min_block_size == 1152
    assert format.max_frame_size == 2272
    assert format.min_frame_size == 1766

    assert format.md5_signature ==
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

    assert {:ok, last_buf} = Engine.flush(state)

    assert state.pos + byte_size(last_buf.payload) == 71_189

    parsed_file = Enum.map_join(bufs ++ [last_buf], fn %Buffer{payload: payload} -> payload end)
    assert reference_data == parsed_file
  end
end
