variable "namespace" {}
variable "stack" {}
variable "cluster" {}
variable "service" { default = "app" }
variable "aws_region" {}
variable "vpc_conf" { type = "map" }
variable "iam_role_arn" {}
variable "iam_profile" {}
variable "aws_instance_type" {}
variable "aws_key_name" {}
variable "ami" {}
variable "app_conf" { type = "map" }

variable "vpc_id" {}
variable "subnets_public_a" {}
variable "subnets_public_b" {}
variable "subnets_public_c" {}
variable "subnets_private_a" {}
variable "subnets_private_b" {}
variable "subnets_private_c" {}
variable "vpc_security_group" {}

module "cluster-app" {
  source = "../../modules/cluster"
  stack = "${var.stack}"
  cluster = "${var.cluster}"
  vpc_conf = "${var.vpc_conf}"
  desired_capacity = "${var.app_conf["capacity_desired"]}"
  aws_image_id = "${var.ami}"
  aws_instance_type = "${var.aws_instance_type}"
  aws_key_name = "${var.aws_key_name}"
  iam_instance_profile_id = "${var.iam_profile}"
  app_conf = "${var.app_conf}"

  vpc_id = "${var.vpc_id}"
  subnets_a = "${var.subnets_public_a}"
  subnets_b = "${var.subnets_public_b}"
  subnets_c = "${var.subnets_public_c}"
  vpc_security_group = "${var.vpc_security_group}"
}

data "template_file" "task" {
  template = "${file("tasks/${var.service}.json")}"

  vars {
    s3bucket = "${var.namespace}-${var.stack}-${var.cluster}-${var.service}"
    stack = "${var.stack}"
    cluster = "${var.cluster}"
    service = "${var.service}"
    aws_region = "${var.aws_region}"
  }
}

resource "aws_ecs_task_definition" "app" {
  family = "${var.stack}-${var.cluster}"
  container_definitions = "${data.template_file.task.rendered}"

  volume {
    name = "${var.stack}"
    host_path = "/ecs/${var.stack}"
  }
  volume {
    name = "${var.stack}-${var.service}"
    host_path = "/ecs/${var.stack}/${var.service}"
  }
  volume {
    name = "backup"
    host_path = "/ecs/${var.stack}"
  }
}

resource "aws_elb" "service" {
  name  = "${var.stack}-${var.cluster}-${var.service}-elb"
  # subnets = ["${lookup(var.vpc_conf["subnets"], "public")}"]
  subnets = ["${var.subnets_public_a}", "${var.subnets_public_b}", "${var.subnets_public_c}"]

  security_groups = [
    "${aws_security_group.elb-sg.id}",
    "${var.vpc_security_group}"
  ]

  listener {
    lb_port            = 80
    lb_protocol        = "http"
    instance_port      = "${var.app_conf["web_container_expose"]}"
    instance_protocol  = "http"
  }

  listener {
    lb_port            = 443
    lb_protocol        = "https"
    ssl_certificate_id = "${var.app_conf["aws_ssl_arn"]}"
    instance_port      = "${var.app_conf["web_container_expose"]}"
    instance_protocol  = "http"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 10
    timeout             = 30
    target              = "TCP:${var.app_conf["web_container_expose"]}"
    interval            = 60
  }

  connection_draining = false
  cross_zone_load_balancing = true
  internal = "${var.app_conf["internal"]}"

  tags {
    Stack = "${var.stack}"
    Name = "${var.service}-elb"
  }
}

resource "aws_security_group" "elb-sg" {
  name = "${var.stack}-${var.cluster}-${var.service}-elb"
  description = "ELB Incoming traffic"

  vpc_id = "${var.vpc_id}"

  ingress {
    from_port = 80
    to_port   = 80
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "elb-sg"
  }
}

resource "aws_security_group_rule" "service-http-ingress" {
  type = "ingress"
  from_port = "${var.app_conf["web_container_expose"]}"
  to_port = "${var.app_conf["web_container_expose"]}"
  protocol = "tcp"

  security_group_id = "${module.cluster-app.sg_cluster_id}"
  source_security_group_id = "${aws_security_group.elb-sg.id}"
}

resource "aws_ecs_service" "service" {
  name = "${var.stack}-${var.cluster}-${var.service}"
  cluster = "${module.cluster-app.cluster_id}"

  task_definition = "${aws_ecs_task_definition.app.arn}"
  desired_count = "${var.app_conf["capacity_desired"]}"

  iam_role = "${var.iam_role_arn}"

  deployment_maximum_percent = 100
  deployment_minimum_healthy_percent = 50

  load_balancer {
    elb_name = "${aws_elb.service.id}"
    container_name = "${var.app_conf["web_container"]}"
    container_port = "${var.app_conf["web_container_port"]}"
  }
}

resource "aws_appautoscaling_target" "autoscale-service" {
  service_namespace = "ecs"
  resource_id = "service/${var.stack}-${var.cluster}/${var.stack}-${var.cluster}-${var.service}"
  scalable_dimension = "ecs:service:DesiredCount"
  role_arn = "${var.iam_role_arn}"
  min_capacity = "${var.app_conf["capacity_min"]}"
  max_capacity = "${var.app_conf["capacity_max"]}"
}

resource "aws_appautoscaling_policy" "autoscale-policy-service" {
  name = "${var.stack}-${var.cluster}-${var.service}"
  service_namespace = "ecs"
  resource_id = "service/${var.stack}-${var.cluster}/${var.stack}-${var.cluster}-${var.service}"
  scalable_dimension = "ecs:service:DesiredCount"
  adjustment_type = "ChangeInCapacity"
  cooldown = 3600
  metric_aggregation_type = "Maximum"
  step_adjustment {
    metric_interval_lower_bound = 3.0
    scaling_adjustment = 2
  }
  step_adjustment {
    metric_interval_lower_bound = 2.0
    metric_interval_upper_bound = 3.0
    scaling_adjustment = 2
  }
  step_adjustment {
    metric_interval_lower_bound = 1.0
    metric_interval_upper_bound = 2.0
    scaling_adjustment = -1
  }
  depends_on = ["aws_appautoscaling_target.autoscale-service"]
}
