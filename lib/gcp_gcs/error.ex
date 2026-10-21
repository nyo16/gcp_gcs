defmodule GcpGcs.Error do
  @moduledoc """
  Structured error type for `GcpGcs` operations.

  Every error returned by the library is wrapped in this struct, giving
  consistent handling across authentication, validation, transport, and
  Google Cloud Storage API errors. It is also an exception: the only raising
  functions, `GcpGcs.stream_objects!/2` and `GcpGcs.stream_buckets!/2`,
  raise it.

  ## Fields

  - `code` — an atom categorizing the error (e.g. `:not_found`, `:validation_error`)
  - `message` — a human-readable description
  - `details` — the original error term (decoded JSON body, exception, etc.)
  - `status` — the integer HTTP status code when applicable, `nil` otherwise

  ## Examples

      case GcpGcs.get_object("my-bucket", "missing.txt") do
        {:ok, object} -> object
        {:error, %GcpGcs.Error{code: :not_found}} -> "no such object"
        {:error, %GcpGcs.Error{code: :unauthenticated}} -> "auth failed"
        {:error, %GcpGcs.Error{} = err} -> "Error: \#{err}"
      end
  """

  @typedoc """
  Every error code the library returns.

  HTTP statuses (aligned with Google's `google.rpc.Code` names):
  `:invalid_argument` (400), `:unauthenticated` (401), `:permission_denied`
  (403), `:not_found` (404), `:method_not_allowed` (405), `:deadline_exceeded`
  (408, 504), `:already_exists` (409), `:failed_precondition` (412),
  `:out_of_range` (413, 416), `:resource_exhausted` (429), `:cancelled` (499),
  `:internal` (500), `:unimplemented` (501), `:unavailable` (502, 503), and
  `:unknown` for any other status.

  Client-side:

    * `:validation_error` — invalid input or options; no request was made
    * `:connection_error` — transport failure (refused, closed, timed out)
    * `:resource_exhausted` — also: no pooled connection within `:pool_timeout`
    * `:unauthenticated` — also: no usable credentials
    * `:protocol_error` — the server's response broke the resumable-upload or
      rewrite protocol (e.g. no `Location`, a malformed `Range`, no progress)
    * `:data_loss` — a resumable session lost bytes a stream can no longer resend
    * `:io_error` — a local file could not be read or written
  """
  @type code ::
          :invalid_argument
          | :unauthenticated
          | :permission_denied
          | :not_found
          | :method_not_allowed
          | :deadline_exceeded
          | :already_exists
          | :failed_precondition
          | :out_of_range
          | :resource_exhausted
          | :cancelled
          | :internal
          | :unimplemented
          | :unavailable
          | :unknown
          | :validation_error
          | :connection_error
          | :protocol_error
          | :data_loss
          | :io_error

  @type t :: %__MODULE__{
          code: code(),
          message: String.t(),
          details: term(),
          status: non_neg_integer() | nil
        }

  @derive {Inspect, only: [:code, :message, :status]}
  defexception [:code, :message, :details, :status]

  # HTTP status -> canonical code (aligned with Google's google.rpc.Code names).
  @status_codes %{
    400 => :invalid_argument,
    401 => :unauthenticated,
    403 => :permission_denied,
    404 => :not_found,
    405 => :method_not_allowed,
    408 => :deadline_exceeded,
    409 => :already_exists,
    412 => :failed_precondition,
    413 => :out_of_range,
    416 => :out_of_range,
    429 => :resource_exhausted,
    499 => :cancelled,
    500 => :internal,
    501 => :unimplemented,
    502 => :unavailable,
    503 => :unavailable,
    504 => :deadline_exceeded
  }

  @doc """
  Builds an error from an HTTP response.

  Maps the status code to a descriptive atom and extracts the message from a
  decoded GCS JSON error body (`%{"error" => %{"message" => ...}}`) when present.
  """
  @spec from_response(non_neg_integer(), term()) :: t()
  def from_response(status, body) when is_integer(status) do
    %__MODULE__{
      code: code_for_status(status),
      message: extract_message(body) || "HTTP #{status}",
      details: body,
      status: status
    }
  end

  @doc """
  Creates a new error with the given code and message.
  """
  @spec new(code(), String.t(), term()) :: t()
  def new(code, message, details \\ nil) do
    %__MODULE__{code: code, message: message, details: details}
  end

  @doc """
  Maps a transport-level reason (Finch/Mint error) to an error struct.

  An invalid request header value is reported by header name only: the value
  (and the wrapped Mint error that carries it) may be a bearer token.
  """
  @spec from_transport(term()) :: t()
  def from_transport(%{__struct__: mod, reason: {:invalid_header_value, name, _value}})
      when mod in [Finch.HTTPError, Mint.HTTPError] do
    new(:connection_error, "invalid value for header #{name}", {:invalid_header_value, name})
  end

  def from_transport(%{__exception__: true} = exception) do
    new(:connection_error, Exception.message(exception), exception)
  end

  def from_transport(reason) do
    new(:connection_error, "connection error", reason)
  end

  @doc false
  @spec code_for_status(non_neg_integer()) :: code()
  def code_for_status(status), do: Map.get(@status_codes, status, :unknown)

  defp extract_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp extract_message(%{"error" => message}) when is_binary(message), do: message
  defp extract_message(_), do: nil

  defimpl String.Chars do
    def to_string(%GcpGcs.Error{code: code, message: message, status: nil}) do
      "[#{code}] #{message}"
    end

    def to_string(%GcpGcs.Error{code: code, message: message, status: status}) do
      "[#{code} (HTTP #{status})] #{message}"
    end
  end
end
