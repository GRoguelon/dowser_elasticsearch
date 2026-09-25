defmodule Dowser.Elasticsearch.Helpers do
  @moduledoc false

  alias Dowser.Client.Response
  alias Dowser.Elasticsearch.Error
  alias Dowser.Elasticsearch.Index
  alias Dowser.Elasticsearch.MappingError

  ## Typespecs

  @typedoc """
  The error a bad argument is reported as — returned by the non-bang API
  functions, raised by the bang ones.
  """
  @type argument_error :: %ArgumentError{}

  ## Public functions

  @doc """
  Parses a `Dowser.Client` result into `{:ok, body}` for a 2xx response,
  `{:error, %Dowser.Elasticsearch.Error{}}` for any other status, and passes
  `{:error, exception}` through untouched.
  """
  @spec parse_result(Dowser.Client.result()) :: {:ok, term()} | {:error, Exception.t()}
  def parse_result({:ok, %Response{status: status, body: body}})
      when status in 200..299 do
    {:ok, body}
  end

  def parse_result({:ok, %Response{status: status, body: body}}) do
    {:error, Error.new(status, body)}
  end

  # A codec that raised because it had no mapping to cast against is reported
  # as itself, not as the `Dowser.Client` decode/encode failure wrapping it:
  # the caller can do something about the first and nothing about the second.
  def parse_result({:error, %Dowser.Client.Error{reason: {kind, %MappingError{} = error}}})
      when kind in [:decode_failed, :encode_failed] do
    {:error, error}
  end

  def parse_result({:error, error}), do: {:error, error}

  @doc """
  Parses a `Dowser.Client` result of a `HEAD` existence check: `{:ok, true}`
  for a 2xx response, `{:ok, false}` for a 404, and an error otherwise.
  """
  @spec parse_exists(Dowser.Client.result()) :: {:ok, boolean()} | {:error, Exception.t()}
  def parse_exists({:ok, %Response{status: status}}) when status in 200..299 do
    {:ok, true}
  end

  def parse_exists({:ok, %Response{status: 404}}) do
    {:ok, false}
  end

  def parse_exists({:ok, %Response{status: status, body: body}}) do
    {:error, Error.new(status, body)}
  end

  def parse_exists({:error, error}), do: {:error, error}

  @doc """
  Builds an endpoint path for an optional index target: `suffix` alone when
  the target is empty, `/{index}` + `suffix` otherwise.
  """
  @spec path(Index.t(), String.t()) :: binary()
  def path(index, suffix) do
    if segment = Index.segment(index) do
      "/" <> segment <> suffix
    else
      suffix
    end
  end

  @doc """
  Builds an endpoint path for an optional *trailing* target — the shape the
  cluster, cat and nodes endpoints use, where `path/2` prefixes: `base` alone
  when the target is empty, `base` + `infix` + `/{target}` otherwise.
  """
  @spec suffix_path(String.t(), Index.name(), String.t()) :: String.t()
  def suffix_path(base, target, infix \\ "") do
    case Index.segment(target) do
      nil ->
        base

      segment ->
        base <> infix <> "/" <> segment
    end
  end

  @doc """
  Like `path/2`, but for endpoints that require an index target: returns
  `{:ok, path}`, or `{:error, %ArgumentError{}}` when the target is empty — so
  a bad argument reaches the caller the same way a bad response does, as the
  `{:error, exception}` a non-bang function returns and a bang one raises.
  """
  @spec required_path(Index.t(), String.t()) :: {:ok, binary()} | {:error, argument_error()}
  def required_path(index, suffix) do
    case Index.segment(index) do
      nil ->
        {:error,
         %ArgumentError{message: "this endpoint requires an index, got: #{inspect(index)}"}}

      segment ->
        {:ok, "/" <> segment <> suffix}
    end
  end

  @doc """
  Encodes a required path parameter into a path segment: `{:ok, segment}`, or
  `{:error, %ArgumentError{}}` naming `label` when the value is empty.
  """
  @spec required_segment(Index.name(), String.t()) ::
          {:ok, binary()} | {:error, argument_error()}
  def required_segment(value, label) do
    case Index.segment(value) do
      nil ->
        {:error, %ArgumentError{message: "#{label} is required, got: #{inspect(value)}"}}

      segment ->
        {:ok, segment}
    end
  end

  @doc """
  Applies a default `:req_format`/`:resp_format`, unless the caller already
  set it — or set `:format`, which is mutually exclusive with both.
  """
  @spec put_default_format(keyword(), atom(), atom()) :: keyword()
  def put_default_format(opts, key, format) do
    if Keyword.has_key?(opts, :format) do
      opts
    else
      Keyword.put_new(opts, key, format)
    end
  end

  @doc """
  Marks a request as idempotent, so `Dowser.Client.Retry` retries it after an
  *ambiguous* failure — a timeout, a dropped connection, a `502`/`504` — and
  not just after one that proves nothing was applied.

  `Dowser.Client` derives this from the HTTP method, which is right for a
  write but wrong for the many Elasticsearch reads that are `POST` requests
  because they carry a body: a search must stay retryable, a `_bulk` must not.
  Only the endpoint knows which it is, so each says so here.

  A `:retry` the caller set wins, including `retry: false`.
  """
  @spec put_idempotent(keyword(), boolean()) :: keyword()
  def put_idempotent(opts, idempotent?) do
    case Keyword.get(opts, :retry, []) do
      retry when is_list(retry) ->
        Keyword.put(opts, :retry, Keyword.put_new(retry, :idempotent, idempotent?))

      _disabled_or_invalid ->
        opts
    end
  end

  @doc """
  Appends a query-string parameter to `opts[:params]`, preserving any params
  the caller already set.
  """
  @spec put_param(keyword(), atom(), term()) :: keyword()
  def put_param(opts, key, value) do
    params = opts |> Keyword.get(:params, []) |> Enum.to_list()
    Keyword.put(opts, :params, params ++ [{key, value}])
  end
end
