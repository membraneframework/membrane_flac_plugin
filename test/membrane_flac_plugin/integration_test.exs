defmodule ParsingPipeline do
  @moduledoc false

  alias Membrane.Testing.Pipeline

  @spec make_pipeline(String.t(), String.t(), boolean(), pid()) :: GenServer.on_start()
  def make_pipeline(in_path, out_path, streaming?, pid \\ self()) do
    import Membrane.ChildrenSpec

    links = [
      child(:file_src, %Membrane.File.Source{location: in_path})
      |> child(:parser, %Membrane.FLAC.Parser{streaming?: streaming?})
      |> child(:sink, %Membrane.File.Sink{location: out_path})
    ]

    Pipeline.start_link_supervised!(
      spec: links,
      test_process: pid
    )
  end
end

defmodule Membrane.FLAC.Parser.IntegrationTest do
  use ExUnit.Case
  import Membrane.Testing.Assertions
  alias Membrane.Pipeline

  defp prepare_files(filename) do
    in_path = "../fixtures/#{filename}.flac" |> Path.expand(__DIR__)
    out_path = "/tmp/parsed-#{filename}.flac"
    File.rm(out_path)
    on_exit(fn -> File.rm(out_path) end)
    {in_path, out_path}
  end

  defp assert_parsing_success(filename, streaming?) do
    {in_path, out_path} = prepare_files(filename)

    assert pid = ParsingPipeline.make_pipeline(in_path, out_path, streaming?)

    # Wait for EndOfStream message
    assert_end_of_stream(pid, :sink, :input, 3000)
    src_data = File.read!(in_path)
    out_data = File.read!(out_path)
    assert src_data == out_data
    assert Pipeline.terminate(pid) == :ok
  end

  defp assert_parsing_failure(filename, streaming?) do
    {in_path, out_path} = prepare_files(filename)
    Process.flag(:trap_exit, true)

    assert pid = ParsingPipeline.make_pipeline(in_path, out_path, streaming?)

    assert_receive {:EXIT, ^pid, reason}, 3000

    assert {:membrane_child_crash, :parser, {%RuntimeError{message: message}, _stacktrace}} =
             reason

    assert String.starts_with?(message, "Parsing error")
  end

  @moduletag :capture_log

  test "parse whole 'noise.flac' file" do
    assert_parsing_success("noise", false)
  end

  test "parse whole 'noise.flac' file in streaming mode" do
    assert_parsing_success("noise", true)
  end

  test "parse streamed file (only frames, no headers) in streaming mode" do
    assert_parsing_success("only_frames", true)
  end

  test "fail when parsing streamed file (only frames, no headers) without streaming mode" do
    assert_parsing_failure("only_frames", false)
  end

  test "fail when parsing file with junk at the end without streaming mode" do
    assert_parsing_failure("noise_and_junk", false)
  end

  # test "generate_best_effort_timestamps false, input pts present" do
  #   import Membrane.ChildrenSpec
  #   in_buffers = buffers_from_file(true)
  #   spec = [
  #     child(:source, %Membrane.Testing.Source{output: in_buffers})
  #     |> child(:parser, %Membrane.FLAC.Parser{generate_best_effort_timestamps?: false})
  #     |> child(:sink, Membrane.Testing.Sink)
  #   ]
  #   pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
  #   do_test(pipeline, true)
  # end

  # test "generate_best_effort_timestamps false, input pts missing" do
  #   import Membrane.ChildrenSpec
  #   in_buffers = buffers_from_file(false)
  #   spec = [
  #     child(:source, %Membrane.Testing.Source{output: in_buffers})
  #     |> child(:parser, %Membrane.FLAC.Parser{generate_best_effort_timestamps?: false})
  #     |> child(:sink, Membrane.Testing.Sink)
  #   ]
  #   pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
  #   do_test(pipeline, false)
  # end

  test "generate_best_effort_timestamps true" do
    import Membrane.ChildrenSpec
    in_buffers = buffers_from_file(false)

    spec = [
      child(:source, %Membrane.Testing.Source{output: in_buffers})
      |> child(:parser, %Membrane.FLAC.Parser{generate_best_effort_timestamps?: true})
      |> child(:sink, Membrane.Testing.Sink)
    ]
    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_start_of_stream(pipeline, :sink)

    # ignore first 4 buffers which have duration 0 and probably contain other data than actual audio
    Enum.each(0..3, fn(_x) ->
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{pts: out_pts}, 500)
    end)

    in_buffers
    |> Enum.with_index()
    |> Enum.each(fn {_fixture, index} ->
      if index <= 27 do
        assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{pts: out_pts}, 500)
        assert out_pts == index * 72000000
        IO.inspect("i: #{index} pts: #{out_pts}")
      end
    end)

    assert_end_of_stream(pipeline, :sink)
    Pipeline.terminate(pipeline)
  end

  defp do_test(pipeline, pts_present) do
    assert_start_of_stream(pipeline, :sink)
    buffers_from_file(pts_present)
    |> Enum.with_index()
    |> Enum.each(fn {fixture, index} ->
      if index > 3 and index < 34 do
        ex_pts = fixture.pts
        # IO.inspect(fixture.pts, label: "expected_pts")
        # assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{pts: ex_pts}, 500)
      end
    end)

    assert_end_of_stream(pipeline, :sink)
    Pipeline.terminate(pipeline)
  end

  defp buffers_from_file(pts_present) do
    binary = File.read!("../fixtures/noise.flac" |> Path.expand(__DIR__))
    split_binary(binary)
    |> Enum.with_index()
    |> Enum.map(fn {payload, index} ->
      %Membrane.Buffer{
        payload: payload,
        pts:
          if pts_present do
            index * 10_000
          else
            nil
          end
      }
    end)
  end

  @spec split_binary(binary(), list(binary())) :: list(binary())
  def split_binary(binary, acc \\ [])

  def split_binary(<<binary::binary-size(2048), rest::binary>>, acc) do
    split_binary(rest, acc ++ [binary])
  end

  def split_binary(rest, acc) when byte_size(rest) <= 2048 do
    Enum.concat(acc, [rest])
  end
end
