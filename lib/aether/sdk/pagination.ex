defmodule Aether.SDK.Pagination do
  @moduledoc """
  Lazy cursor pagination. The fetch function receives a cursor (initially `nil`)
  and returns `{:ok, %{items: items, next_cursor: cursor}}` or `{:error, error}`.
  The stream yields `{:ok, item}` and terminates after yielding any error once.
  The default page limit is 1,000; use `:initial_cursor` and `:max_pages` to configure it.
  """
  alias Aether.SDK.Error

  @spec stream((String.t() | nil -> {:ok, map()} | {:error, Error.t()}), keyword()) ::
          Enumerable.t()
  def stream(fetch, options \\ []) when is_function(fetch, 1) do
    maximum = Keyword.get(options, :max_pages, 1_000)
    initial = Keyword.get(options, :initial_cursor)

    Stream.resource(
      fn -> {initial, MapSet.new(), 0, false} end,
      fn
        {_, _, _, true} = state ->
          {:halt, state}

        {cursor, seen, count, false} ->
          cond do
            not is_integer(maximum) or maximum < 1 -> fail("invalid_max_pages")
            count >= maximum -> fail("max_pages_exceeded")
            true -> page(fetch.(cursor), cursor, seen, count)
          end
      end,
      fn _ -> :ok end
    )
  end

  defp page({:error, %Error{} = error}, _, _, _), do: {[{:error, error}], {nil, nil, 0, true}}

  defp page({:ok, result}, cursor, seen, count) when is_map(result) do
    items = Map.get(result, :items, Map.get(result, "items"))
    next = Map.get(result, :next_cursor, Map.get(result, "next_cursor"))

    cond do
      not is_list(items) or not (is_nil(next) or is_binary(next)) ->
        fail("invalid_page")

      next not in [nil, ""] and (next == cursor or MapSet.member?(seen, next)) ->
        fail("repeated_cursor")

      true ->
        seen = if cursor, do: MapSet.put(seen, cursor), else: seen
        {Enum.map(items, &{:ok, &1}), {next, seen, count + 1, next in [nil, ""]}}
    end
  end

  defp page(_, _, _, _), do: fail("invalid_page")

  defp fail(code),
    do: {[{:error, Error.new(code, "Aether pagination failed")}], {nil, nil, 0, true}}
end
