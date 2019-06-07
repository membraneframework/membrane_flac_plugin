defmodule ParsingPipeline do
  @moduledoc false

  alias Membrane.Testing.Pipeline

  def make_pipeline(in_path, out_path, pid \\ self()) do
    Pipeline.start_link(%Pipeline.Options{
      elements: [
        file_src: %Membrane.Element.File.Source{location: in_path},
        parser: Membrane.Element.FLACParser,
        sink: %Membrane.Element.File.Sink{location: out_path}
      ],
      monitored_callbacks: [:handle_notification],
      test_process: pid
    })
  end
end

defmodule Membrane.Element.FLACParser.IntegrationTest do
  use ExUnit.Case
  import Membrane.Testing.Pipeline.Assertions
  alias Membrane.Pipeline

  def fixture_paths(filename) do
    in_path = "../fixtures/#{filename}.flac" |> Path.expand(__DIR__)
    out_path = "/tmp/parsed-#{filename}.flac"
    File.rm(out_path)
    on_exit(fn -> File.rm(out_path) end)
    {in_path, out_path}
  end

  test "parse whole 'noise.flac' file" do
    {in_path, out_path} = fixture_paths("noise")
    assert {:ok, pid} = ParsingPipeline.make_pipeline(in_path, out_path)

    # Start the pipeline
    assert Pipeline.play(pid) == :ok
    # Wait for EndOfStream message
    assert_receive_message({:handle_notification, {{:end_of_stream, :input}, :sink}}, 3000)
    src_data = File.read!(in_path)
    out_data = File.read!(out_path)
    assert src_data == out_data
  end
end
