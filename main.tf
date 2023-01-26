#Required for a provider block
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "4.48.0"
    }
  }
}

#setting a provider region, and profile so I can easily signin
provider "aws" {
  region  = "us-east-1"
  profile = "default"
}


#experimenting with a dynamic block to DRY up code
locals {
  ingress_rules = [{
    port        = "80"
    description = "Allow all inbound requests"
    protocol    = "tcp"
    cidr        = ["0.0.0.0/0"]
    },
    {
      port        = "0"
      description = "Allow all outbound requests"
      protocol    = "-1"
      cidr        = ["0.0.0.0/0"]

  }]
}

#Security groups for AWS
resource "aws_security_group" "instance" {

  dynamic "ingress" {
    for_each = local.ingress_rules

    content {
      description = ingress.value.description
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr
    }

  }
}

#auto scaling allowing my instance to change from 1-10
resource "aws_autoscaling_group" "example" {
  launch_configuration = aws_launch_configuration.app.name
  vpc_zone_identifier  = data.aws_subnets.default.ids

  target_group_arns = [aws_lb_target_group.asg.arn]
  health_check_type = "ELB"

  min_size = 2
  max_size = 10

  tag {
    key                 = "Name"
    value               = "terraform-asg-example"
    propagate_at_launch = true
  }

}

#resource which employs create before destroy to allow for terraform to not break dependencies on recycle
resource "aws_launch_configuration" "app" {
  image_id        = "ami-0b5eea76982371e91"
  instance_type   = var.instancetype
  security_groups = [aws_security_group.instance.id]
  user_data       = <<-EOF
                 #!/bin/bashs
                 echo "Hi Michael" > index.html
                 nohup busybox httpd -f -p 8080 &
                 EOF
  lifecycle {
    create_before_destroy = true
  }


}

# Load balancer connected to subnets
resource "aws_lb" "balance" {
  name               = "terraform-future-app"
  load_balancer_type = "application"
  subnets            = data.aws_subnets.default.ids
  security_groups    = [aws_security_group.alb.id]

}

#health checker for individual instances
resource "aws_lb_target_group" "asg" {
  name     = "terraform-asg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.secure.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = "15"
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

}

#Load balancer listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.balance.arn
  port              = 80
  protocol          = "HTTP"
  # By default, return a simple 404 page

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: Page not found"
      status_code  = 404

    }

  }
}

#load balancer rules 
resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }
}

output "alb_dns_name" {
  value = aws_lb.balance.dns_name
}

resource "aws_security_group" "alb" {
  name = "terraform-example-alb"

  #allow inbound HTTP requests
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  #allow all outboundrequests
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


data "aws_vpc" "secure" {
  default = true
}

output "vpc_id" {
  value = data.aws_vpc.secure.id

}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.secure.id]
  }

}

#for encrypted storage of a statefile, State is never to be stored in GIT
resource "aws_s3_bucket" "state_storage" {
  bucket = "terraform-state-bucket"

  #To ensure no accidental deletion of this S3 bucket
  lifecycle {
    prevent_destroy = true
  }

}
# enables version history to be visible for my state file
resource "aws_s3_bucket_versioning" "enabled" {
  bucket = aws_s3_bucket.state_storage.id
  versioning_configuration {
    status = "Enabled"
  }

}

#enable server side encryption to be default
resource "aws_s3_bucket_server_side_encryption_configuration" "default" {
  bucket = aws_s3_bucket.state_storage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }

}

#block out all public access to the S3 bucket
resource "aws_s3_account_public_access_block" "public_access" {

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

}


#Used to connect a table to allow for state locking
resource "aws_dynamodb_table" "terraform_lock" {
  name         = "terraform-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

