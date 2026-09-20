defmodule Dowser.Elasticsearch.CodecTest do
  use ExUnit.Case, async: false

  alias Dowser.Elasticsearch.Codec
  alias Dowser.Elasticsearch.HTTPStub

  @mapping %{
    "properties" => %{
      "published_at" => %{"type" => "date", "format" => "strict_date_optional_time"},
      "ip" => %{"type" => "ip"}
    }
  }

  @context Dowser.Client.Context.new(endpoint: "http://x:9200")

  defp context_opts(extra \\ []), do: Keyword.merge([context: @context], extra)

  defp decode_opts(extra \\ []),
    do: context_opts(Keyword.put_new(extra, :key_fn, &Function.identity/1))

  doctest Dowser.Elasticsearch.Codec

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
      assert Codec.load(%{"lat" => 1.2, "lon" => 3.4}, %{"type" => "geo_point"}) ==
               {1.2, 3.4}
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

      assert Codec.dump(~U[2026-08-11 00:00:00Z], %{"type" => "date"}) ==
               "2026-08-11T00:00:00Z"
    end

    test "dumps :inet tuples to strings" do
      assert Codec.dump({127, 0, 0, 1}, %{"type" => "ip"}) == "127.0.0.1"
    end

    test "dumps raw binaries to Base64" do
      assert Codec.dump("raw", %{"type" => "binary"}) == Base.encode64("raw")
    end

    test "dumps {lat, lon} tuples to geo_point objects" do
      assert Codec.dump({1.2, 3.4}, %{"type" => "geo_point"}) ==
               %{"lat" => 1.2, "lon" => 3.4}
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

  describe "a codec of your own" do
    defmodule CustomCodec do
      @behaviour Dowser.Elasticsearch.Codec

      @impl true
      def load(value, %{"type" => "scaled_float", "scaling_factor" => factor})
          when is_integer(value) do
        value / factor
      end

      # `date` is already handled by the built-in codec; matching it first
      # replaces that cast.
      def load(value, %{"type" => "date"}), do: {:raw, value}

      def load(value, field), do: Dowser.Elasticsearch.Codec.load(value, field)

      @impl true
      def dump(value, %{"type" => "scaled_float", "scaling_factor" => factor})
          when is_float(value) do
        round(value * factor)
      end

      def dump(value, field), do: Dowser.Elasticsearch.Codec.dump(value, field)
    end

    test "a delegated type still uses the built-in codec" do
      assert CustomCodec.load("127.0.0.1", %{"type" => "ip"}) == {127, 0, 0, 1}
    end

    test "an added type is cast by the new clause" do
      field = %{"type" => "scaled_float", "scaling_factor" => 100}

      assert CustomCodec.load(1234, field) == 12.34
      assert CustomCodec.dump(12.34, field) == 1234
    end

    test "a clause over a built-in type replaces that cast" do
      assert CustomCodec.load("2026-08-11", %{"type" => "date"}) == {:raw, "2026-08-11"}
    end

    test "delegating inherits the nil short-circuit and the identity fallback" do
      assert CustomCodec.load(nil, %{"type" => "ip"}) == nil
      assert CustomCodec.load("hello", %{"type" => "text"}) == "hello"
    end
  end

  describe "a mapping entry with no type" do
    test "falls back to identity in both directions" do
      assert Codec.load("hello", nil) == "hello"
      assert Codec.dump("hello", %{"properties" => %{}}) == "hello"
    end
  end

  describe "decode/2 — document found at any depth" do
    test "a bare document (Document.get/3 shape) is cast" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{
        "_index" => "posts",
        "_id" => "1",
        "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
      }

      assert %{"_source" => %{"published_at" => ~U[2026-08-11 00:00:00.000Z]}} =
               Codec.decode(body, decode_opts())
    end

    test "a document nested under hits.hits[] (search shape) is cast" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{
        "took" => 1,
        "hits" => %{
          "hits" => [
            %{
              "_index" => "posts",
              "_id" => "1",
              "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
            }
          ]
        }
      }

      assert %{"hits" => %{"hits" => [%{"_source" => source}]}} =
               Codec.decode(body, decode_opts())

      assert source["published_at"] == ~U[2026-08-11 00:00:00.000Z]
    end

    test "a document nested under responses[].hits.hits[] (msearch shape) is cast" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{
        "responses" => [
          %{
            "hits" => %{
              "hits" => [
                %{
                  "_index" => "posts",
                  "_id" => "1",
                  "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
                }
              ]
            }
          }
        ]
      }

      assert %{"responses" => [%{"hits" => %{"hits" => [%{"_source" => source}]}}]} =
               Codec.decode(body, decode_opts())

      assert source["published_at"] == ~U[2026-08-11 00:00:00.000Z]
    end

    test "different documents are cast against their own index's mapping" do
      other_mapping = %{"properties" => %{"ip" => %{"type" => "ip"}}}

      fetch = fn _context, index ->
        case index do
          "posts" -> {:ok, @mapping}
          "comments" -> {:ok, other_mapping}
        end
      end

      start_supervised!({Dowser.Elasticsearch.MappingCacher, fetch: fetch})

      body = [
        %{
          "_index" => "posts",
          "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
        },
        %{"_index" => "comments", "_source" => %{"ip" => "127.0.0.1"}}
      ]

      assert [%{"_source" => %{"published_at" => date}}, %{"_source" => %{"ip" => ip}}] =
               Codec.decode(body, decode_opts())

      assert date == ~U[2026-08-11 00:00:00.000Z]
      assert ip == {127, 0, 0, 1}
    end

    test "with no mapping cacher running, values pass through but keys are still processed" do
      body = %{
        "_index" => "posts",
        "_id" => "1",
        "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
      }

      assert %{"_id" => "1", "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}} =
               Codec.decode(body, decode_opts())
    end

    test "key_fn is applied throughout, including inside _source" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{
        "_index" => "posts",
        "_id" => "1",
        "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
      }

      assert %{_id: "1", _source: %{published_at: ~U[2026-08-11 00:00:00.000Z]}} =
               Codec.decode(body, decode_opts(key_fn: &String.to_atom/1))
    end
  end

  describe "decode/2 — opts[:source] (Document.get_source/3 shape)" do
    test "a bare source with no embedded _index uses opts[:index]" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{"published_at" => "2026-08-11T00:00:00.000Z"}

      assert %{"published_at" => ~U[2026-08-11 00:00:00.000Z]} =
               Codec.decode(body, decode_opts(source: true, index: "posts"))
    end
  end

  describe "decode/2 — opts[:codec]" do
    defmodule UpcaseCodec do
      @behaviour Dowser.Elasticsearch.Codec

      @impl true
      def load(value, %{"type" => "text"}) when is_binary(value), do: String.upcase(value)
      def load(value, field), do: Dowser.Elasticsearch.Codec.load(value, field)

      @impl true
      def dump(value, field), do: Dowser.Elasticsearch.Codec.dump(value, field)
    end

    test "values are cast through the given codec instead of the default" do
      HTTPStub.start_mapping_cacher!(%{
        "properties" => %{"title" => %{"type" => "text"}}
      })

      body = %{"_index" => "posts", "_source" => %{"title" => "hello"}}

      assert %{"_source" => %{"title" => "HELLO"}} =
               Codec.decode(body, decode_opts(codec: UpcaseCodec))

      assert %{"_source" => %{"title" => "hello"}} = Codec.decode(body, decode_opts())
    end
  end

  describe "encode/2" do
    test "casts the source against opts[:index]'s mapping" do
      HTTPStub.start_mapping_cacher!(@mapping)

      document = %{"published_at" => ~U[2026-08-11 00:00:00Z]}

      assert Codec.encode(document, context_opts(index: "posts")) ==
               %{"published_at" => "2026-08-11T00:00:00Z"}
    end

    test "no opts[:index] means no mapping — values pass through" do
      document = %{"published_at" => ~U[2026-08-11 00:00:00Z]}

      assert Codec.encode(document, context_opts()) == document
    end

    test "with no mapping cacher running, values pass through" do
      document = %{"published_at" => ~U[2026-08-11 00:00:00Z]}

      assert Codec.encode(document, context_opts(index: "posts")) == document
    end

    defmodule DowncaseCodec do
      @behaviour Dowser.Elasticsearch.Codec

      @impl true
      def load(value, field), do: Dowser.Elasticsearch.Codec.load(value, field)

      @impl true
      def dump(value, %{"type" => "text"}) when is_binary(value), do: String.downcase(value)
      def dump(value, field), do: Dowser.Elasticsearch.Codec.dump(value, field)
    end

    test "opts[:codec] replaces the default codec" do
      HTTPStub.start_mapping_cacher!(%{"properties" => %{"title" => %{"type" => "text"}}})

      document = %{"title" => "HELLO"}

      assert Codec.encode(document, context_opts(index: "posts", codec: DowncaseCodec)) ==
               %{"title" => "hello"}

      assert Codec.encode(document, context_opts(index: "posts")) == document
    end
  end

  describe "encode_bulk/3" do
    test "index/create/update actions are dumped, delete has no payload to dump" do
      HTTPStub.start_mapping_cacher!(@mapping)

      operations = [
        %{index: %{_id: "1"}},
        %{published_at: ~U[2026-08-11 00:00:00Z]},
        %{delete: %{_id: "2"}},
        %{update: %{_id: "3"}},
        %{doc: %{published_at: ~U[2026-08-11 00:00:00Z]}}
      ]

      assert [
               %{index: %{_id: "1"}},
               %{published_at: "2026-08-11T00:00:00Z"},
               %{delete: %{_id: "2"}},
               %{update: %{_id: "3"}},
               %{doc: %{published_at: "2026-08-11T00:00:00Z"}}
             ] = encode_bulk(operations, index: "posts")
    end

    test "an update action's upsert source is dumped too" do
      HTTPStub.start_mapping_cacher!(@mapping)

      operations = [
        %{"update" => %{"_id" => "1"}},
        %{
          "doc" => %{"published_at" => ~U[2026-08-11 00:00:00Z]},
          "upsert" => %{"published_at" => ~U[2026-08-12 00:00:00Z]}
        }
      ]

      assert [
               _header,
               %{
                 "doc" => %{"published_at" => "2026-08-11T00:00:00Z"},
                 "upsert" => %{"published_at" => "2026-08-12T00:00:00Z"}
               }
             ] = encode_bulk(operations, index: "posts")
    end

    test "a scripted update payload has nothing to dump" do
      HTTPStub.start_mapping_cacher!(@mapping)

      operations = [
        %{"update" => %{"_id" => "1"}},
        %{"script" => %{"source" => "ctx._source.views++"}}
      ]

      assert encode_bulk(operations, index: "posts") == operations
    end

    test "a per-action _index overrides the bulk-level default" do
      other_mapping = %{"properties" => %{"ip" => %{"type" => "ip"}}}

      start_supervised!(
        {Dowser.Elasticsearch.MappingCacher,
         fetch: fn _context, index ->
           case index do
             "posts" -> {:ok, @mapping}
             "comments" -> {:ok, other_mapping}
           end
         end}
      )

      operations = [
        %{"index" => %{"_id" => "1", "_index" => "comments"}},
        %{"ip" => {127, 0, 0, 1}}
      ]

      assert [_header, %{"ip" => "127.0.0.1"}] = encode_bulk(operations, index: "posts")
    end
  end

  defp encode_bulk(operations, extra) do
    Codec.encode_bulk(operations, &Codec.encode/2, context_opts(extra))
  end
end
