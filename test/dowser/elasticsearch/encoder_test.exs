defmodule Dowser.Elasticsearch.EncoderTest do
  use ExUnit.Case, async: false

  alias Dowser.Elasticsearch.Encoder
  alias Dowser.Elasticsearch.HTTPStub

  defmodule DowncaseCodec do
    @behaviour Dowser.Elasticsearch.Codec

    @impl true
    def decode(value, field), do: Dowser.Elasticsearch.Codec.decode(value, field)

    @impl true
    def encode(value, %{"type" => "text"}) when is_binary(value), do: String.downcase(value)
    def encode(value, field), do: Dowser.Elasticsearch.Codec.encode(value, field)
  end

  @mapping %{
    "properties" => %{
      "published_at" => %{"type" => "date", "format" => "strict_date_optional_time"},
      "ip" => %{"type" => "ip"}
    }
  }

  @context Dowser.Client.Context.new(endpoint: "http://x:9200")

  defp opts(extra \\ []), do: Keyword.merge([context: @context], extra)

  describe "encode/2" do
    test "dumps the source against opts[:index]'s mapping" do
      HTTPStub.start_mapping_cacher!(@mapping)

      document = %{"published_at" => ~U[2026-08-11 00:00:00Z]}

      assert Encoder.encode(document, opts(index: "posts")) ==
               %{"published_at" => "2026-08-11T00:00:00Z"}
    end

    test "no opts[:index] means no mapping — values pass through" do
      document = %{"published_at" => ~U[2026-08-11 00:00:00Z]}

      assert Encoder.encode(document, opts()) == document
    end

    test "with no mapping cacher running, values pass through" do
      document = %{"published_at" => ~U[2026-08-11 00:00:00Z]}

      assert Encoder.encode(document, opts(index: "posts")) == document
    end

    test "opts[:codec] replaces the default codec" do
      HTTPStub.start_mapping_cacher!(%{"properties" => %{"title" => %{"type" => "text"}}})

      document = %{"title" => "HELLO"}

      assert Encoder.encode(document, opts(index: "posts", codec: DowncaseCodec)) ==
               %{"title" => "hello"}

      assert Encoder.encode(document, opts(index: "posts")) == document
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
    Encoder.encode_bulk(operations, &Encoder.encode/2, opts(extra))
  end
end
