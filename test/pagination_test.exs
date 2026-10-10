defmodule Aether.SDK.PaginationTest do
  use ExUnit.Case, async: true
  alias Aether.SDK.Pagination

  test "shared cursor vectors" do
    fixtures = Path.expand("../contracts/sdk/v1/pagination-vectors.json", __DIR__)

    fixtures =
      if File.exists?(fixtures),
        do: fixtures,
        else: Path.expand("../../../contracts/sdk/v1/pagination-vectors.json", __DIR__)

    for vector <- Jason.decode!(File.read!(fixtures))["cases"] do
      ref = make_ref()
      Process.put(ref, vector["cursors"])

      fetch = fn _ ->
        [cursor | rest] = Process.get(ref)
        Process.put(ref, rest)
        {:ok, %{items: ["item"], next_cursor: cursor}}
      end

      result = Pagination.stream(fetch, max_pages: vector["max_pages"]) |> Enum.to_list()
      errors = for {:error, error} <- result, do: error.code
      expected = if vector["expected"] == "complete", do: [], else: [vector["expected"]]
      assert errors == expected, vector["name"]
    end
  end

  test "fetches lazily and stops before unused pages" do
    owner = self()

    fetch = fn cursor ->
      send(owner, {:fetched, cursor})
      {:ok, %{items: [1, 2], next_cursor: "next"}}
    end

    stream = Pagination.stream(fetch)
    refute_received {:fetched, _}
    assert Enum.take(stream, 1) == [{:ok, 1}]
    assert_received {:fetched, nil}
    refute_received {:fetched, "next"}
  end

  test "rejects longer cycles, malformed pages and passes original fetch errors once" do
    ref = make_ref()
    Process.put(ref, ["b", "c", "b"])

    fetch = fn _ ->
      [next | rest] = Process.get(ref)
      Process.put(ref, rest)
      {:ok, %{"items" => [], "next_cursor" => next}}
    end

    assert [{:error, %{code: "repeated_cursor"}}] =
             Enum.to_list(Pagination.stream(fetch, initial_cursor: "a"))

    assert [{:error, %{code: "invalid_page"}}] =
             Enum.to_list(Pagination.stream(fn _ -> {:ok, %{items: nil}} end))

    error = Aether.SDK.Error.new("outage", "Unavailable")
    assert [{:error, ^error}] = Enum.to_list(Pagination.stream(fn _ -> {:error, error} end))
  end
end
