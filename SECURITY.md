# Security

This repository mirrors installer files and publishes checksums. Treat this as a supply-chain-sensitive project.

## Recommended Practices

- Keep GitHub Actions workflow permissions to the minimum needed for release publishing.
- Use SHA256 verification before any local install or unpack operation.
- Do not modify, repackage, crack, or patch upstream installers.
- Keep release manifests and checksum files public.
- Review workflow logs when a new version is published.

## Reporting Issues

Open a GitHub issue if:

- a checksum does not match;
- a release asset is missing;
- a manifest reports the wrong package identity or architecture;
- the user updater removes files it should preserve.
