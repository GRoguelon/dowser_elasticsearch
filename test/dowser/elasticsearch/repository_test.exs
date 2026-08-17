defmodule Dowser.Elasticsearch.RepositoryTest do
  use ExUnit.Case, async: true

  alias Dowser.Elasticsearch.HTTPStub

  defp config(port), do: HTTPStub.config(port)
  defp start_server(response \\ HTTPStub.ok_response()), do: HTTPStub.start_server(response)

  defmodule StaticRepo do
    use Dowser.Elasticsearch.Repository,
      index: "probes",
      only: [
        search: [:search],
        document: [:get, :exists, :index],
        index: [:refresh, :delete_index]
      ]
  end

  defmodule DynamicRepo do
    use Dowser.Elasticsearch.Repository,
      only: [search: [:msearch, :search], document: [:get]],
      index: &index_name/1

    def index_name(term) do
      "my_index_#{term}"
    end
  end

  defmodule ExceptRepo do
    use Dowser.Elasticsearch.Repository,
      index: :probes,
      except: [:document, :index, search: [:msearch]]
  end

  describe "static index" do
    test "search/2 injects the index option" do
      {port, server} = start_server()

      assert {:ok, _} = StaticRepo.search(%{}, config: config(port))
      assert Task.await(server).path == "/probes/_search"
    end

    test "search/2 overwrites a caller-supplied index" do
      {port, server} = start_server()

      assert {:ok, _} = StaticRepo.search(%{}, index: "other", config: config(port))
      assert Task.await(server).path == "/probes/_search"
    end

    test "positional index arguments disappear" do
      {port, server} = start_server()

      assert {:ok, _} = StaticRepo.get_doc("1", config: config(port))
      assert Task.await(server).path == "/probes/_doc/1"

      {port, server} = start_server()

      assert {:ok, _} = StaticRepo.index_doc(%{"title" => "hi"}, config: config(port))
      assert Task.await(server).path == "/probes/_doc"

      {port, server} = start_server()

      assert {:ok, _} = StaticRepo.delete_index(config: config(port))

      req = Task.await(server)
      assert req.method == "DELETE"
      assert req.path == "/probes"
    end

    test "opts-style index functions target the repository index" do
      {port, server} = start_server()

      assert {:ok, _} = StaticRepo.refresh(config: config(port))
      assert Task.await(server).path == "/probes/_refresh"
    end

    test "bang and predicate variants are generated" do
      {port, server} = start_server()
      assert %{"acknowledged" => true} = StaticRepo.search!(%{}, config: config(port))
      Task.await(server)

      {port, server} = start_server(HTTPStub.head_response(404))
      assert {:ok, false} = StaticRepo.doc_exists("1", config: config(port))
      Task.await(server)

      {port, server} = start_server(HTTPStub.head_response(200))
      assert StaticRepo.doc_exists?("1", config: config(port)) == true
      Task.await(server)
    end

    test "unselected functions are not generated" do
      refute function_exported?(StaticRepo, :msearch, 2)
      refute function_exported?(StaticRepo, :count, 2)
      refute function_exported?(StaticRepo, :delete_doc, 2)
    end
  end

  describe "dynamic index" do
    test "the :index option is the term passed to the index function" do
      {port, server} = start_server()

      assert {:ok, _} = DynamicRepo.search(%{}, index: "day1", config: config(port))
      assert Task.await(server).path == "/my_index_day1/_search"
    end

    test "positional index arguments become terms" do
      {port, server} = start_server()

      assert {:ok, _} = DynamicRepo.get_doc("day1", "1", config: config(port))
      assert Task.await(server).path == "/my_index_day1/_doc/1"
    end

    test "an absent :index option passes nil to the index function" do
      {port, server} = start_server()

      assert {:ok, _} = DynamicRepo.search(%{}, config: config(port))
      assert Task.await(server).path == "/my_index_/_search"
    end
  end

  describe "except" do
    test "keeps everything but the excluded functions" do
      {port, server} = start_server()

      assert {:ok, _} = ExceptRepo.count(%{}, config: config(port))
      assert Task.await(server).path == "/probes/_count"

      refute function_exported?(ExceptRepo, :msearch, 2)
      refute function_exported?(ExceptRepo, :get, 2)
      refute function_exported?(ExceptRepo, :refresh, 1)
    end
  end

  describe "cross-module name collisions" do
    test "no two API modules expose a repository function under the same name" do
      names =
        for mod <- [
              Dowser.Elasticsearch.Document,
              Dowser.Elasticsearch.Index,
              Dowser.Elasticsearch.Search
            ],
            {name, _meta} <- mod.__repository__() do
          name
        end

      duplicates = names -- Enum.uniq(names)

      assert duplicates == [],
             "these repository function names are shared by more than one module: " <>
               "#{inspect(duplicates)}; add an entry to `renames/0` in " <>
               "Dowser.Elasticsearch.Repository to disambiguate them"
    end
  end

  describe "compile-time validation" do
    test "requires the :index option" do
      assert_raise ArgumentError, ~r/:index option is required/, fn ->
        defmodule NoIndex do
          use Dowser.Elasticsearch.Repository, only: [:search]
        end
      end
    end

    test "rejects unknown function names" do
      assert_raise ArgumentError, ~r/unknown repository function :nope/, fn ->
        defmodule UnknownFunction do
          use Dowser.Elasticsearch.Repository, index: "x", only: [search: [:nope]]
        end
      end
    end

    test "rejects unknown module keys" do
      assert_raise ArgumentError, ~r/unknown module key :cluster/, fn ->
        defmodule UnknownModule do
          use Dowser.Elasticsearch.Repository, index: "x", only: [:cluster]
        end
      end
    end

    test "rejects :only combined with :except" do
      assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
        defmodule Both do
          use Dowser.Elasticsearch.Repository, index: "x", only: [:search], except: [:document]
        end
      end
    end

    test "rejects an invalid :index" do
      assert_raise ArgumentError, ~r/:index must be/, fn ->
        defmodule BadIndex do
          use Dowser.Elasticsearch.Repository, index: 123, only: [:search]
        end
      end
    end
  end
end
