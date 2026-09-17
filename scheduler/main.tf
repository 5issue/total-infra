# -------------------------------------------------------------
# EventBridge 스케줄러 & 람다 (평일 14:00~18:00 가동, 야간/주말 절전)
# -------------------------------------------------------------

provider "aws" {
  region = "ap-northeast-2"
}

variable "cluster_name" {
  default = "test-eks"
}

variable "node_group_name" {
  default = "worker_node-2026091505052993800000004d" # 사용 중인 노드 그룹
}

# 1. Lambda IAM Role
resource "aws_iam_role" "scheduler_lambda_role" {
  name = "eks-scheduler-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_lambda_policy" {
  role = aws_iam_role.scheduler_lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:UpdateNodegroupConfig",
          "eks:DescribeNodegroup",
          "eks:DescribeCluster"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# 2. Lambda 패키징 및 생성 (다운스케일용 - size 0)
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/handler.py"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "scale_down" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "eks-node-scale-down"
  role             = aws_iam_role.scheduler_lambda_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      CLUSTER_NAME    = var.cluster_name
      NODE_GROUP_NAME = var.node_group_name
      TARGET_SIZE     = "0"
    }
  }
}

resource "aws_lambda_function" "scale_up" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "eks-node-scale-up"
  role             = aws_iam_role.scheduler_lambda_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      CLUSTER_NAME    = var.cluster_name
      NODE_GROUP_NAME = var.node_group_name
      TARGET_SIZE     = "2" # 원래 복구할 노드 갯수 (예: 2개)
    }
  }
}

# 3. EventBridge Scheduler를 위한 IAM Role (Scheduler가 Lambda를 실행할 권한)
resource "aws_iam_role" "eventbridge_scheduler_role" {
  name = "eventbridge-scheduler-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "scheduler.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_scheduler_policy" {
  role = aws_iam_role.eventbridge_scheduler_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "lambda:InvokeFunction"
      Resource = [
        aws_lambda_function.scale_down.arn,
        aws_lambda_function.scale_up.arn
      ]
    }]
  })
}

# 4. EventBridge Scheduler 설정
# 평일 18:00 KST (UTC 09:00) -> 0개로 축소 (월~금)
resource "aws_scheduler_schedule" "scale_down_schedule" {
  name       = "eks-scale-down-schedule"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 9 ? * MON-FRI *)" # KST 기준 오후 6시 (UTC 09:00)
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.scale_down.arn
    role_arn = aws_iam_role.eventbridge_scheduler_role.arn
  }
}

# 평일 14:00 KST (UTC 05:00) -> 2개로 복구 (월~금)
resource "aws_scheduler_schedule" "scale_up_schedule" {
  name       = "eks-scale-up-schedule"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 5 ? * MON-FRI *)" # KST 기준 오후 2시 (UTC 05:00)
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.scale_up.arn
    role_arn = aws_iam_role.eventbridge_scheduler_role.arn
  }
}