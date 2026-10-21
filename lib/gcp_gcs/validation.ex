defmodule GcpGcs.Validation do
  @moduledoc false
  # Input validation for GcpGcs. Returns {:ok, value} | {:error, %GcpGcs.Error{}}.

  alias GcpGcs.Error

  # Bucket naming: 3-63 chars, lowercase letters/digits/hyphens/underscores/dots,
  # must start and end with a letter or digit. (Dotted "domain-named" buckets up
  # to 222 chars exist but are rare; we keep the common-case rule strict.)
  #
  # These checks run on every request: they use binary matching, not regexes.
  defguardp lower_alnum?(c) when c in ?a..?z or c in ?0..?9
  defguardp digit?(c) when c in ?0..?9

  @max_object_bytes 1024

  @spec validate_project_id(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_project_id(project_id)
      when is_binary(project_id) and byte_size(project_id) > 0 do
    {:ok, project_id}
  end

  def validate_project_id(_) do
    {:error, Error.new(:validation_error, "project_id must be a non-empty string")}
  end

  @spec validate_bucket(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_bucket(bucket) when is_binary(bucket) do
    cond do
      not bucket_name?(bucket) ->
        {:error,
         Error.new(
           :validation_error,
           "bucket must be 3-63 chars: lowercase letters, digits, '-', '_', '.', " <>
             "starting and ending with a letter or digit"
         )}

      ip_address?(bucket) ->
        {:error, Error.new(:validation_error, "bucket must not be an IP address")}

      String.starts_with?(bucket, "goog") ->
        {:error,
         Error.new(:validation_error, "bucket must not begin with reserved prefix 'goog'")}

      String.contains?(bucket, "google") ->
        {:error, Error.new(:validation_error, "bucket must not contain 'google'")}

      String.contains?(bucket, ["..", ".-", "-."]) ->
        {:error,
         Error.new(:validation_error, "bucket must not contain '..', '.-' or '-.' sequences")}

      true ->
        {:ok, bucket}
    end
  end

  def validate_bucket(_) do
    {:error, Error.new(:validation_error, "bucket must be a string")}
  end

  @spec validate_object(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_object(object) when is_binary(object) do
    cond do
      byte_size(object) == 0 ->
        {:error, Error.new(:validation_error, "object name must not be empty")}

      byte_size(object) > @max_object_bytes ->
        {:error,
         Error.new(:validation_error, "object name must be at most #{@max_object_bytes} bytes")}

      object in [".", ".."] ->
        {:error, Error.new(:validation_error, "object name must not be '.' or '..'")}

      not String.valid?(object) ->
        {:error, Error.new(:validation_error, "object name must be valid UTF-8")}

      control_char?(object) ->
        {:error, Error.new(:validation_error, "object name must not contain control characters")}

      true ->
        {:ok, object}
    end
  end

  def validate_object(_) do
    {:error, Error.new(:validation_error, "object name must be a string")}
  end

  @spec validate_opts(term(), [atom()]) :: {:ok, keyword()} | {:error, Error.t()}
  def validate_opts(opts, allowed) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, _} <- Keyword.validate(opts, allowed) do
      {:ok, opts}
    else
      false ->
        {:error, Error.new(:validation_error, "options must be a keyword list")}

      {:error, unknown} ->
        {:error,
         Error.new(
           :validation_error,
           "unknown options #{inspect(unknown)}; allowed: #{inspect(Enum.sort(allowed))}",
           {:unknown_options, unknown}
         )}
    end
  end

  def validate_opts(_opts, _allowed) do
    {:error, Error.new(:validation_error, "options must be a keyword list")}
  end

  # Values that end up in request headers (`:origin`, `:content_type`): visible
  # ASCII and spaces only, so a CR/LF can't split headers and the request fails
  # here rather than as a Mint :connection_error.
  @spec validate_header_value(term(), String.t()) :: {:ok, term()} | {:error, Error.t()}
  def validate_header_value(nil, _field), do: {:ok, nil}

  def validate_header_value(value, field) when is_binary(value) do
    if value != "" and printable_ascii?(value),
      do: {:ok, value},
      else: header_value_error(field)
  end

  def validate_header_value(_value, field), do: header_value_error(field)

  defp header_value_error(field) do
    {:error,
     Error.new(:validation_error, "#{field} must be a non-empty string of printable ASCII")}
  end

  defp bucket_name?(<<first, rest::binary>> = name)
       when byte_size(name) in 3..63 and lower_alnum?(first),
       do: bucket_tail?(rest)

  defp bucket_name?(_name), do: false

  defp bucket_tail?(<<last>>) when lower_alnum?(last), do: true

  defp bucket_tail?(<<c, rest::binary>>) when lower_alnum?(c) or c in [?., ?_, ?-],
    do: bucket_tail?(rest)

  defp bucket_tail?(_rest), do: false

  # Four dot-separated groups of 1-3 digits.
  defp ip_address?(name) do
    case :binary.split(name, ".", [:global]) do
      [_, _, _, _] = groups -> Enum.all?(groups, &(byte_size(&1) in 1..3 and digits?(&1)))
      _ -> false
    end
  end

  @doc false
  # Non-empty and ASCII digits only.
  @spec digits?(binary()) :: boolean()
  def digits?(<<c>>) when digit?(c), do: true
  def digits?(<<c, rest::binary>>) when digit?(c), do: digits?(rest)
  def digits?(_), do: false

  defp control_char?(<<c, _::binary>>) when c < 0x20, do: true
  defp control_char?(<<_, rest::binary>>), do: control_char?(rest)
  defp control_char?(<<>>), do: false

  defp printable_ascii?(<<c, rest::binary>>) when c in 0x20..0x7E, do: printable_ascii?(rest)
  defp printable_ascii?(<<>>), do: true
  defp printable_ascii?(_), do: false

  @doc "Validates a bucket/object pair."
  @spec validate_location(term(), term()) :: {:ok, {String.t(), String.t()}} | {:error, Error.t()}
  def validate_location(bucket, object) do
    with {:ok, _} <- validate_bucket(bucket),
         {:ok, _} <- validate_object(object) do
      {:ok, {bucket, object}}
    end
  end

  @spec validate_binary(term(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def validate_binary(data, _field) when is_binary(data), do: {:ok, data}

  def validate_binary(_, field) do
    {:error, Error.new(:validation_error, "#{field} must be a binary")}
  end

  @spec validate_enumerable(term(), String.t()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def validate_enumerable(value, field) do
    if Enumerable.impl_for(value) do
      {:ok, value}
    else
      {:error,
       Error.new(:validation_error, "#{field} must be a binary, {:file, path} or an Enumerable")}
    end
  end

  @spec validate_non_neg_integer(term(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def validate_non_neg_integer(value, _field) when is_integer(value) and value >= 0,
    do: {:ok, value}

  def validate_non_neg_integer(_, field) do
    {:error, Error.new(:validation_error, "#{field} must be a non-negative integer")}
  end

  @spec validate_optional_non_neg_integer(term(), String.t()) ::
          {:ok, non_neg_integer() | nil} | {:error, Error.t()}
  def validate_optional_non_neg_integer(nil, _field), do: {:ok, nil}
  def validate_optional_non_neg_integer(value, field), do: validate_non_neg_integer(value, field)

  @spec validate_map(term(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def validate_map(value, _field) when is_map(value), do: {:ok, value}

  def validate_map(_, field) do
    {:error, Error.new(:validation_error, "#{field} must be a map")}
  end

  @spec validate_reducer(term()) :: {:ok, (term(), term() -> term())} | {:error, Error.t()}
  def validate_reducer(fun) when is_function(fun, 2), do: {:ok, fun}

  def validate_reducer(_) do
    {:error, Error.new(:validation_error, "reducer must be a function of arity 2")}
  end

  @spec validate_source_objects(term()) :: {:ok, [map()]} | {:error, Error.t()}
  def validate_source_objects([_ | _] = sources) do
    if Enum.all?(sources, &valid_source?/1) do
      {:ok, sources}
    else
      {:error,
       Error.new(
         :validation_error,
         "each source object must be a string name or a map with a :name (string) key"
       )}
    end
  end

  def validate_source_objects(_) do
    {:error, Error.new(:validation_error, "source objects must be a non-empty list")}
  end

  defp valid_source?(name) when is_binary(name) and byte_size(name) > 0, do: true
  defp valid_source?(%{name: name}) when is_binary(name) and byte_size(name) > 0, do: true
  defp valid_source?(%{"name" => name}) when is_binary(name) and byte_size(name) > 0, do: true
  defp valid_source?(_), do: false

  # A resumable session URI is a bearer capability: it must point at the
  # upload API of the endpoint in use (`base_url`, e.g. the configured one),
  # never at an arbitrary host, so a caller-supplied or server-returned URI
  # can't redirect object bytes.
  @spec validate_session_uri(term(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_session_uri(uri, base_url) when is_binary(uri) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(base_url)

    case URI.new(uri) do
      {:ok, %URI{scheme: ^scheme, host: ^host, port: ^port, userinfo: nil, path: path}}
      when is_binary(path) ->
        if String.starts_with?(path, "/upload/storage/v1/"),
          do: {:ok, uri},
          else: session_uri_error()

      _ ->
        session_uri_error()
    end
  end

  def validate_session_uri(_uri, _base_url), do: session_uri_error()

  defp session_uri_error do
    {:error,
     Error.new(
       :validation_error,
       "session URI must be a resumable upload URI on the configured endpoint"
     )}
  end
end
