output "subnets" {
  value = {
    A = aws_subnet.a.cidr_block
    B = aws_subnet.b.cidr_block
    C = aws_subnet.c.cidr_block
  }
}

output "node_ips" {
  value = {
    node_a = {
      private = aws_network_interface.eni_a.private_ip
      public  = aws_eip.node_a.public_ip
    }
    node_b = {
      a = aws_network_interface.eni_b_a.private_ip
      b = aws_network_interface.eni_b_b.private_ip
    }
    node_c = {
      b = aws_network_interface.eni_c_b.private_ip
      c = aws_network_interface.eni_c_c.private_ip
    }
    node_d = {
      c = aws_network_interface.eni_d.private_ip
    }
  }
}
