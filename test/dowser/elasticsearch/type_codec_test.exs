defmodule Dowser.Elasticsearch.TypeCodecTest do
  use ExUnit.Case, async: false

  alias Dowser.Elasticsearch.HTTPStub
  alias Dowser.Elasticsearch.TypeCodec

  @mapping %{
    "properties" => %{
      "published_at" => %{"type" => "date", "format" => "strict_date_optional_time"},
      "ip" => %{"type" => "ip"}
    }
  }

  @config Dowser.Client.Config.new(endpoint: "http://x:9200")

  defp opts(extra \\ []),
    do: Keyword.merge([config: @config, key_fn: &Function.identity/1], extra)

  describe "decode/2 — document found at any depth" do
    test "a bare document (Document.get/3 shape) is cast" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{
        "_index" => "posts",
        "_id" => "1",
        "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
      }

      assert {:ok, %{"_source" => %{"published_at" => ~U[2026-08-11 00:00:00.000Z]}}} =
               TypeCodec.decode(body, opts())
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
               TypeCodec.decode(body, opts())

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
               TypeCodec.decode(body, opts())

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
               TypeCodec.decode(body, opts())

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
               TypeCodec.decode(body, opts())
    end

    test "key_fn is applied throughout, including inside _source" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{
        "_index" => "posts",
        "_id" => "1",
        "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
      }

      assert {:ok, %{_id: "1", _source: %{published_at: ~U[2026-08-11 00:00:00.000Z]}}} =
               TypeCodec.decode(body, opts(key_fn: &String.to_atom/1))
    end
  end

  describe "decode/2 — opts[:source] (Document.get_source/3 shape)" do
    test "a bare source with no embedded _index uses opts[:index]" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{"published_at" => "2026-08-11T00:00:00.000Z"}

      assert {:ok, %{"published_at" => ~U[2026-08-11 00:00:00.000Z]}} =
               TypeCodec.decode(body, opts(source: true, index: "posts"))
    end
  end

  describe "encode/2 — a single document" do
    test "dumps the whole body against opts[:index]'s mapping" do
      HTTPStub.start_mapping_cacher!(@mapping)

      document = %{"published_at" => ~U[2026-08-11 00:00:00Z]}

      assert TypeCodec.encode(document, opts(index: "posts")) ==
               {:ok, %{"published_at" => "2026-08-11T00:00:00Z"}}
    end

    test "with opts[:doc_key], only that sub-key is dumped (Document.update/4 shape)" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{"doc" => %{"published_at" => ~U[2026-08-11 00:00:00Z]}}

      assert TypeCodec.encode(body, opts(index: "posts", doc_key: :doc)) ==
               {:ok, %{"doc" => %{"published_at" => "2026-08-11T00:00:00Z"}}}
    end

    test "a %{script: ...} update body with no doc_key match passes through" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{"script" => %{"source" => "ctx._source.views++"}}

      assert TypeCodec.encode(body, opts(index: "posts", doc_key: :doc)) == {:ok, body}
    end

    test "no opts[:index] means no mapping — values pass through" do
      document = %{"published_at" => ~U[2026-08-11 00:00:00Z]}
      assert TypeCodec.encode(document, opts()) == {:ok, document}
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
              ]} = TypeCodec.encode(operations, opts(index: "posts"))
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
               TypeCodec.encode(operations, opts(index: "posts"))
    end
  end
end
