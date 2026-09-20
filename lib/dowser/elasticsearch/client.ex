defmodule Dowser.Elasticsearch.Client do
  @moduledoc false

  # The seam between this package's API modules and `Dowser.Client`.
  #
  # Every API function goes through the verbs below rather than calling
  # `Dowser.Client` directly, so the options this package adds on top of the
  # client's are handled in one place — `:codec` today. A request option only
  # some endpoints honoured would be worse than none at all: the rest would
  # ignore it silently.
  #
  # The rest of the module resolves `:decoder`/`:encoder` the way
  # `Dowser.Client.Request` does — request, then context, then the application
  # environment — which the API functions need in order to hand the decoder and
  # the encoder what their endpoint's shape requires.

  alias Dowser.Client.Context

  ## Public functions — the request funnel

  @doc "Runs a `GET` through `Dowser.Client`; see `put_codec/1`."
  @spec get(String.t(), keyword()) :: Dowser.Client.result()
  def get(path, opts), do: Dowser.Client.get(path, put_codec(opts))

  @doc "Runs a `POST` through `Dowser.Client`; see `put_codec/1`."
  @spec post(String.t(), term(), keyword()) :: Dowser.Client.result()
  def post(path, body, opts), do: Dowser.Client.post(path, body, put_codec(opts))

  @doc "Runs a `PUT` through `Dowser.Client`; see `put_codec/1`."
  @spec put(String.t(), term(), keyword()) :: Dowser.Client.result()
  def put(path, body, opts), do: Dowser.Client.put(path, body, put_codec(opts))

  @doc "Runs a `DELETE` through `Dowser.Client`; see `put_codec/1`."
  @spec delete(String.t(), term(), keyword()) :: Dowser.Client.result()
  def delete(path, body, opts), do: Dowser.Client.delete(path, body, put_codec(opts))

  @doc "Runs a request through `Dowser.Client`; see `put_codec/1`."
  @spec request(Dowser.Client.method(), String.t(), term(), keyword()) :: Dowser.Client.result()
  def request(method, path, body, opts) do
    Dowser.Client.request(method, path, body, put_codec(opts))
  end

  ## Public functions — the casting options

  @doc """
  Folds a request-level `:codec` into whichever of `:decoder`/`:encoder` is in
  play, and removes it from `opts`.

  `:codec` is this package's option, not `Dowser.Client`'s, and the client
  hands a decoder/encoder only its *own* options — so the short spelling at the
  call site has to be moved inside them here. It wins over a `:codec` given on
  the decoder/encoder itself, which is what makes it the per-request tier; see
  `Dowser.Elasticsearch.Codec` for the rest.

  With neither a decoder nor an encoder configured there is nothing to cast, so
  the option is simply dropped.
  """
  @spec put_codec(keyword()) :: keyword()
  def put_codec(opts) do
    case Keyword.pop(opts, :codec) do
      {nil, opts} ->
        opts

      {codec, opts} ->
        opts |> put_codec_on(:decoder, codec) |> put_codec_on(:encoder, codec)
    end
  end

  @doc """
  Supplies the decoder — when one is configured at all — with what this
  endpoint's response shape needs (e.g. `:index`, `:source`).

  A `:decoder` replaces the context's outright rather than merging with it, so
  the one in play is resolved first and handed back with `extra` filled in;
  keys the caller already set on it win. Without a decoder anywhere, `opts` is
  returned untouched and no casting happens.
  """
  @spec put_decoder(keyword(), keyword()) :: keyword()
  def put_decoder(opts, extra) do
    case fetch_option(opts, :decoder) do
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
    case fetch_option(opts, :encoder) do
      nil ->
        opts

      encoder ->
        opts
        |> Keyword.put(:encoder, merge_option_opts(encoder, extra))
        |> Keyword.put_new(:encode, encode)
    end
  end

  @doc """
  The encoder in play as `{function, opts}` — its own options plus the resolved
  `:context` — or `nil` when none is configured.

  `Dowser.Client` normalizes and calls the encoder itself for every other
  endpoint; `Dowser.Elasticsearch.Document.bulk/2` needs it in hand, because a
  bulk payload is cast against the index named on the action line above it,
  which no per-line pass can see.
  """
  @spec resolve_encoder(keyword()) :: {(term(), keyword() -> term()), keyword()} | nil
  def resolve_encoder(opts) do
    with encoder when not is_nil(encoder) <- fetch_option(opts, :encoder),
         {:ok, {fun, encoder_opts}} <- Dowser.Client.Encoder.encoder(encoder),
         {:ok, context} <- Context.resolve(Keyword.get(opts, :context)) do
      {fun, Keyword.put(encoder_opts, :context, context)}
    else
      _other ->
        nil
    end
  end

  ## Private functions

  # Same precedence `Dowser.Client.Request` applies: request, then context,
  # then the application environment.
  defp fetch_option(opts, key) do
    Keyword.get(opts, key) || context_option(opts, key) ||
      Application.get_env(:dowser_client, key)
  end

  defp context_option(opts, key) do
    case Context.resolve(Keyword.get(opts, :context)) do
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

  defp put_codec_on(opts, key, codec) do
    case fetch_option(opts, key) do
      nil ->
        opts

      value ->
        Keyword.put(opts, key, put_own_opt(value, :codec, codec))
    end
  end

  # Unlike `merge_option_opts/2`, this one overwrites: a `:codec` named at the
  # call site is the most specific tier, so it wins over one the decoder or
  # encoder was configured with.
  defp put_own_opt({module_or_fun, own_opts}, key, value) when is_list(own_opts) do
    {module_or_fun, Keyword.put(own_opts, key, value)}
  end

  defp put_own_opt(module_or_fun, key, value), do: {module_or_fun, [{key, value}]}
end
