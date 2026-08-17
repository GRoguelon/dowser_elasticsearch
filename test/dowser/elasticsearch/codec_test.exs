defmodule Dowser.Elasticsearch.CodecTest do
  use ExUnit.Case, async: true

  alias Dowser.Elasticsearch.Codec

  describe "load/2" do
    test "casts date strings and epoch millis to DateTime" do
      assert Codec.load("2026-08-11T00:00:00.000Z", %{
               "type" => "date",
               "format" => "strict_date_optional_time"
             }) == ~U[2026-08-11 00:00:00.000Z]

      assert Codec.load(0, %{"type" => "date", "format" => "epoch_millis"}) ==
               ~U[1970-01-01 00:00:00.000Z]

      assert Codec.load("2026-08-11T00:00:00.000Z", %{
               "type" => "date_nanos",
               "format" => "strict_date_optional_time"
             }) == ~U[2026-08-11 00:00:00.000Z]
    end

    test "casts ip strings to :inet tuples" do
      assert Codec.load("127.0.0.1", %{"type" => "ip"}) == {127, 0, 0, 1}
    end

    test "casts binary fields from Base64" do
      assert Codec.load(Base.encode64("raw"), %{"type" => "binary"}) == "raw"
    end

    test "casts geo_point objects to {lat, lon} tuples" do
      assert Codec.load(%{"lat" => 1.2, "lon" => 3.4}, %{"type" => "geo_point"}) == {1.2, 3.4}
    end

    test "casts date_range objects to Date.Range structs" do
      assert Codec.load(%{"gte" => "2026-08-01", "lte" => "2026-08-11"}, %{
               "type" => "date_range",
               "format" => "strict_date"
             }) == Date.range(~D[2026-08-01], ~D[2026-08-11])
    end

    test "casts integer_range objects to Range structs" do
      assert Codec.load(%{"gte" => 1, "lte" => 10}, %{"type" => "integer_range"}) == 1..10
    end

    test "an integer_range with non-integer bounds passes through unchanged" do
      assert Codec.load(%{"gte" => 1.5, "lte" => 2.5}, %{"type" => "integer_range"}) ==
               %{"gte" => 1.5, "lte" => 2.5}
    end

    test "an unrecognized value passes through unchanged" do
      assert Codec.load("not a date", %{"type" => "date"}) == "not a date"
    end

    test "a mapping with no format defaults to Elasticsearch's own default (strict_date_optional_time||epoch_millis)" do
      assert Codec.load("2026-08-11", %{"type" => "date"}) == ~D[2026-08-11]

      assert Codec.load("2026-08-11T00:00:00.000Z", %{"type" => "date"}) ==
               ~U[2026-08-11 00:00:00.000Z]

      assert Codec.load(0, %{"type" => "date"}) == ~U[1970-01-01 00:00:00.000Z]
    end

    test "an unmatched type falls back to identity" do
      assert Codec.load("hello", %{"type" => "text"}) == "hello"
    end

    test "nil short-circuits" do
      assert Codec.load(nil, %{"type" => "date"}) == nil
    end
  end

  describe "dump/2" do
    test "dumps DateTime to ISO-8601" do
      assert Codec.dump(~U[2026-08-11 00:00:00Z], %{
               "type" => "date",
               "format" => "strict_date_optional_time"
             }) == "2026-08-11T00:00:00Z"
    end

    test "a mapping with no format defaults to Elasticsearch's own default (strict_date_optional_time||epoch_millis)" do
      assert Codec.dump(~D[2026-08-11], %{"type" => "date"}) == "2026-08-11"
      assert Codec.dump(~U[2026-08-11 00:00:00Z], %{"type" => "date"}) == "2026-08-11T00:00:00Z"
    end

    test "dumps :inet tuples to strings" do
      assert Codec.dump({127, 0, 0, 1}, %{"type" => "ip"}) == "127.0.0.1"
    end

    test "dumps raw binaries to Base64" do
      assert Codec.dump("raw", %{"type" => "binary"}) == Base.encode64("raw")
    end

    test "dumps {lat, lon} tuples to geo_point objects" do
      assert Codec.dump({1.2, 3.4}, %{"type" => "geo_point"}) == %{"lat" => 1.2, "lon" => 3.4}
    end

    test "dumps Date.Range structs to date_range objects" do
      assert Codec.dump(Date.range(~D[2026-08-01], ~D[2026-08-11]), %{
               "type" => "date_range",
               "format" => "strict_date"
             }) == %{"gte" => "2026-08-01", "lte" => "2026-08-11"}
    end

    test "dumps Range structs to integer_range objects" do
      assert Codec.dump(1..10, %{"type" => "integer_range"}) == %{"gte" => 1, "lte" => 10}
    end

    test "a non-Range value for integer_range passes through unchanged" do
      assert Codec.dump("not a range", %{"type" => "integer_range"}) == "not a range"
    end

    test "an unmatched type falls back to identity" do
      assert Codec.dump("hello", %{"type" => "text"}) == "hello"
    end

    test "nil short-circuits" do
      assert Codec.dump(nil, %{"type" => "date"}) == nil
    end
  end
end
