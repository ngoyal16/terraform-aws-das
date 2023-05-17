locals {
  enabled = module.this.enabled

  sns_topic_names = [for stream_name in var.stream_names : join(module.this.delimiter, [module.this.id, stream_name])]
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "s3_event_publish_access" {
  for_each = toset(module.this.enabled ? local.sns_topic_names : [])

  statement {
    sid = "Allow s3 to publish on respective sns topic"
    effect = "Allow"

    principals {
      type = "Service"

      identifiers = [
        "s3.amazonaws.com"
      ]
    }

    actions = [
      "SNS:Publish",
    ]

    resources = [
      "arn:aws:sns:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${each.value}"
    ]

    condition {
      test = "StringLike"
      variable = "aws:sourceArn"
      values = [
        "arn:aws:s3:::${var.s3_bucket_name}"
      ]
    }
  }
}

data "aws_iam_policy_document" "resource_sqs_publish_access" {
  for_each = local.enabled ? var.stream_filters : {}

  statement {
    sid = "Allow SNS to publish on respective sqs topic"
    effect = "Allow"

    principals {
      type = "Service"

      identifiers = [
        "sns.amazonaws.com"
      ]
    }

    actions = [
      "sqs:SendMessage",
    ]

    resources = [
      aws_sqs_queue.this[each.key].arn
    ]

    condition {
      test = "ArnEquals"
      variable = "aws:sourceArn"
      values = [
        aws_sns_topic.this[join(module.this.delimiter, [module.this.id, var.stream_filters[each.key].stream_name])].arn
      ]
    }
  }
}

resource "aws_sns_topic" "this" {
  for_each = toset(module.this.enabled ? local.sns_topic_names : [])

  name = each.value
  display_name = replace(each.value, ".", "-") # dots are illegal in display names and for .fifo topics required as part of the name (AWS SNS by design)
  policy = data.aws_iam_policy_document.s3_event_publish_access[each.value].json
  tags = merge(module.this.tags, {
    Name = each.value
  })
}

resource "aws_s3_bucket_notification" "this" {
  bucket = var.s3_bucket_name

  dynamic topic {
    for_each = toset(module.this.enabled ? local.sns_topic_names : [])

    content {
      topic_arn     = aws_sns_topic.this[topic.value].arn
      events        = [
        "s3:ObjectCreated:*"
      ]
      filter_prefix = join("/", ["firehose", replace(topic.value, join(module.this.delimiter, [module.this.id, ""]), ""), ""])
    }
  }
}

resource "aws_sqs_queue" "this" {
  for_each = local.enabled ? var.stream_filters : {}

  name = join(module.this.delimiter, [module.this.id, each.key])
  message_retention_seconds = 604800  // 7 days
  visibility_timeout_seconds = 1200   // 20 minutes

  tags = merge(module.this.tags, {
    Name = each.key
  })
}


resource "aws_sqs_queue_policy" "this" {
  for_each = local.enabled ? var.stream_filters : {}

  queue_url  = aws_sqs_queue.this[each.key].id
  policy = data.aws_iam_policy_document.resource_sqs_publish_access[each.key].json
}

resource "aws_sns_topic_subscription" "this" {
  for_each = local.enabled ? var.stream_filters : {}

  topic_arn              = aws_sns_topic.this[join(module.this.delimiter, [module.this.id, var.stream_filters[each.key].stream_name])].arn
  protocol               = "sqs"
  endpoint               = aws_sqs_queue.this[each.key].arn
  raw_message_delivery   = true
}


data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type = "Service"

      identifiers = [
        "lambda.amazonaws.com"
      ]
    }

    actions = [
      "sts:AssumeRole",
    ]
  }
}

data "aws_iam_policy_document" "lamdba_kms_permission" {
  for_each = local.enabled ? var.stream_filters : {}

  statement {
    effect = "Allow"

    actions = [
      "kms:Decrypt",
    ]

    resources = [
      "arn:aws:kms:${data.aws_region.current.name}:*:key/*",
    ]
  }
}

data "aws_iam_policy_document" "lamdba_s3_permission" {
  for_each = local.enabled ? var.stream_filters : {}

  statement {
    effect = "Allow"

    actions = [
      "s3:GetObject",
    ]

    resources = [
      "arn:aws:s3:::${var.s3_bucket_name}/firehose/${var.stream_filters[each.key].stream_name}/*",
    ]
  }

  statement {
    effect = "Allow"

    actions = [
      "s3:PutObject",
    ]

    resources = [
      "arn:aws:s3:::${var.s3_bucket_name}/das/${each.key}/*",
    ]
  }
}

data "aws_iam_policy_document" "lamdba_sqs_permission" {
  for_each = local.enabled ? var.stream_filters : {}

  statement {
    effect = "Allow"

    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage",
    ]

    resources = [
      "arn:aws:sqs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${join(module.this.delimiter, [module.this.id, each.key])}",
    ]
  }
}

resource "aws_iam_role" "iam_role_for_lamdba" {
  for_each = local.enabled ? var.stream_filters : {}

  name = join(module.this.delimiter, ["DASProcessorRoleForLambda", module.this.id, each.key])

  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  managed_policy_arns   = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
  ]

  inline_policy {
    name = "KMS"
    policy = data.aws_iam_policy_document.lamdba_kms_permission[each.key].json
  }

  inline_policy {
    name = "S3"
    policy = data.aws_iam_policy_document.lamdba_s3_permission[each.key].json
  }

  inline_policy {
    name = "SQS"
    policy = data.aws_iam_policy_document.lamdba_sqs_permission[each.key].json
  }
}

resource "aws_lambda_function" "this" {
  for_each = local.enabled ? var.stream_filters : {}

  function_name = join(module.this.delimiter, [module.this.id, each.key])
  
  architectures = [
    "x86_64"
  ]

  environment {
    variables = {
      "DAS_FILTER_NAME" = each.key
      "DAS_KMS_REGION_NAME" = var.stream_filters[each.key].kms_region
      "DAS_RDS_RESOURCE_ID" = var.stream_filters[each.key].stream_name
    }
  }

  image_uri    = var.lambda_image_uri
  package_type = "Image"
  role         = aws_iam_role.iam_role_for_lamdba[each.key].arn
  
  memory_size = 200
  timeout     = 900
}

resource "aws_lambda_event_source_mapping" "this" {
  for_each = local.enabled ? var.stream_filters : {}

  event_source_arn = aws_sqs_queue.this[each.key].arn
  function_name = aws_lambda_function.this[each.key].arn
}
