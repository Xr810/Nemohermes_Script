# Offline / transfer package

1. On the build machine (this repo):

   ```bash
   ./scripts/package-image.sh
   ```

2. Send the `release/` folder (tar + compose + `.env.example`).

3. On the target:

   ```bash
   cd release
   docker load -i nemohermes-local.tar
   cp .env.example .env         # set INFERENCE_API_KEY
   docker compose up -d
   ```

The image carries no configuration and no secrets, so the tar is safe to copy
around; the inference key lives only in `.env` on the target and can be changed
without rebuilding or re-transferring anything.

The tar is the wrapper image only. On first `up`, the inner dockerd pulls the
Hermes/OpenShell sandbox images into the `nemohermes-docker` volume; they do
not need to be present on the host Docker store.
