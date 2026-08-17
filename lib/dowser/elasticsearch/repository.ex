defmodule Dowser.Elasticsearch.Repository do
  @moduledoc """
  The repository pattern: binds the index-related API functions to a fixed or
  computed index.

      defmodule Probes do
        use Dowser.Elasticsearch.Repository,
          only: [search: [:msearch, :search]],
          index: &index_name/1

        def index_name(term) do
          "my_index_\#{term}"
        end
      end

      %{query: %{match_all: %{}}} |> Probes.search(index: "day1")
      # searches my_index_day1

  ## Options

    * `:index` (required) — where the repository points:
      * a string or atom (or a list of them): a *static* index. Index
        arguments disappear from the generated functions entirely —
        `Probes.get("1")`, `Probes.search(query)` — and any `:index` option
        passed by the caller is overwritten.
      * a 1-arity function capture (or `fn`): a *dynamic* index. Wherever the
        underlying API takes an index, the generated function takes a *term*
        instead — positionally (`Probes.get(term, "1")`) or as the `:index`
        option (`Probes.search(query, index: term)`, `nil` when absent) — and
        the function turns the term into the actual index.
    * `:only` / `:except` — mutually exclusive filters over the generated
      functions. Each entry is either a module key alone to select every
      function of that module, or `key: [:fun, ...]` for specific ones. Module
      keys: `:search` (`Dowser.Elasticsearch.Search`), `:document`
      (`Dowser.Elasticsearch.Document`) and `:index`
      (`Dowser.Elasticsearch.Index`). Base names select their `!`/`?`
      variants too. Without `:only`/`:except`, every index-related function
      of all three modules is generated.

  Two functions selected from different modules can end up sharing the same
  base name (e.g. a future endpoint named `create` in more than one module).
  `renames/0` below is a fixed table renaming such functions (`!`/`?`
  variants follow the rename); `use` raises an `ArgumentError` naming the
  clash if it finds one that `renames/0` does not cover, so the fix is to add
  an entry there rather than to work around it at the call site.

  Only index-related functions can be generated; functions that do not target
  an index (`reindex`, `scroll`, templates, …) never are — call their module
  directly.
  """

  @modules [
    document: Dowser.Elasticsearch.Document,
    index: Dowser.Elasticsearch.Index,
    search: Dowser.Elasticsearch.Search
  ]

  # Renames generated functions that would otherwise collide with another
  # selected module's function of the same base name. Keyed by
  # `{module, base_name}`, valued with the replacement base name — add an
  # entry here when a new endpoint collides with one from another module.
  @spec renames() :: %{optional({module(), atom()}) => atom()}
  defp renames do
    %{
      {Dowser.Elasticsearch.Document, :create} => :create_doc,
      {Dowser.Elasticsearch.Document, :delete} => :delete_doc,
      {Dowser.Elasticsearch.Document, :exists} => :doc_exists,
      {Dowser.Elasticsearch.Document, :get} => :get_doc,
      {Dowser.Elasticsearch.Document, :index} => :index_doc,
      {Dowser.Elasticsearch.Document, :update} => :update_doc
    }
  end

  defmacro __using__(opts) do
    index = fetch_index!(opts)
    style = index_style!(index)
    selected = select!(Keyword.get(opts, :only), Keyword.get(opts, :except))
    renamed = apply_rename(selected)
    check_conflicts!(renamed)

    helpers(index, renamed) ++ Enum.flat_map(renamed, &function_defs(&1, style))
  end

  @doc """
  Resolves a repository `:index` configuration against a term: calls it when
  it is a 1-arity function, returns it unchanged otherwise.
  """
  @spec resolve_index(term(), term()) :: Dowser.Elasticsearch.Index.t()
  def resolve_index(fun, term) when is_function(fun, 1), do: fun.(term)
  def resolve_index(index, _term), do: index

  ## Private functions — code generation

  defp helpers(_index, []), do: []

  defp helpers(index, selected) do
    index_helper =
      quote do
        defp __repository_index__(term) do
          Dowser.Elasticsearch.Repository.resolve_index(unquote(index), term)
        end
      end

    opts_helper =
      if Enum.any?(selected, fn {_key, _mod, _call_name, _def_name, {spec, _arity, _kind}} ->
           spec == :opts
         end) do
        quote do
          defp __repository_opts__(opts) do
            {term, opts} = Keyword.pop(opts, :index)
            Keyword.put(opts, :index, __repository_index__(term))
          end
        end
      end

    Enum.reject([index_helper, opts_helper], &is_nil/1)
  end

  defp function_defs({_key, mod, call_name, def_name, {index_spec, arity, kind}}, style) do
    {call_variants, def_variants} =
      case kind do
        :pair ->
          {[call_name, :"#{call_name}!"], [def_name, :"#{def_name}!"]}

        :predicate ->
          {[call_name, :"#{call_name}?"], [def_name, :"#{def_name}?"]}
      end

    call_variants
    |> Enum.zip(def_variants)
    |> Enum.map(fn {call_name, def_name} ->
      build_def(mod, call_name, def_name, index_spec, arity, style)
    end)
  end

  defp build_def(mod, call_name, def_name, :opts, arity, _style) do
    lead = Macro.generate_arguments(arity - 1, __MODULE__)

    quote do
      @doc unquote(delegate_doc(mod, call_name, arity))
      def unquote(def_name)(unquote_splicing(lead), opts \\ []) do
        unquote(mod).unquote(call_name)(unquote_splicing(lead), __repository_opts__(opts))
      end
    end
  end

  defp build_def(mod, call_name, def_name, {:pos, position}, arity, :dynamic) do
    args = Macro.generate_arguments(arity - 1, __MODULE__)
    term = Enum.at(args, position)
    call_args = List.replace_at(args, position, quote(do: __repository_index__(unquote(term))))

    quote do
      @doc unquote(delegate_doc(mod, call_name, arity))
      def unquote(def_name)(unquote_splicing(args), opts \\ []) do
        unquote(mod).unquote(call_name)(unquote_splicing(call_args), opts)
      end
    end
  end

  defp build_def(mod, call_name, def_name, {:pos, position}, arity, :static) do
    args = Macro.generate_arguments(arity - 2, __MODULE__)
    call_args = List.insert_at(args, position, quote(do: __repository_index__(nil)))

    quote do
      @doc unquote(delegate_doc(mod, call_name, arity))
      def unquote(def_name)(unquote_splicing(args), opts \\ []) do
        unquote(mod).unquote(call_name)(unquote_splicing(call_args), opts)
      end
    end
  end

  defp delegate_doc(mod, name, arity) do
    "Calls `#{inspect(mod)}.#{name}/#{arity}` with the repository index."
  end

  ## Private functions — option parsing

  defp fetch_index!(opts) do
    case Keyword.fetch(opts, :index) do
      {:ok, index} ->
        index

      :error ->
        raise ArgumentError,
              "the :index option is required when using Dowser.Elasticsearch.Repository"
    end
  end

  defp index_style!(index) do
    case index do
      {:&, _meta, _args} ->
        :dynamic

      {:fn, _meta, _clauses} ->
        :dynamic

      value when is_binary(value) or is_atom(value) or is_list(value) ->
        :static

      other ->
        raise ArgumentError,
              ":index must be a string, an atom, a list of them, or a 1-arity function, " <>
                "got: #{Macro.to_string(other)}"
    end
  end

  defp select!(only, except) do
    cond do
      only != nil and except != nil ->
        raise ArgumentError, ":only and :except are mutually exclusive"

      only != nil ->
        Enum.uniq_by(expand_spec!(only), fn {key, _mod, name, _meta} -> {key, name} end)

      except != nil ->
        excluded =
          except
          |> expand_spec!()
          |> MapSet.new(fn {key, _mod, name, _meta} -> {key, name} end)

        Enum.reject(all_functions(), fn {key, _mod, name, _meta} ->
          MapSet.member?(excluded, {key, name})
        end)

      true ->
        all_functions()
    end
  end

  defp all_functions do
    for {key, mod} <- @modules, {name, meta} <- mod.__repository__() do
      {key, mod, name, meta}
    end
  end

  defp expand_spec!(spec) when is_list(spec) do
    Enum.flat_map(spec, fn
      key when is_atom(key) ->
        mod = fetch_module!(key)

        for {name, meta} <- mod.__repository__() do
          {key, mod, name, meta}
        end

      {key, names} when is_list(names) ->
        mod = fetch_module!(key)
        metadata = mod.__repository__()

        Enum.map(names, fn name ->
          case Keyword.fetch(metadata, name) do
            {:ok, meta} ->
              {key, mod, name, meta}

            :error ->
              raise ArgumentError,
                    "unknown repository function #{inspect(name)} for #{inspect(mod)}; " <>
                      "available: #{inspect(Keyword.keys(metadata))}"
          end
        end)

      other ->
        raise ArgumentError,
              "invalid :only/:except entry: #{inspect(other)}; expected a module key " <>
                "(#{inspect(Keyword.keys(@modules))}) or `key: [:function, ...]`"
    end)
  end

  defp expand_spec!(other) do
    raise ArgumentError, ":only/:except must be a list, got: #{inspect(other)}"
  end

  defp fetch_module!(key) do
    Keyword.get(@modules, key) ||
      raise ArgumentError,
            "unknown module key #{inspect(key)}; known keys: #{inspect(Keyword.keys(@modules))}"
  end

  ## Private functions — renaming

  defp apply_rename(selected) do
    table = renames()

    Enum.map(selected, fn {key, mod, name, meta} ->
      def_name =
        Enum.find_value(table, name, fn {rename_key, new_name} ->
          if rename_key == {mod, name} do
            new_name
          end
        end)

      {key, mod, name, def_name, meta}
    end)
  end

  defp check_conflicts!(renamed) do
    renamed
    |> Enum.group_by(fn {_key, _mod, _call_name, def_name, _meta} -> def_name end)
    |> Enum.each(fn {def_name, entries} ->
      if length(entries) > 1 do
        mods = Enum.map(entries, fn {_key, mod, _call_name, _def_name, _meta} -> inspect(mod) end)

        raise ArgumentError,
              "conflicting repository function name #{inspect(def_name)} generated from " <>
                "#{Enum.join(mods, " and ")}; add an entry to renames/0 in " <>
                "Dowser.Elasticsearch.Repository to disambiguate"
      end
    end)
  end
end
