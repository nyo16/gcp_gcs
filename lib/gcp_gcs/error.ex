defmodule GcpGcs.Error do
  @moduledoc """
  Structured error type for `GcpGcs` operations.

  Every error returned by the library is wrapped in this struct, giving
  consistent handling across authentication, validation, transport, and
  Google Cloud Storage API errors.

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

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          details: term(),
          status: non_neg_integer() | nil
        }

  @derive {Inspect, only: [:code, :message, :status]}
  defstruct [:code, :message, :details, :status]

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
  @spec new(atom(), String.t(), term()) :: t()
  def new(code, message, details \\ nil) do
    %__MODULE__{code: code, message: message, details: details}
  end

  @doc """
  Maps a transport-level reason (Finch/Mint error) to an error struct.
  """
  @spec from_transport(term()) :: t()
  def from_transport(%{__exception__: true} = exception) do
    new(:connection_error, Exception.message(exception), exception)
  end

  def from_transport(reason) do
    new(:connection_error, "connection error", reason)
  end

  @doc false
  @spec code_for_status(non_neg_integer()) :: atom()
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
