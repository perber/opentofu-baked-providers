# The providers baked into the image, and nothing else: every entry here is downloaded, checked and
# copied into the image's filesystem mirror at build time, and the CLI configuration in `tofurc`
# allows no other installation source at run time.
#
# Exact versions only. A range would let the mirror pick whatever is newest on the day of the
# build, and `.terraform.lock.hcl` next to this file pins the checksums of exactly these releases.
#
# Sources name the registry host explicitly. OpenTofu and Dependabot's `opentofu` ecosystem resolve a
# bare `hashicorp/vault` to registry.opentofu.org anyway; spelled out, the address is the same for
# every tool that reads this file - including ones that would default to registry.terraform.io.
#
# The image version follows these versions - see `scripts/next-version.sh`.
#
# To bake in another provider, add it here, then regenerate the lock file - see the README.
terraform {
  required_providers {
    # Also the provider for OpenBao, which speaks the Vault API.
    vault = {
      source  = "registry.opentofu.org/hashicorp/vault"
      version = "5.12.0"
    }
  }
}
