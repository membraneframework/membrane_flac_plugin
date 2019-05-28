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

    assert {:ok, bufs_tail, %Parser{}} = Parser.flush(state)
    parsed_file = Enum.map_join(bufs ++ bufs_tail, fn %Buffer{payload: payload} -> payload end)
    assert data == parsed_file
  end
end
