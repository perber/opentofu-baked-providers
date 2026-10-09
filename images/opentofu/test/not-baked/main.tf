# A provider the image does NOT bake in. `tofu init` has to fail on it: the image allows no
# installation source other than its mirror, so it must never be downloaded.
terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
    }
  }
}
