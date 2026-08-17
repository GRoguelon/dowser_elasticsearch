defmodule Dowser.Elasticsearch.Helpers do
  @moduledoc false

  alias Dowser.Client.Response
  alias Dowser.Elasticsearch.Error
  alias Dowser.Elasticsearch.Index

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
  Like `path/2`, but for endpoints that require an index target; raises
  `ArgumentError` when the target is empty.
  """
  @spec required_path(Index.t(), String.t()) :: binary()
  def required_path(index, suffix) do
    case Index.segment(index) do
      nil ->
        raise ArgumentError, "this endpoint requires an index, got: #{inspect(index)}"

      segment ->
        "/" <> segment <> suffix
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
  Appends a query-string parameter to `opts[:params]`, preserving any params
  the caller already set.
  """
  @spec put_param(keyword(), atom(), term()) :: keyword()
  def put_param(opts, key, value) do
    params = opts |> Keyword.get(:params, []) |> Enum.to_list()
    Keyword.put(opts, :params, params ++ [{key, value}])
  end

  @doc """
  Merges `extra` into `opts[:codec_opts]` — supplying the context
  `Dowser.Elasticsearch.Codec` needs (e.g. `:index`) for an endpoint's
  request/response shape, without overwriting any key the caller already set
  there themselves.
  """
  @spec put_codec_opts(keyword(), keyword()) :: keyword()
  def put_codec_opts(opts, extra) do
    existing = Keyword.get(opts, :codec_opts, [])
    Keyword.put(opts, :codec_opts, Keyword.merge(extra, existing))
  end
end
