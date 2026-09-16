# Contributing

Thanks for wanting to improve the plugin. The project is young and maintained by one
person, so the surface is deliberately small.

## Before opening a PR

1. Run the test suite — it is fully offline:

   ```bash
   ./test.sh
   ```

   All checks must pass (skips count as not-run: shellcheck, python3, and jq gaps are
   environment artifacts — but a skip caused by your change is a failure).
2. `claude plugin validate .` should pass.
3. Keep scripts bash-3.2-compatible (no `mapfile`, `declare -A`, `|&`): stock macOS
   bash must keep working.
4. Every behavior change ships with a test. The suite is the project's spec — checks
   are added, not edited to fit.
5. One topic per PR; keep the diff focused.

## Scope notes

- The quota endpoint is an internal Z.AI API and can change without notice; fetcher
  changes must keep the response-shape validation strict.
- Security-relevant behavior (token handling, file permissions, output redaction) is
  pinned by tests — changes here need an explicit justification in the PR description.

## License

By contributing, you agree that your contributions are licensed under the project's
[MIT License](LICENSE) (© Artur Galstyan (Galart)).
