provider "aws" {
  region = "us-east-2"
}
resource "aws_key_pair" "example" {
  key_name   = "example-key"
  public_key = file("~/.ssh/id_rsa.pub")
}

resource "aws_security_group" "allow_ssh_http" {
  name_prefix = "allow_ssh_http"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_instance" "example" {
  ami           = "ami-00eb69d236edcfaf8"  # AMI
  instance_type = "t2.micro"
  key_name      = aws_key_pair.example.key_name
  security_groups = [aws_security_group.allow_ssh_http.name]

  tags = {
    Name = "Prometheus-Server"
  }
}

output "instance_ip" {
  value = aws_instance.example.public_ip
}
