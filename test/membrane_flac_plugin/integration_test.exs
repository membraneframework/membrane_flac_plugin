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

  test "generate_best_effort_timestamps false" do
    pipeline = prepare_pts_test_pipeline(false)
    assert_start_of_stream(pipeline, :sink)

    Enum.each(0..31, fn _index ->
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{pts: nil})
    end)

    assert_end_of_stream(pipeline, :sink)
    Pipeline.terminate(pipeline)
  end

  test "generate_best_effort_timestamps true" do
    pipeline = prepare_pts_test_pipeline(true)
    assert_start_of_stream(pipeline, :sink)

    Enum.each(0..3, fn _x ->
      assert_sink_buffer(pipeline, :sink, _)
    end)

    Enum.each(0..27, fn index ->
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{pts: out_pts})
      assert out_pts == index * 72_000_000
    end)

    assert_end_of_stream(pipeline, :sink)
    Pipeline.terminate(pipeline)
  end

  defp prepare_pts_test_pipeline(generate_best_effort_timestamps?) do
    import Membrane.ChildrenSpec

    spec = [
      child(:source, %Membrane.Testing.Source{output: buffers_from_file()})
      |> child(:parser, %Membrane.FLAC.Parser{
        generate_best_effort_timestamps?: generate_best_effort_timestamps?
      })
      |> child(:sink, Membrane.Testing.Sink)
    ]

    Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
  end

  defp buffers_from_file() do
    binary = File.read!("../fixtures/noise.flac" |> Path.expand(__DIR__))

    split_binary(binary)
    |> Enum.map(fn payload ->
      %Membrane.Buffer{
        payload: payload,
        pts: nil
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
