variable "lambda_image_uri" {
  type        = string
  description = "Image uri for the lambda which will process logs and filter based on requirement"
}

variable "s3_bucket_name" {
  type        = string
  description = "Name of the s3 bucket which holds the DAS firehose logs"
}

variable "stream_names" {
    type = list(string)
    description = "List of stream names to create the processor"
}

variable "stream_filters" {
  type = map(object({
    # Name of the stream on which filter has to apply
    stream_name = string
    # Region of the KMS key located in used for database activity stream
    kms_region = string
  }))
}