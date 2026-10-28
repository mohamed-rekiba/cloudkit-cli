<p align="center">
  <img src="assets/logo.svg" alt="CloudKit — CLI toolkit for AWS & Google Cloud" width="580">
</p>

<p align="center">
  <a href="https://github.com/shabayekdes/cloudkit-cli/actions/workflows/ci.yml"><img src="https://github.com/shabayekdes/cloudkit-cli/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/shabayekdes/cloudkit-cli/releases/latest"><img src="https://img.shields.io/github/v/release/shabayekdes/cloudkit-cli?label=release&color=2EA44F" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/shell-bash%20%7C%20zsh-4EAA25" alt="Shell: bash | zsh">
  <img src="https://img.shields.io/badge/clouds-AWS%20%7C%20Google%20Cloud-FF8A00" alt="Clouds: AWS | Google Cloud">
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey" alt="Platform: macOS | Linux">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License: MIT"></a>
  <a href="https://cloudkit-cli.pages.dev"><img src="https://img.shields.io/badge/docs-cloudkit--cli.pages.dev-F38020" alt="Docs"></a>
</p>

<p align="center">
  <b>One <code>ck</code> command for AWS and Google Cloud.</b><br>
  Pick a profile, log in, and jump into your instances — without remembering a single long CLI flag.
</p>

---

## What is CloudKit?

CloudKit is a set of shell helpers that wraps the AWS CLI and `gcloud` behind a single `ck` command:

- **Session management** — pick an AWS profile (SSO, access keys, chained roles) or a gcloud configuration from a list, log in if needed, and see account, region, identity and credential expiry in one table.
- **Per-terminal sessions** — each terminal has its own active profile/configuration, like `AWS_PROFILE`. Your prompt shows `[profile:region]` and `[gcloud:account:project]`, with a red `[PROD]` marker and banner for production.
- **Service shortcuts** — list, start, stop and connect to EC2 and GCE instances, exec into ECS tasks, forward ports through SSM or IAP, and manage instance groups. `ck ec2 session` and `ck gce ssh` offer an interactive picker when you leave out the instance.
- **Guided setup** — `ck setup` walks you through creating AWS profiles and gcloud configurations; `ck doctor` checks that everything is installed and configured.

Works in **bash** and **zsh** on **macOS** and **Linux**.

## Documentation

Installation, configuration, every command and troubleshooting are covered in the documentation at **[cloudkit-cli.pages.dev](https://cloudkit-cli.pages.dev)**. Start with [Getting started](https://cloudkit-cli.pages.dev/getting-started/).

## Contributing

Thank you for considering contributing to CloudKit! The contribution guide can be found in the [CloudKit documentation](https://cloudkit-cli.pages.dev/contributing/).

## Security Vulnerabilities

If you discover a security vulnerability within CloudKit, please send an e-mail to Esmail Shabayek via [esmail.shabayek@gmail.com](mailto:esmail.shabayek@gmail.com). All security vulnerabilities will be promptly addressed.

## License

CloudKit is open-sourced software licensed under the [MIT license](LICENSE).
