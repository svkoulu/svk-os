# School CA certificates

Drop any internal / school root CA certificates here as `*.crt` (PEM, one cert
per file). `build.base.sh` runs `update-ca-trust` during the image build, which
folds them into the system trust store so every fleet machine trusts them.

This file is only a placeholder so the directory exists in git — it is ignored
by `update-ca-trust` (not a `.crt`). Delete it once you add a real cert if you
like.
