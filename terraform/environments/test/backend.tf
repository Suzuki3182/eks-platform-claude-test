terraform {
  required_version = ">= 1.6.0"

  backend "s3" {
    bucket         = "eks-platform-tfstate-test"
    key            = "environments/test/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    kms_key_id     = "alias/eks-platform-tfstate"
    dynamodb_table = "eks-platform-tfstate-lock"
  }
}
