defmodule Dowser.Elasticsearch.RepoTest do
  use ExUnit.Case, async: false

  alias Dowser.Client.HTTP.Stub
  alias Dowser.Elasticsearch.Info

  defmodule Search do
    use Dowser.Elasticsearch.Repo, otp_app: :dowser_elasticsearch
  end

  defmodule Logs do
    use Dowser.Elasticsearch.Repo, otp_app: :dowser_elasticsearch
  end

  @elasticsearch %{
    "version" => %{"number" => "8.15.0", "build_flavor" => "default"},
    "tagline" => "You Know, for Search"
  }

  @opensearch %{
    "version" => %{"distribution" => "opensearch", "number" => "2.15.0"},
    "tagline" => "The OpenSearch Project: https://opensearch.org/"
  }

  setup do
    Application.put_env(:dowser_elasticsearch, Search, endpoint: "http://search:9200")
    Application.put_env(:dowser_elasticsearch, Logs, endpoint: "http://logs:9200")

    on_exit(fn ->
      Application.delete_env(:dowser_elasticsearch, Search)
      Application.delete_env(:dowser_elasticsearch, Logs)
      Application.delete_env(:dowser_elasticsearch, :default_repo)
    end)
  end

  # Answers `GET /` with `body` (and `headers`), and records every URL requested.
  defp stub_root(body, headers \\ []) do
    Stub.stub(fn _method, url, _headers, _body, _opts ->
      send(self(), {:url, url})
      Stub.json(200, body, headers)
    end)
  end

  describe "verify/1" do
    test "recognizes Elasticsearch by its x-elastic-product header" do
      stub_root(%{"version" => %{"number" => "8.15.0"}}, [{"x-elastic-product", "Elasticsearch"}])

      assert Search.verify(Search.config()) == {:ok, {:elasticsearch, "8.15.0"}}
      assert_received {:url, "http://search:9200/"}
    end

    test "recognizes an older release by its tagline" do
      stub_root(@elasticsearch)

      assert Search.verify(Search.config()) == {:ok, {:elasticsearch, "8.15.0"}}
    end

    test "rejects an OpenSearch cluster, tagline or not" do
      stub_root(Map.put(@opensearch, "tagline", "You Know, for Search"))

      assert {:error, {:unexpected_engine, %{"distribution" => "opensearch"}}} =
               Search.verify(Search.config())
    end

    test "rejects a cluster with neither signature" do
      stub_root(%{"version" => %{"number" => "1.0.0"}, "tagline" => "Something else"})

      assert {:error, {:unexpected_engine, %{"number" => "1.0.0"}}} =
               Search.verify(Search.config())
    end

    test "reports a response that isn't a cluster description" do
      Stub.stub(fn _method, _url, _headers, _body, _opts ->
        Stub.json(401, %{"error" => "no"})
      end)

      assert {:error, {:unexpected_response, 401, %{"error" => "no"}}} =
               Search.verify(Search.config())
    end

    test "ignores the repo's decoder: the cluster description is not a document" do
      Application.put_env(:dowser_elasticsearch, Search,
        endpoint: "http://search:9200",
        keys: :atoms,
        decoder: Dowser.Elasticsearch.Codec
      )

      stub_root(@elasticsearch)

      assert Search.verify(Search.config()) == {:ok, {:elasticsearch, "8.15.0"}}
    end
  end

  describe "choosing the repo" do
    test "the API functions go to the default repo when a call names none" do
      Application.put_env(:dowser_elasticsearch, :default_repo, Search)
      stub_root(@elasticsearch)

      assert {:ok, %{"tagline" => _}} = Info.info()
      assert_received {:url, "http://search:9200/"}
    end

    test ":repo wins over the default repo" do
      Application.put_env(:dowser_elasticsearch, :default_repo, Search)
      stub_root(@elasticsearch)

      assert {:ok, _body} = Info.info(repo: Logs)
      assert_received {:url, "http://logs:9200/"}
    end

    test "a dynamic instance is reached through put_dynamic_repo/1 or {repo, name}" do
      start_supervised!({Search, name: :tenant_a, endpoint: "http://tenant-a:9200"})
      Application.put_env(:dowser_elasticsearch, :default_repo, Search)
      stub_root(@elasticsearch)

      assert {:ok, _body} = Info.info(repo: {Search, :tenant_a})
      assert_received {:url, "http://tenant-a:9200/"}

      Search.with_dynamic_repo(:tenant_a, fn ->
        assert {:ok, _body} = Info.info()
      end)

      assert_received {:url, "http://tenant-a:9200/"}

      assert {:ok, _body} = Info.info()
      assert_received {:url, "http://search:9200/"}
    end

    test "an ad-hoc repo works without a module" do
      stub_root(@elasticsearch)

      assert {:ok, _body} = Info.info(repo: [endpoint: "http://adhoc:9200"])
      assert_received {:url, "http://adhoc:9200/"}
    end

    test "no :repo and no default repo is an error naming both" do
      assert {:error, %Dowser.Client.Error{reason: :no_repo} = error} =
               Info.info()

      assert Exception.message(error) =~ ":default_repo"
    end

    test "the removed :context option is an error pointing at :repo" do
      Application.put_env(:dowser_elasticsearch, :default_repo, Search)

      assert {:error, %Dowser.Client.Error{reason: {:removed_option, :context}}} =
               Info.info(context: [endpoint: "http://x:9200"])
    end

    test "the repo's own casting configuration is used" do
      Application.put_env(:dowser_elasticsearch, Search,
        endpoint: "http://search:9200",
        keys: :atoms
      )

      Application.put_env(:dowser_elasticsearch, :default_repo, Search)
      stub_root(@elasticsearch)

      assert {:ok, %{tagline: _}} = Info.info()
    end
  end

  describe "the HTTP verbs" do
    test "reach any endpoint, on the repo's cluster" do
      Stub.stub(fn :post, url, _headers, _body, _opts ->
        send(self(), {:url, url})
        Stub.json(200, %{"hits" => %{"hits" => []}})
      end)

      assert {:ok, %Dowser.Client.Response{status: 200}} =
               Search.post("/_ml/trained_models/_search", %{query: %{match_all: %{}}})

      assert_received {:url, "http://search:9200/_ml/trained_models/_search"}
    end
  end
end
