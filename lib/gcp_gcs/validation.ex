defmodule GcpGcs.Validation do
  @moduledoc false
  # Input validation for GcpGcs. Returns {:ok, value} | {:error, %GcpGcs.Error{}}.

  alias GcpGcs.Error

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
end
