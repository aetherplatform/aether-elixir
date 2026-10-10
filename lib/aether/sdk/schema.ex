defmodule Aether.SDK.Schema do
  @moduledoc """
  Encodes application values and decodes responses using the bundled public contracts.

  Declared objects become generated structs. Free-form keys remain strings, and remote
  data never creates atoms. An unset struct field is omitted; an explicit `nil` is
  encoded as JSON null only when the contract allows null.
  """

  alias Aether.SDK.Error
  @unset :__aether_unset__

  @type schema :: map() | module() | nil
  @spec encode(schema(), term()) :: {:ok, term()} | {:error, Error.t()}
  def encode(schema, value), do: convert(schema, value, :encode)

  @spec decode(schema(), term()) :: {:ok, term()} | {:error, Error.t()}
  def decode(schema, value), do: convert(schema, value, :decode)

  defp convert(module, value, mode) when is_atom(module) and module not in [nil, true, false],
    do: convert(module.__schema__(), value, mode)

  defp convert(nil, value, mode), do: convert(%{}, value, mode)
  defp convert(true, value, mode), do: convert(%{}, value, mode)
  defp convert(false, _value, mode), do: failure(mode)

  defp convert(schema, value, mode) when is_map(schema) do
    with :ok <- constant(schema, value, mode),
         :ok <- enumeration(schema, value, mode),
         {:ok, converted} <- shape(schema, value, mode),
         :ok <- constraints(schema, value, mode) do
      {:ok, converted}
    end
  end

  defp convert(_, _, mode), do: failure(mode)

  defp constant(%{"const" => expected}, value, mode) when value != expected, do: failure(mode)
  defp constant(_, _, _), do: :ok

  defp enumeration(%{"enum" => allowed}, value, mode) do
    if value in allowed, do: :ok, else: failure(mode)
  end

  defp enumeration(_, _, _), do: :ok

  defp shape(%{"oneOf" => alternatives} = schema, value, mode),
    do: alternatives(schema, alternatives, value, mode, :one)

  defp shape(%{"anyOf" => alternatives} = schema, value, mode),
    do: alternatives(schema, alternatives, value, mode, :any)

  defp shape(%{"allOf" => schemas} = schema, value, mode) do
    base = Map.delete(schema, "allOf")

    with {:ok, base_value} <- convert(base, value, mode) do
      Enum.reduce_while(schemas, {:ok, base_value}, fn child, {:ok, current} ->
        case convert(child, value, mode) do
          {:ok, converted} -> {:cont, {:ok, combine(current, converted)}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp shape(%{"nullable" => true}, nil, _mode), do: {:ok, nil}

  defp shape(%{"type" => types} = schema, value, mode) when is_list(types) do
    alternatives(schema, Enum.map(types, &Map.put(schema, "type", &1)), value, mode, :any)
  end

  defp shape(%{"type" => "null"}, nil, _mode), do: {:ok, nil}
  defp shape(%{"type" => "string"}, value, _mode) when is_binary(value), do: {:ok, value}
  defp shape(%{"type" => "integer"}, value, _mode) when is_integer(value), do: {:ok, value}
  defp shape(%{"type" => "number"}, value, _mode) when is_number(value), do: {:ok, value}
  defp shape(%{"type" => "boolean"}, value, _mode) when is_boolean(value), do: {:ok, value}

  defp shape(%{"type" => "array"} = schema, value, mode) when is_list(value),
    do: array(schema, value, mode)

  defp shape(%{"type" => "object"} = schema, value, mode) when is_map(value),
    do: object(schema, value, mode)

  defp shape(%{"type" => _}, _value, mode), do: failure(mode)

  defp shape(%{"properties" => _} = schema, value, mode) when is_map(value),
    do: object(schema, value, mode)

  defp shape(schema, value, mode) when is_map(value), do: object(schema, value, mode)
  defp shape(_schema, value, mode) when is_list(value), do: array(%{}, value, mode)

  defp shape(_schema, value, _mode)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp shape(_, _, mode), do: failure(mode)

  defp alternatives(schema, children, value, mode, kind) do
    results =
      Enum.flat_map(children, fn child ->
        case convert(child, value, mode) do
          {:ok, converted} -> [converted]
          {:error, _} -> []
        end
      end)

    case {kind, results} do
      {_, []} ->
        failure(mode)

      {:one, [_first, _second | _]} ->
        failure(mode)

      {_, [first | _]} ->
        # Sibling keywords still apply to a union, including a declared type.
        sibling = schema |> Map.drop(["oneOf", "anyOf", "x-elixir-module"])
        sibling = if is_list(sibling["type"]), do: Map.delete(sibling, "type"), else: sibling

        case convert(sibling, value, mode) do
          {:ok, _} -> {:ok, first}
          error -> error
        end
    end
  end

  defp array(schema, values, mode) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, values} ->
      case convert(schema["items"] || %{}, value, mode) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp object(schema, value, mode) do
    with {:ok, wire} <- wire_object(value, mode),
         :ok <- required(schema["required"] || [], wire, mode),
         {:ok, values} <- object_values(schema, wire, mode) do
      module = schema["x-elixir-module"]

      if mode == :decode and is_atom(module) and not is_nil(module) and
           Code.ensure_loaded?(module) and function_exported?(module, :__fields__, 0) do
        fields = module.__fields__()
        {declared, extra} = Enum.split_with(values, fn {key, _} -> Map.has_key?(fields, key) end)
        attrs = Enum.map(declared, fn {key, value} -> {Map.fetch!(fields, key), value} end)
        {:ok, struct(module, [{:additional_properties, Map.new(extra)} | attrs])}
      else
        {:ok, values}
      end
    end
  end

  defp wire_object(%{__struct__: module} = value, :encode) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__fields__, 0) do
      fields = module.__fields__()

      declared =
        Enum.reduce(fields, %{}, fn {wire, field}, acc ->
          case Map.fetch!(value, field) do
            @unset -> acc
            item -> Map.put(acc, wire, item)
          end
        end)

      with {:ok, extra} <- wire_object(Map.get(value, :additional_properties, %{}), :encode) do
        if Enum.any?(Map.keys(extra), &Map.has_key?(fields, &1)) do
          failure(:encode)
        else
          {:ok, Map.merge(extra, declared)}
        end
      end
    else
      failure(:encode)
    end
  end

  defp wire_object(%{__struct__: _}, :decode), do: failure(:decode)

  defp wire_object(value, mode) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, value}, {:ok, output} ->
      key = if mode == :encode and is_atom(key), do: Atom.to_string(key), else: key

      cond do
        not is_binary(key) -> {:halt, failure(mode)}
        Map.has_key?(output, key) -> {:halt, failure(mode)}
        value == @unset -> {:halt, failure(mode)}
        true -> {:cont, {:ok, Map.put(output, key, value)}}
      end
    end)
  end

  defp wire_object(_, mode), do: failure(mode)

  defp object_values(schema, wire, mode) do
    properties = schema["properties"] || %{}
    extra = Map.get(schema, "additionalProperties", true)

    Enum.reduce_while(wire, {:ok, %{}}, fn {key, value}, {:ok, output} ->
      child = Map.get(properties, key, extra)

      case convert(child, value, mode) do
        {:ok, value} -> {:cont, {:ok, Map.put(output, key, value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp required(fields, values, mode) do
    if Enum.all?(fields, &Map.has_key?(values, &1)), do: :ok, else: failure(mode)
  end

  defp constraints(schema, value, mode) do
    checks = [
      string_constraints(schema, value),
      number_constraints(schema, value),
      collection_constraints(schema, value)
    ]

    if Enum.all?(checks), do: :ok, else: failure(mode)
  end

  defp string_constraints(schema, value) when is_binary(value) do
    size = String.length(value)

    (not Map.has_key?(schema, "minLength") or size >= schema["minLength"]) and
      (not Map.has_key?(schema, "maxLength") or size <= schema["maxLength"]) and
      (not Map.has_key?(schema, "pattern") or
         Regex.match?(Regex.compile!(schema["pattern"]), value))
  end

  defp string_constraints(_, _), do: true

  defp number_constraints(schema, value) when is_number(value) do
    (not Map.has_key?(schema, "minimum") or value >= schema["minimum"]) and
      (not Map.has_key?(schema, "maximum") or value <= schema["maximum"]) and
      (not is_number(schema["exclusiveMinimum"]) or value > schema["exclusiveMinimum"]) and
      (not is_number(schema["exclusiveMaximum"]) or value < schema["exclusiveMaximum"])
  end

  defp number_constraints(_, _), do: true

  defp collection_constraints(schema, value) when is_list(value) do
    size = length(value)

    (not Map.has_key?(schema, "minItems") or size >= schema["minItems"]) and
      (not Map.has_key?(schema, "maxItems") or size <= schema["maxItems"]) and
      (schema["uniqueItems"] != true or Enum.uniq(value) == value)
  end

  defp collection_constraints(schema, value) when is_map(value) do
    size =
      if is_struct(value),
        do: value |> Map.from_struct() |> Enum.count(fn {_, v} -> v != @unset end),
        else: map_size(value)

    (not Map.has_key?(schema, "minProperties") or size >= schema["minProperties"]) and
      (not Map.has_key?(schema, "maxProperties") or size <= schema["maxProperties"])
  end

  defp collection_constraints(_, _), do: true

  defp combine(first, second)
       when is_map(first) and is_map(second) and not is_struct(first) and not is_struct(second),
       do: Map.merge(first, second)

  defp combine(_first, second), do: second

  defp failure(:encode),
    do: {:error, Error.new("invalid_request", "Request does not match the public API contract.")}

  defp failure(:decode),
    do:
      {:error, Error.new("invalid_response", "Response does not match the public API contract.")}
end
