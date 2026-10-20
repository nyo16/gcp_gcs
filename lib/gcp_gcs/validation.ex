defmodule GcpGcs.Validation do
  @moduledoc false
  # Input validation for GcpGcs. Returns {:ok, value} | {:error, %GcpGcs.Error{}}.

  alias GcpGcs.{Config, Error}

  # Bucket naming: 3-63 chars, lowercase letters/digits/hyphens/underscores/dots,
  # must start and end with a letter or digit. (Dotted "domain-named" buckets up
  # to 222 chars exist but are rare; we keep the common-case rule strict.)
  @bucket_regex ~r/^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$/
  @ip_regex ~r/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/

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
      not Regex.match?(@bucket_regex, bucket) ->
        {:error,
         Error.new(
           :validation_error,
           "bucket must be 3-63 chars: lowercase letters, digits, '-', '_', '.', " <>
             "starting and ending with a letter or digit"
         )}

      Regex.match?(@ip_regex, bucket) ->
        {:error, Error.new(:validation_error, "bucket must not be an IP address")}

      String.starts_with?(bucket, "goog") ->
        {:error,
         Error.new(:validation_error, "bucket must not begin with reserved prefix 'goog'")}

      String.contains?(bucket, "google") ->
        {:error, Error.new(:validation_error, "bucket must not contain 'google'")}

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

      String.contains?(object, ["\r", "\n"]) ->
        {:error,
         Error.new(:validation_error, "object name must not contain carriage return or line feed")}

      true ->
        {:ok, object}
    end
  end

  def validate_object(_) do
    {:error, Error.new(:validation_error, "object name must be a string")}
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
  # configured endpoint's upload API, never at an arbitrary host, so a
  # caller-supplied or server-returned URI can't redirect object bytes.
  @spec validate_session_uri(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_session_uri(uri) when is_binary(uri) do
    {scheme, host, port} = Config.endpoint()
    expected_scheme = Atom.to_string(scheme)

    case URI.new(uri) do
      {:ok, %URI{scheme: ^expected_scheme, host: ^host, port: ^port, userinfo: nil, path: path}}
      when is_binary(path) ->
        if String.starts_with?(path, "/upload/storage/v1/"),
          do: {:ok, uri},
          else: session_uri_error()

      _ ->
        session_uri_error()
    end
  end

  def validate_session_uri(_), do: session_uri_error()

  defp session_uri_error do
    {:error,
     Error.new(
       :validation_error,
       "session URI must be a resumable upload URI on the configured endpoint"
     )}
  end
end
