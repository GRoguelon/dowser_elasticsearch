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

  @config Dowser.Client.Config.new(endpoint: "http://x:9200")

  defp opts(extra \\ []),
    do: Keyword.merge([config: @config, key_fn: &Function.identity/1], extra)

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

  describe "decode/2 — document found at any depth" do
    test "a bare document (Document.get/3 shape) is cast" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{
        "_index" => "posts",
        "_id" => "1",
        "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
      }

      assert {:ok, %{"_source" => %{"published_at" => ~U[2026-08-11 00:00:00.000Z]}}} =
               Codec.decode(body, opts())
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

      assert {:ok, %{"hits" => %{"hits" => [%{"_source" => source}]}}} =
               Codec.decode(body, opts())

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

      assert {:ok, %{"responses" => [%{"hits" => %{"hits" => [%{"_source" => source}]}}]}} =
               Codec.decode(body, opts())

      assert source["published_at"] == ~U[2026-08-11 00:00:00.000Z]
    end

    test "different documents are cast against their own index's mapping" do
      other_mapping = %{"properties" => %{"ip" => %{"type" => "ip"}}}

      fetch = fn _config, index ->
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

      assert {:ok, [%{"_source" => %{"published_at" => date}}, %{"_source" => %{"ip" => ip}}]} =
               Codec.decode(body, opts())

      assert date == ~U[2026-08-11 00:00:00.000Z]
      assert ip == {127, 0, 0, 1}
    end

    test "with no mapping cacher running, values pass through but keys are still processed" do
      body = %{
        "_index" => "posts",
        "_id" => "1",
        "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
      }

      assert {:ok, %{"_id" => "1", "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}}} =
               Codec.decode(body, opts())
    end

    test "key_fn is applied throughout, including inside _source" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{
        "_index" => "posts",
        "_id" => "1",
        "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
      }

      assert {:ok, %{_id: "1", _source: %{published_at: ~U[2026-08-11 00:00:00.000Z]}}} =
               Codec.decode(body, opts(key_fn: &String.to_atom/1))
    end
  end

  describe "decode/2 — opts[:source] (Document.get_source/3 shape)" do
    test "a bare source with no embedded _index uses opts[:index]" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{"published_at" => "2026-08-11T00:00:00.000Z"}

      assert {:ok, %{"published_at" => ~U[2026-08-11 00:00:00.000Z]}} =
               Codec.decode(body, opts(source: true, index: "posts"))
    end
  end

  describe "encode/2 — a single document" do
    test "dumps the whole body against opts[:index]'s mapping" do
      HTTPStub.start_mapping_cacher!(@mapping)

      document = %{"published_at" => ~U[2026-08-11 00:00:00Z]}

      assert Codec.encode(document, opts(index: "posts")) ==
               {:ok, %{"published_at" => "2026-08-11T00:00:00Z"}}
    end

    test "with opts[:doc_key], only that sub-key is dumped (Document.update/4 shape)" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{"doc" => %{"published_at" => ~U[2026-08-11 00:00:00Z]}}

      assert Codec.encode(body, opts(index: "posts", doc_key: :doc)) ==
               {:ok, %{"doc" => %{"published_at" => "2026-08-11T00:00:00Z"}}}
    end

    test "a %{script: ...} update body with no doc_key match passes through" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{"script" => %{"source" => "ctx._source.views++"}}

      assert Codec.encode(body, opts(index: "posts", doc_key: :doc)) == {:ok, body}
    end

    test "no opts[:index] means no mapping — values pass through" do
      document = %{"published_at" => ~U[2026-08-11 00:00:00Z]}
      assert Codec.encode(document, opts()) == {:ok, document}
    end
  end

  describe "encode/2 — bulk (Document.bulk/2 shape)" do
    test "index/create/update actions are dumped, delete has no payload to dump" do
      HTTPStub.start_mapping_cacher!(@mapping)

      operations = [
        %{index: %{_id: "1"}},
        %{published_at: ~U[2026-08-11 00:00:00Z]},
        %{delete: %{_id: "2"}},
        %{update: %{_id: "3"}},
        %{doc: %{published_at: ~U[2026-08-11 00:00:00Z]}}
      ]

      assert {:ok,
              [
                %{index: %{_id: "1"}},
                %{published_at: "2026-08-11T00:00:00Z"},
                %{delete: %{_id: "2"}},
                %{update: %{_id: "3"}},
                %{doc: %{published_at: "2026-08-11T00:00:00Z"}}
              ]} = Codec.encode(operations, opts(index: "posts"))
    end

    test "a per-action _index overrides the bulk-level default" do
      other_mapping = %{"properties" => %{"ip" => %{"type" => "ip"}}}

      start_supervised!(
        {Dowser.Elasticsearch.MappingCacher,
         fetch: fn _config, index ->
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

      assert {:ok, [_header, %{"ip" => "127.0.0.1"}]} =
               Codec.encode(operations, opts(index: "posts"))
    end
  end
end
