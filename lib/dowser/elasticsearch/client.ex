defmodule Dowser.Elasticsearch.Client do
  @moduledoc false

  # The seam between this package's API modules and `Dowser.Client`.
  #
  # Every API function goes through the verbs below rather than calling
  # `Dowser.Client` directly, so the options this package adds on top of the
  # client's are handled in one place — the default repo and the casting
  # options (`:mapping`, `:struct`, `:types`, `:unknown_fields`,
  # `:mapping_failure`). A request
  # option only some endpoints honoured would be worse than none at all: the
  # rest would ignore it silently.
  #
  # Requests go through `Dowser.Repo.request/5`, so a repo module sees every one
  # of them — which is what lets a test swap it for a mock.
  #
  # The rest of the module resolves `:decoder`/`:encoder` the way
  # `Dowser.Client.Request` does — request, then repo, then the application
  # environment — which the API functions need in order to hand the decoder and
  # the encoder what their endpoint's shape requires.

  alias Dowser.Repo.Config

  ## Module attributes

  @codec Dowser.Elasticsearch.Codec

  @casting_options [:mapping, :struct, :types, :unknown_fields, :mapping_failure]

  ## Public functions — the request funnel

  @doc "Runs a `GET` against the repo; see `request/4`."
  @spec get(String.t(), keyword()) :: Dowser.Client.result()
  def get(path, opts), do: request(:get, path, nil, opts)

  @doc "Runs a `POST` against the repo; see `request/4`."
  @spec post(String.t(), term(), keyword()) :: Dowser.Client.result()
  def post(path, body, opts), do: request(:post, path, body, opts)

  @doc "Runs a `PUT` against the repo; see `request/4`."
  @spec put(String.t(), term(), keyword()) :: Dowser.Client.result()
  def put(path, body, opts), do: request(:put, path, body, opts)

  @doc "Runs a `DELETE` against the repo; see `request/4`."
  @spec delete(String.t(), term(), keyword()) :: Dowser.Client.result()
  def delete(path, body, opts), do: request(:delete, path, body, opts)

  @doc """
  Runs a request against `repo/1`'s repo, through `Dowser.Repo.request/5`,
  with the casting options folded in (see `put_casting/1`).
  """
  @spec request(Dowser.Client.method(), String.t(), term(), keyword()) :: Dowser.Client.result()
  def request(method, path, body, opts) do
    repo = repo(opts)
    opts = opts |> put_casting() |> Keyword.delete(:repo)

    Dowser.Repo.request(repo, method, path, body, opts)
  end

  @doc """
  The repo a request goes to: its `:repo` option, else
  `config :dowser_elasticsearch, default_repo: ...`, else `nil` — which
  `Dowser.Client` reports as `:no_repo`.
  """
  @spec repo(keyword()) :: Dowser.Repo.t() | nil
  def repo(opts) do
    Keyword.get(opts, :repo) || Application.get_env(:dowser_elasticsearch, :default_repo)
  end

  ## Public functions — the casting options

  @doc """
  Folds the request-level casting options — `:mapping`, `:struct`, `:types`,
  `:unknown_fields` and `:mapping_failure` — into whichever of
  `:decoder`/`:encoder` is in play, and removes them from `opts`.

  They are this package's options, not `Dowser.Client`'s, and the client hands
  a decoder/encoder only its *own* options — so the short spelling at the call
  site has to be moved inside them here. They win over the same options given
  on the decoder/encoder itself, which is what makes them the per-request tier;
  see `Dowser.Elasticsearch.Codec` for the rest.

  `:mapping` and `:struct` ask for casting outright, so with no decoder or
  encoder configured they bring `Dowser.Elasticsearch.Codec` in. The others only
  adjust a casting that is configured, and are dropped without one.
  """
  @spec put_casting(keyword()) :: keyword()
  def put_casting(opts) do
    case Keyword.split(opts, @casting_options) do
      {[], opts} ->
        opts

      {casting, opts} ->
        opts
        |> put_casting_on(:decoder, casting)
        |> put_casting_on(:encoder, casting)
    end
  end

  @doc """
  Supplies the decoder — when one is configured at all — with what this
  endpoint's response shape needs (e.g. `:index`, `:source`).

  A `:decoder` replaces the repo's outright rather than merging with it, so
  the one in play is resolved first and handed back with `extra` filled in;
  keys the caller already set on it win. Without a decoder anywhere, `opts` is
  returned untouched and no casting happens.
  """
  @spec put_decoder(keyword(), keyword()) :: keyword()
  def put_decoder(opts, extra) do
    case in_play(opts, :decoder) do
      nil ->
        opts

      decoder ->
        Keyword.put(opts, :decoder, merge_option_opts(decoder, extra))
    end
  end

  @doc """
  Like `put_decoder/2` for the encoder, plus the `:encode` telling
  `Dowser.Client` where in this request's body the document source sits.

  `:encode` is only set when an encoder is configured, and never over one the
  caller passed themselves.
  """
  @spec put_encoder(keyword(), keyword(), term()) :: keyword()
  def put_encoder(opts, extra, encode) do
    case in_play(opts, :encoder) do
      nil ->
        opts

      encoder ->
        opts
        |> Keyword.put(:encoder, merge_option_opts(encoder, extra))
        |> Keyword.put_new(:encode, encode)
    end
  end

  @doc """
  The response second pass in play, as `{key_fun, decoder}` — both resolved the
  way `Dowser.Client.Request` resolves them, either being `nil` when unset.

  `Dowser.Elasticsearch.Streamer` needs it in hand: its own requests have to come
  back raw, because it reads `hits.hits[]`, each hit's `sort` and the `pit_id`
  by their string keys, so it applies the pass itself to the hits it yields.
  Feed the pair to `Dowser.Client.Decoder.run/3`.
  """
  @spec resolve_decoder(keyword()) ::
          {Dowser.Client.Decoder.key_fun() | nil, Dowser.Client.Decoder.resolved() | nil}
  def resolve_decoder(opts) do
    opts = put_casting(opts)
    {:ok, key_fun} = opts |> fetch_option(:keys) |> Dowser.Client.Decoder.key_fun()

    decoder =
      with decoder when not is_nil(decoder) <- fetch_option(opts, :decoder),
           {:ok, {fun, decoder_opts}} <- Dowser.Client.Decoder.decoder(decoder),
           {:ok, context} <- Config.resolve(repo(opts)) do
        {fun, Keyword.put(decoder_opts, :repo_config, context)}
      else
        _other -> nil
      end

    {key_fun, decoder}
  end

  @doc """
  The encoder in play as `{function, opts}` — its own options plus the repo,
  resolved, as `:repo_config` — or `nil` when none is configured.

  `Dowser.Client` normalizes and calls the encoder itself for every other
  endpoint; `Dowser.Elasticsearch.Document.bulk/2` needs it in hand, because a
  bulk payload is cast against the index named on the action line above it,
  which no per-line pass can see.
  """
  @spec resolve_encoder(keyword()) :: {(term(), keyword() -> term()), keyword()} | nil
  def resolve_encoder(opts) do
    opts = put_casting(opts)

    with encoder when not is_nil(encoder) <- fetch_option(opts, :encoder),
         {:ok, {fun, encoder_opts}} <- Dowser.Client.Encoder.encoder(encoder),
         {:ok, context} <- Config.resolve(repo(opts)) do
      {fun, Keyword.put(encoder_opts, :repo_config, context)}
    else
      _other ->
        nil
    end
  end

  ## Private functions

  # Same precedence `Dowser.Client.Request` applies: request, then repo, then
  # the application environment.
  defp fetch_option(opts, key) do
    Keyword.get(opts, key) || repo_option(opts, key) ||
      Application.get_env(:dowser_client, key)
  end

  defp repo_option(opts, key) do
    case Config.resolve(repo(opts)) do
      {:ok, context} ->
        Map.fetch!(context, key)

      {:error, _reason} ->
        nil
    end
  end

  defp merge_option_opts({module_or_fun, own_opts}, extra) when is_list(own_opts) do
    {module_or_fun, Keyword.merge(extra, own_opts)}
  end

  defp merge_option_opts(module_or_fun, extra), do: {module_or_fun, extra}

  # The decoder or encoder a request will use: the one configured, or this
  # package's codec when the request asks for casting outright.
  defp in_play(opts, key) do
    case fetch_option(opts, key) do
      nil ->
        if Keyword.has_key?(opts, :struct) or Keyword.has_key?(opts, :mapping) do
          @codec
        end

      value ->
        value
    end
  end

  defp put_casting_on(opts, key, casting) do
    case in_play(casting ++ opts, key) do
      nil ->
        opts

      value ->
        Keyword.put(opts, key, Enum.reduce(casting, value, &put_own_opt(&2, &1)))
    end
  end

  # Unlike `merge_option_opts/2`, this one overwrites: an option named at the
  # call site is the most specific tier, so it wins over one the decoder or
  # encoder was configured with.
  defp put_own_opt({module_or_fun, own_opts}, {key, value}) when is_list(own_opts) do
    {module_or_fun, Keyword.put(own_opts, key, value)}
  end

  defp put_own_opt(module_or_fun, {key, value}), do: {module_or_fun, [{key, value}]}
end
