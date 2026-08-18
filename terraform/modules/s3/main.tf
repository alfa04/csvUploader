resource "aws_s3_bucket" "raw_uploads" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_ownership_controls" "raw_uploads" {
  bucket = aws_s3_bucket.raw_uploads.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "raw_uploads" {
  bucket = aws_s3_bucket.raw_uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw_uploads" {
  bucket = aws_s3_bucket.raw_uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning is deliberately off: each upload gets its own fresh key (raw/{upload_id}.csv), so
# there's nothing to version - it would only add storage cost.

resource "aws_s3_bucket_lifecycle_configuration" "raw_uploads" {
  bucket = aws_s3_bucket.raw_uploads.id

  rule {
    id     = "expire-raw-uploads"
    status = "Enabled"

    filter {} # applies to every object in the bucket

    expiration {
      days = var.expiration_days
    }
  }
}

# Access control is granted via each Lambda's own least-privilege IAM role policy
# (identity-based), not a bucket policy naming those roles as principals - doing it here would
# make this module depend on the IAM module's outputs while the IAM module's inline policies
# depend on this module's bucket ARN, a circular dependency. This bucket policy is limited to
# a blanket security rule that doesn't need to know about specific principals.
data "aws_iam_policy_document" "deny_insecure_transport" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.raw_uploads.arn, "${aws_s3_bucket.raw_uploads.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "raw_uploads" {
  bucket = aws_s3_bucket.raw_uploads.id
  policy = data.aws_iam_policy_document.deny_insecure_transport.json
}
