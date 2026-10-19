# Code signing policy

Application pending: this project is applying for free code signing provided by SignPath.io, certificate by SignPath Foundation. No sponsorship or public certificate has been granted yet.

Committers, reviewers and release approvers: g3 NetworX maintainers, GitHub account [g3networx](https://github.com/g3networx). Signing approval is manual. All signing participants must use multi-factor authentication on GitHub and SignPath before production signing is enabled.

Only artifacts built by the public `g3 Windows verified build` workflow from a reviewed commit are eligible. Customer credentials, enrollment invitations, private keys and customer logs must never enter the repository or signing artifacts. Existing local self-issued signatures do not establish public publisher trust.

This is an independently maintained AGPL-3.0 RustDesk fork. The code and dependency notices remain available. It is not an official RustDesk release.

## Privacy

The installed host contacts rust.g3nx.net for rendezvous, relay, authorized device enrollment, password provisioning, update checks and session accounting. These operations can transfer device identifiers, hostnames, assigned customer/address-book information, connection metadata and session duration. Authorized remote sessions can transfer screen contents, input, clipboard contents and files. Password provisioning and portal APIs use certificate-validated HTTPS. Credentials and client identity keys are not included in build artifacts.

The service operator is g3 NetworX UG & Co. KG, contact info@g3networx.de. Customers must authorize the software and its intended unattended-access settings. Third-party components and their licenses are documented in the source and installed notices. This policy does not claim that the program performs no network communication.
