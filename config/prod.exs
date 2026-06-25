import Config

# No configuration required for production. The library talks to
# https://storage.googleapis.com and authenticates using one of:
#
#   1. Goth          — config :gcp_gcs, :goth, MyApp.Goth
#   2. gcloud CLI    — `gcloud auth application-default login` (auto-detected)
#   3. Service file  — GOOGLE_APPLICATION_CREDENTIALS env var (via Goth)
#
# Tune the Finch connection pool if needed:
#
#     config :gcp_gcs, :finch,
#       pool_size: 50,
#       pool_count: 1
