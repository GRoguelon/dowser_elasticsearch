defmodule Dowser.Elasticsearch.CastingOptionsTest do
  use ExUnit.Case, async: false

  alias Dowser.Client.HTTP.Stub
  alias Dowser.Elasticsearch.Document
  alias Dowser.Elasticsearch.Search

  # A document module written out by hand — what `use ...Schema` will
  # generate.
  defmodule Post do
    @behaviour Dowser.Schema

    defstruct [:title, :published_at, :id]

    @mapping %{
      "properties" => %{
        "title" => %{"type" => "text"},
        "published_at" => %{"type" => "date", "format" => "strict_date_time"}
      }
    }

    @impl true
    def __schema__(:mapping), do: @mapping

    @impl true
    def __load__(source, opts) do
      source = Dowser.Source.load(source, @mapping, Keyword.put(opts, :unknown_fields, :raise))

      %__MODULE__{
        title: source["title"],
        published_at: source["published_at"],
        id: opts |> Keyword.get(:meta, %{}) |> Map.get("_id")
      }
    end

    @impl true
    def __dump__(%__MODULE__{} = post, opts) do
      Dowser.Source.dump(
        %{"title" => post.title, "published_at" => post.published_at},
        @mapping,
        opts
      )
    end
  end

  defmodule Upcase do
    @behaviour Dowser.Type

    @impl true
    def load(value, %{"type" => "text"}) when is_binary(value), do: String.upcase(value)
    def load(value, field), do: Dowser.Type.load(value, field)

    @impl true
    def dump(value, field), do: Dowser.Type.dump(value, field)
  end

  # A repo with no decoder or encoder configured: nothing is cast unless a
  # call asks for it.
  @repo [endpoint: "http://search:9200"]

  @doc_body %{
    "_index" => "posts",
    "_id" => "1",
    "found" => true,
    "_source" => %{"title" => "hi", "published_at" => "2026-08-11T00:00:00.000Z"}
  }

  defp stub(body) do
    Stub.stub(fn _method, _url, _headers, request_body, _opts ->
      send(self(), {:sent, request_body && IO.iodata_to_binary(request_body)})
      Stub.json(200, body)
    end)
  end

  test "without casting options, nothing is cast" do
    stub(@doc_body)

    assert {:ok, %{"_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}}} =
             Document.get("posts", "1", repo: @repo)
  end

  test "struct: loads the document into the struct, even with no decoder configured" do
    stub(@doc_body)

    assert {:ok, %{"_source" => %Post{} = post}} =
             Document.get("posts", "1", repo: @repo, struct: Post)

    assert post.title == "hi"
    assert post.published_at == ~U[2026-08-11 00:00:00.000Z]
    assert post.id == "1"
  end

  test "keys: applies to the response around the struct, not to the struct" do
    stub(@doc_body)

    assert {:ok, %{_id: "1", _source: %Post{title: "hi", id: "1"}}} =
             Document.get("posts", "1", repo: @repo ++ [keys: :atoms], struct: Post)
  end

  test "struct: loads every search hit" do
    stub(%{"hits" => %{"hits" => [@doc_body, Map.put(@doc_body, "_id", "2")]}})

    assert {:ok, %{"hits" => %{"hits" => hits}}} =
             Search.search(%{query: %{match_all: %{}}}, index: "posts", repo: @repo, struct: Post)

    assert [%{"_source" => %Post{id: "1"}}, %{"_source" => %Post{id: "2"}}] = hits
  end

  test "struct: dumps the struct when writing it" do
    stub(%{"result" => "created"})

    post = %Post{title: "hi", published_at: ~U[2026-08-11 00:00:00Z]}

    assert {:ok, _body} = Document.index(post, "posts", repo: @repo, struct: Post, id: "1")
    assert_received {:sent, body}
    assert JSON.decode!(body) == %{"title" => "hi", "published_at" => "2026-08-11T00:00:00.000Z"}
  end

  test "mapping: casts with the given mapping, documents staying maps" do
    stub(@doc_body)

    assert {:ok, %{"_source" => %{"published_at" => ~U[2026-08-11 00:00:00.000Z]}}} =
             Document.get("posts", "1", repo: @repo, mapping: Post)
  end

  test "types: picks the type module for this call" do
    stub(@doc_body)

    assert {:ok, %{"_source" => %{"title" => "HI"}}} =
             Document.get("posts", "1", repo: @repo, mapping: Post, types: Upcase)
  end

  test "unknown_fields: :raise is returned as the error itself" do
    stub(put_in(@doc_body, ["_source", "extra"], 1))

    assert {:error, %Dowser.UnknownFieldError{path: ["extra"]}} =
             Document.get("posts", "1", repo: @repo, mapping: Post, unknown_fields: :raise)
  end

  test "the removed codec: is an error naming :types" do
    assert {:error, %Dowser.Client.Error{reason: {:removed_option, :codec}} = error} =
             Document.get("posts", "1", repo: @repo, codec: Upcase)

    assert Exception.message(error) =~ ":types"
  end
end
