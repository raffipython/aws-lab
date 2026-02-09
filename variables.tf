variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  type    = string
  default = "lab"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "ssh_allowed_cidr" {
  type        = string
  description = "CIDR allowed to SSH (e.g. your public IP /32)."
  default     = "0.0.0.0/0"
}

variable "public_key_path" {
  type        = string
  description = "Path to your SSH public key (e.g. ~/.ssh/id_ed25519.pub)."
}

variable "key_name" {
  type    = string
  default = "lab-key"
}
