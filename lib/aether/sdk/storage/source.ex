defmodule Aether.SDK.Storage.Source do
  @moduledoc false
  alias Aether.SDK.Error
  @chunk_size 65_536

  def size(binary) when is_binary(binary), do: {:ok, byte_size(binary)}

  def size({:file, path}) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} -> {:ok, size}
      _ -> {:error, Error.new("invalid_source", "Upload source is not a readable file")}
    end
  end

  def size(_),
    do: {:error, Error.new("invalid_source", "Upload source must be a binary or {:file, path}")}

  def stream(binary, start, length) when is_binary(binary), do: binary_part(binary, start, length)

  def stream({:file, path}, start, length) do
    Stream.resource(
      fn -> {File.open!(path, [:read, :binary, :raw]), start, length} end,
      fn
        {file, offset, 0} ->
          {:halt, {file, offset, 0}}

        {file, offset, remaining} ->
          count = min(remaining, @chunk_size)

          case :file.pread(file, offset, count) do
            {:ok, bytes} when byte_size(bytes) == count ->
              {[bytes], {file, offset + count, remaining - count}}

            _ ->
              raise "Upload source changed or could not be read"
          end
      end,
      fn {file, _, _} -> File.close(file) end
    )
  end
end
