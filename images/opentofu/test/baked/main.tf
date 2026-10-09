# A configuration using every provider baked into the image. `tofu validate` checks the provider
# schema, so the provider binary is actually started, not only unpacked.
terraform {
  required_providers {
    vault = {
      source = "hashicorp/vault"
    }
  }
}

# Never contacted: `tofu validate` does not configure the provider.
provider "vault" {
  address = "https://openbao.invalid:8200"
}

resource "vault_mount" "smoke" {
  path = "smoke"
  type = "kv"
  options = {
    version = "2"
  }
}
