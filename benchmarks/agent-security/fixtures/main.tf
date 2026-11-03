# INSECURE benchmark fixture. It exists only to exercise Trivy configuration scan.
resource "aws_security_group" "benchmark_ssh" {
  name = "benchmark-public-ssh"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
