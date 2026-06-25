import Config

# To develop against a local GCS emulator (e.g. fsouza/fake-gcs-server),
# uncomment and adjust:
#
#     config :gcp_gcs, :emulator,
#       scheme: "http",
#       host: "localhost",
#       port: 4443
#
# Otherwise the library talks to production storage.googleapis.com and uses
# your ambient credentials (gcloud CLI, GOOGLE_APPLICATION_CREDENTIALS, or Goth).
