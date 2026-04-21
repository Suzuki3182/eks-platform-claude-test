# Security Improvements — tfsec Compliance

This document summarizes the security hardening applied to pass tfsec validation (HIGH severity threshold).

---

## Changes Applied

### 1. Security Group Egress Rules Restricted

**Before:** All egress rules used `cidr_blocks = ["0.0.0.0/0"]` allowing unrestricted outbound traffic.

**After:** Egress rules now restricted to specific ports and protocols:

#### EKS Cluster Security Group (`modules/eks/main.tf`)
- **DNS (UDP 53)**: Allow outbound to `0.0.0.0/0` (required for DNS resolution)
- **HTTPS (TCP 443)**: Allow outbound to `0.0.0.0/0` (required for AWS API calls, VPC endpoints)
- **Node Communication (TCP 1025-65535)**: Allow outbound to VPC CIDR only

#### EKS Node Security Group (`modules/eks/main.tf`)
- **DNS (UDP 53)**: Allow outbound to `0.0.0.0/0` (required for DNS)
- **HTTPS (TCP 443)**: Allow outbound to `0.0.0.0/0` (required for AWS APIs, ECR, STS)
- **HTTP (TCP 80)**: Allow outbound to `0.0.0.0/0` (required for package downloads)
- **NTP (UDP 123)**: Allow outbound to `0.0.0.0/0` (required for time synchronization)

#### VPC Endpoints Security Group (`modules/vpc/main.tf`)
- **Ingress**: Restricted to HTTPS (TCP 443) from VPC CIDR only
- **Egress**: Restricted to HTTPS (TCP 443) responses within VPC CIDR only

### 2. IAM Policy Refinement

#### Flow Logs Policy (`modules/vpc/main.tf`)
Separated resource scoping by action sensitivity:

```hcl
# CreateLogGroup and DescribeLogGroups → specific log group ARN
Resource = aws_cloudwatch_log_group.flow_logs.arn

# Stream operations (CreateLogStream, PutLogEvents, DescribeLogStreams) 
Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
```

This pattern follows AWS best practices: coarse actions get specific resources, stream-level operations get the log group pattern.

#### Existing Well-Scoped Policies
The following IAM policies already included proper conditions and resource scoping:
- **Load Balancer Controller**: Uses conditions on `StringEquals` for region and `ec2:CreateAction`
- **Cluster Autoscaler**: Uses condition on `autoscaling:ResourceTag` for SetDesiredCapacity and TerminateInstanceInAutoScalingGroup
- **EBS CSI Driver**: Uses AWS managed policy (no custom wildcards)

### 3. Module Input Variables Added

Added `vpc_cidr` variable to the `eks` module to enable scoped security group rules:
- **File**: `terraform/modules/eks/variables.tf`
- **Purpose**: Allows cluster SG to restrict egress to VPC CIDR instead of `0.0.0.0/0`
- **Propagated to**: All environment configurations (test, staging, prod)

---

## Remaining tfsec Findings — Justified

The following tfsec findings remain and are **acceptable** for the following reasons:

### DNS and HTTPS Egress to 0.0.0.0/0
- **Reason**: EKS nodes must reach AWS APIs (EC2, STS, ECR), public DNS resolvers, and external package repositories
- **Alternative**: VPC endpoints for private AWS service access, but nodes still need: public DNS (port 53), external package repos (port 80/443), public certificate authorities for TLS verification
- **Mitigation**: Implement egress network policies within Kubernetes to restrict pod-level outbound traffic

### IAM Actions on Wildcard Resources with Conditions
Some sensitive actions require wildcard resources because they determine which resources get created:
- `elasticloadbalancing:CreateLoadBalancer` — can be in any subnet
- `ec2:AuthorizeSecurityGroupIngress` — can operate on any SG
- Conditions limit scope (e.g., region, resource tags) even if Resource = "*"

**Mitigation**: These are acceptable under the principle that:
1. IRSA roles are bound to specific service accounts (Kubernetes workload identity)
2. AWS resource-level permissions (`StringEquals`, `Null`, `StringLike` conditions) effectively restrict blast radius
3. Production workloads should implement additional RBAC within Kubernetes

---

## Validation

All three environments pass Terraform validation:

```bash
✓ test environment:    Success! The configuration is valid.
✓ staging environment: Success! The configuration is valid.
✓ prod environment:    Success! The configuration is valid.
```

fmt check passes:
```bash
✓ terraform fmt -check -recursive terraform/
```

---

## Recommendations for Further Hardening

1. **Implement Kubernetes Network Policies**: Restrict pod egress to internal services only where possible
2. **Use AWS Security Groups for ECS/Lambda**: If running workloads outside EKS, apply similar scoping rules
3. **Enable VPC Flow Logs Analysis**: Monitor unexpected outbound connections at the network layer
4. **Rotate IAM Credentials**: Implement automatic credential rotation for IRSA roles
5. **Audit CloudTrail**: Monitor IAM policy actions for misuse or unexpected patterns

---

## References

- [tfsec AWS EC2 Security Group Checks](https://aquasecurity.github.io/tfsec/v1.28.14/checks/aws/ec2/)
- [tfsec IAM Policy Checks](https://aquasecurity.github.io/tfsec/v1.28.14/checks/aws/iam/)
- [AWS IAM Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [Security Groups in Amazon VPC](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_SecurityGroups.html)
