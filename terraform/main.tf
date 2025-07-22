##################################
# 1) Provider & Backend
##################################
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

##################################
# 2) ECR Repository
##################################
resource "aws_ecr_repository" "model_repo" {
  name = var.ecr_repo_name
}

##################################
# 3) S3 Bucket for Async Outputs
##################################
# Random suffix to ensure bucket name uniqueness
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "async_output" {
  bucket = "${var.ecr_repo_name}-async-output-${random_id.bucket_suffix.hex}"
}

resource "aws_s3_bucket_versioning" "async_output" {
  bucket = aws_s3_bucket.async_output.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "async_output" {
  bucket = aws_s3_bucket.async_output.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "async_output" {
  bucket = aws_s3_bucket.async_output.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

##################################
# 4) IAM Role for SageMaker
##################################
data "aws_iam_policy_document" "sagemaker_assume" {
  statement {
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sagemaker_exec" {
  name               = "${var.ecr_repo_name}-exec-role"
  assume_role_policy = data.aws_iam_policy_document.sagemaker_assume.json
}

# Attach X-Ray permissions
resource "aws_iam_policy" "xray_policy" {
  name = "${var.ecr_repo_name}-xray"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["xray:PutTraceSegments","xray:PutTelemetryRecords"]
      Resource = ["*"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sagemaker_xray_attach" {
  role       = aws_iam_role.sagemaker_exec.name
  policy_arn = aws_iam_policy.xray_policy.arn
}

# Attach S3 permissions for async inference outputs
resource "aws_iam_policy" "s3_policy" {
  name = "${var.ecr_repo_name}-s3"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.async_output.arn,
        "${aws_s3_bucket.async_output.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sagemaker_s3_attach" {
  role       = aws_iam_role.sagemaker_exec.name
  policy_arn = aws_iam_policy.s3_policy.arn
}

# Attach ECR permissions for SageMaker to pull Docker images
resource "aws_iam_policy" "ecr_policy" {
  name = "${var.ecr_repo_name}-ecr"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability", 
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ]
      Resource = ["*"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sagemaker_ecr_attach" {
  role       = aws_iam_role.sagemaker_exec.name
  policy_arn = aws_iam_policy.ecr_policy.arn
}

# Attach CloudWatch Logs permissions for SageMaker container logging
resource "aws_iam_policy" "cloudwatch_logs_policy" {
  name = "${var.ecr_repo_name}-cloudwatch-logs"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream", 
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = [
        "arn:aws:logs:${var.aws_region}:*:log-group:/aws/sagemaker/*",
        "arn:aws:logs:${var.aws_region}:*:log-group:/aws/sagemaker/*:*"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sagemaker_cloudwatch_attach" {
  role       = aws_iam_role.sagemaker_exec.name
  policy_arn = aws_iam_policy.cloudwatch_logs_policy.arn
}

##################################
# 5) SageMaker Model & Endpoint
##################################
resource "aws_sagemaker_model" "model" {
  name                 = var.ecr_repo_name
  execution_role_arn   = aws_iam_role.sagemaker_exec.arn
  primary_container {
    image = "${aws_ecr_repository.model_repo.repository_url}:${var.image_tag}"
  }
}

resource "aws_sagemaker_endpoint_configuration" "async_cfg" {
  name = "${var.ecr_repo_name}-async-cfg"

  production_variants {
    variant_name           = "AllTraffic"
    model_name             = aws_sagemaker_model.model.name
    initial_instance_count = 1
    instance_type          = "ml.m5.large"
  }

  async_inference_config {
    client_config {
      max_concurrent_invocations_per_instance = 4
    }
    output_config { 
      s3_output_path = "s3://${aws_s3_bucket.async_output.bucket}/async-output/" 
    }
  }
}

resource "aws_sagemaker_endpoint" "async_endpoint" {
  name                 = "${var.ecr_repo_name}-async-endpoint"
  endpoint_config_name = aws_sagemaker_endpoint_configuration.async_cfg.name
}

##################################
# 6) Outputs
##################################
output "ecr_repository_url" {
  description = "URL of the ECR repository"
  value       = aws_ecr_repository.model_repo.repository_url
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket for async inference outputs"
  value       = aws_s3_bucket.async_output.bucket
}

output "s3_output_path" {
  description = "S3 path for async inference outputs"
  value       = "s3://${aws_s3_bucket.async_output.bucket}/async-output/"
}

output "sagemaker_endpoint_name" {
  description = "Name of the SageMaker endpoint"
  value       = aws_sagemaker_endpoint.async_endpoint.name
}

output "sagemaker_endpoint_url" {
  description = "URL of the SageMaker endpoint"
  value       = "https://runtime.sagemaker.${var.aws_region}.amazonaws.com/endpoints/${aws_sagemaker_endpoint.async_endpoint.name}/async-invocations"
}
