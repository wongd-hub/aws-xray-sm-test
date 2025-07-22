variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "ecr_repo_name" {
  type    = string
  default = "xray-rocker-model"
}

variable "image_tag" {
  type    = string
  default = "latest"
}

# Note: S3 output path is now automatically created by the terraform
# The variable below is kept for compatibility but not used
variable "s3_output_path" {
  type        = string
  default     = ""
  description = "DEPRECATED: S3 bucket is now created automatically by Terraform"
}
