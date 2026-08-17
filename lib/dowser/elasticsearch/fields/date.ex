defmodule Dowser.Elasticsearch.Fields.Date do
  @moduledoc """
  `date` — ISO-8601 strings or epoch millis <-> `DateTime`.

  A mapping entry with no `"format"` is treated as Elasticsearch's own
  default, `strict_date_optional_time||epoch_millis`. Custom Java date
  `format`s aren't parsed; unrecognized strings pass through untouched (cast
  your own field over these types to handle them).
  """

  ## Behaviours

  @behaviour Dowser.Client.Field

  ## Module attributes

  @date_formats ~w[strict_date strict_year_month_day yyyy-MM-dd strict_date_optional_time strict_date_optional_time_nanos]

  @date_time_second_formats ~w[strict_date_time_no_millis yyyy-MM-dd'T'HH:mm:ssZ]

  @date_time_millisecond_formats ~w[strict_date_optional_time strict_date_time yyyy-MM-dd'T'HH:mm:ss.SSSZ]

  @date_time_microsecond_formats ~w[strict_date_optional_time_nanos yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ]

  @default_format ~w[strict_date_optional_time epoch_millis]

  ## Public functions

  @impl Dowser.Client.Field
  def load(value, field)
      when not is_map_key(field, "format") and not is_map_key(field, "formats") do
    field = Map.put(field, "formats", @default_format)

    load(value, field)
  end

  def load(value, %{"format" => format} = field) when not is_map_key(field, "formats") do
    formats = String.split(format, "||")
    field = Map.put(field, "formats", formats)

    load(value, field)
  end

  def load(value, %{"formats" => formats}) do
    Enum.find_value(formats, value, &do_load(value, &1))
  end

  @impl Dowser.Client.Field
  def dump(value, field)
      when not is_map_key(field, "format") and not is_map_key(field, "formats") do
    field = Map.put(field, "formats", @default_format)

    dump(value, field)
  end

  def dump(value, %{"format" => format} = field) when not is_map_key(field, "formats") do
    formats = String.split(format, "||")
    field = Map.put(field, "formats", formats)

    dump(value, field)
  end

  def dump(value, %{"formats" => [format | _]}) do
    do_dump(value, format)
  end

  ## Private functions

  defp do_load(value, "epoch_millis") when is_integer(value) do
    DateTime.from_unix!(value, :millisecond)
  end

  defp do_load(value, "epoch_second") when is_integer(value) do
    DateTime.from_unix!(value, :second)
  end

  for format <- @date_formats do
    defp do_load(
           <<_::binary-size(4), "-", _::binary-size(2), "-", _::binary-size(2)>> = value,
           unquote(format)
         ) do
      case Date.from_iso8601(value) do
        {:ok, date} ->
          date

        _ ->
          nil
      end
    end
  end

  for format <- @date_time_second_formats do
    defp do_load(
           <<_::binary-size(4), "-", _::binary-size(2), "-", _::binary-size(2), "T",
             _::binary-size(2), ":", _::binary-size(2), ":", _::binary-size(2), "Z">> = value,
           unquote(format)
         ) do
      case DateTime.from_iso8601(value) do
        {:ok, date_time, 0} ->
          date_time

        _ ->
          nil
      end
    end
  end

  for format <- @date_time_millisecond_formats do
    defp do_load(
           <<_::binary-size(4), "-", _::binary-size(2), "-", _::binary-size(2), "T",
             _::binary-size(2), ":", _::binary-size(2), ":", _::binary-size(2), ".",
             _::binary-size(3), "Z">> = value,
           unquote(format)
         ) do
      case DateTime.from_iso8601(value) do
        {:ok, date_time, 0} ->
          date_time

        _ ->
          nil
      end
    end
  end

  for format <- @date_time_microsecond_formats do
    defp do_load(
           <<_::binary-size(4), "-", _::binary-size(2), "-", _::binary-size(2), "T",
             _::binary-size(2), ":", _::binary-size(2), ":", _::binary-size(2), ".",
             _::binary-size(6), "Z">> = value,
           unquote(format)
         ) do
      case DateTime.from_iso8601(value) do
        {:ok, date_time, 0} ->
          date_time

        _ ->
          nil
      end
    end
  end

  defp do_load(_value, _format), do: nil

  defp do_dump(%NaiveDateTime{} = naive_date_time, format) do
    naive_date_time
    |> DateTime.from_naive!("Etc/UTC")
    |> do_dump(format)
  end

  defp do_dump(%DateTime{} = date_time, "epoch_millis") do
    DateTime.to_unix(date_time, :millisecond)
  end

  defp do_dump(%DateTime{} = date_time, "epoch_second") do
    DateTime.to_unix(date_time, :second)
  end

  for format <- @date_formats do
    defp do_dump(%Date{} = date, unquote(format)) do
      Date.to_iso8601(date)
    end
  end

  for format <- @date_time_second_formats do
    defp do_dump(%DateTime{} = date_time, unquote(format)) do
      date_time |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    end
  end

  for format <- @date_time_millisecond_formats do
    defp do_dump(%DateTime{} = date_time, unquote(format)) do
      date_time |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    end
  end

  for format <- @date_time_microsecond_formats do
    defp do_dump(%DateTime{} = date_time, unquote(format)) do
      date_time |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    end
  end

  defp do_dump(value, _format), do: value
end
