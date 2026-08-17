defmodule Dowser.Elasticsearch.MappableTest do
  use ExUnit.Case, async: true

  alias Dowser.Elasticsearch.Mappable

  # A value_fn that just returns the value unchanged, so these tests isolate
  # Mappable's own traversal/strip_blank behavior from field-level casting
  # (covered separately by Dowser.Elasticsearch.CodecTest).
  defp identity(value, _mapping), do: value

  describe "encode/4 — strip_blank: false (default)" do
    test "a Map keeps blank values" do
      assert Mappable.encode(%{"title" => "", "views" => nil}, nil, &identity/2, false) ==
               %{"title" => "", "views" => nil}
    end

    test "a List keeps blank elements" do
      assert Mappable.encode(["a", "", "b"], nil, &identity/2, false) == ["a", "", "b"]
    end

    test "a MapSet keeps blank elements" do
      assert Mappable.encode(MapSet.new(["a", ""]), nil, &identity/2, false) ==
               MapSet.new(["a", ""])
    end
  end

  describe "encode/4 — strip_blank: true" do
    test "a Map drops keys whose encoded value is blank" do
      assert Mappable.encode(
               %{"title" => "hi", "subtitle" => "", "tags" => []},
               nil,
               &identity/2,
               true
             ) ==
               %{"title" => "hi"}
    end

    test "a List drops blank elements" do
      assert Mappable.encode(["a", "", nil, "b"], nil, &identity/2, true) == ["a", "b"]
    end

    test "a MapSet drops blank elements" do
      assert Mappable.encode(MapSet.new(["a", ""]), nil, &identity/2, true) == MapSet.new(["a"])
    end

    test "nested containers are stripped at every level, including now-empty parents" do
      value = %{"tags" => ["a", ""], "meta" => %{"note" => ""}}

      assert Mappable.encode(value, nil, &identity/2, true) == %{"tags" => ["a"]}
    end
  end

  describe "decode/4" do
    test "a List decodes every element against the same mapping" do
      assert Mappable.decode([1, 2, 3], nil, &Function.identity/1, fn v, _m -> v * 2 end) ==
               [2, 4, 6]
    end

    test "an unwrapped Map (no _index/_source) casts keys and recurses per opts[:properties]" do
      mapping = %{"properties" => %{"count" => %{"type" => "integer"}}}

      assert Mappable.decode(%{"count" => 1}, mapping, &String.to_atom/1, fn v, _f -> v * 10 end) ==
               %{count: 10}
    end

    test "a Map with no matching mapping shape still casts each value, with mapping forced to nil" do
      assert Mappable.decode(%{"a" => 1}, "not a mapping", &Function.identity/1, fn v, _f ->
               v * 10
             end) ==
               %{"a" => 10}
    end
  end
end
