defmodule Dowser.Elasticsearch.DecoderTest do
  use ExUnit.Case, async: false

  alias Dowser.Elasticsearch.Decoder
  alias Dowser.Elasticsearch.HTTPStub

  @mapping %{
    "properties" => %{
      "published_at" => %{"type" => "date", "format" => "strict_date_optional_time"},
      "ip" => %{"type" => "ip"}
    }
  }

  @context Dowser.Client.Context.new(endpoint: "http://x:9200")

  defp opts(extra \\ []),
    do: Keyword.merge([context: @context, key_fn: &Function.identity/1], extra)

  describe "decode/2 — document found at any depth" do
    test "a bare document (Document.get/3 shape) is cast" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{
        "_index" => "posts",
        "_id" => "1",
        "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
      }

      assert %{"_source" => %{"published_at" => ~U[2026-08-11 00:00:00.000Z]}} =
               Decoder.decode(body, opts())
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

      assert %{"hits" => %{"hits" => [%{"_source" => source}]}} = Decoder.decode(body, opts())
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
               Decoder.decode(body, opts())

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
               Decoder.decode(body, opts())

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
               Decoder.decode(body, opts())
    end

    test "key_fn is applied throughout, including inside _source" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{
        "_index" => "posts",
        "_id" => "1",
        "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
      }

      assert %{_id: "1", _source: %{published_at: ~U[2026-08-11 00:00:00.000Z]}} =
               Decoder.decode(body, opts(key_fn: &String.to_atom/1))
    end
  end

  describe "decode/2 — opts[:source] (Document.get_source/3 shape)" do
    test "a bare source with no embedded _index uses opts[:index]" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{"published_at" => "2026-08-11T00:00:00.000Z"}

      assert %{"published_at" => ~U[2026-08-11 00:00:00.000Z]} =
               Decoder.decode(body, opts(source: true, index: "posts"))
    end
  end

  describe "decode/2 — opts[:codec]" do
    defmodule UpcaseCodec do
      @behaviour Dowser.Elasticsearch.Codec

      @impl true
      def decode(value, %{"type" => "text"}) when is_binary(value), do: String.upcase(value)
      def decode(value, field), do: Dowser.Elasticsearch.Codec.decode(value, field)

      @impl true
      def encode(value, field), do: Dowser.Elasticsearch.Codec.encode(value, field)
    end

    test "values are cast through the given codec instead of the default" do
      HTTPStub.start_mapping_cacher!(%{
        "properties" => %{"title" => %{"type" => "text"}}
      })

      body = %{"_index" => "posts", "_source" => %{"title" => "hello"}}

      assert %{"_source" => %{"title" => "HELLO"}} =
               Decoder.decode(body, opts(codec: UpcaseCodec))

      assert %{"_source" => %{"title" => "hello"}} = Decoder.decode(body, opts())
    end
  end
end
