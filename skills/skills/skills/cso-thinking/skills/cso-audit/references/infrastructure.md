# Infrastructure security checklist

> IaC, container, orchestration, CI/CD. Configuration is the audit target. Grounded in CIS Docker / Kubernetes / Cloud benchmarks, NIST SP 800-190 (container security), OWASP IaC Top 10, SLSA.

Read this file when the `infrastructure` profile is active.

## Threat outcomes we defend against

1. **Cluster / cloud account takeover** — over-permissive IAM, privileged containers escaping to host
2. **Lateral movement** — flat networking, no network policy, default service accounts
3. **Image-level RCE** — vulnerable base images, outdated packages, running as root
4. **Secret exposure** — secrets in env vars, in IaC state files, in container images
5. **Supply-chain compromise** — unpinned base images, unsigned images, CI/CD trust abuse

## Checklist (I-1 to I-11)

### I-1: Container images
- **I-1.1** `FROM <image>:<tag>` pinned to a specific version, ideally with `@sha256:` digest. `FROM node:latest` = `high`.
- **I-1.2** Minimal base image — `-alpine`, `-slim`, `distroless`, `scratch`. Full Ubuntu/Debian only if justified.
- **I-1.3** `USER` directive present and not root. Running as root in production = `high`.
- **I-1.4** No secrets in `ENV` or `ARG` (they leak into image layers).
- **I-1.5** `.dockerignore` present; doesn't copy `.git`, `.env`, `node_modules` for builds that re-install.
- **I-1.6** `HEALTHCHECK` directive present.
- **I-1.7** Multi-stage builds for compiled languages (Go, Rust, Java) — no compiler in runtime image.
- **I-1.8** Image scanned for vulnerabilities with `trivy image` — map severities directly.

### I-2: Kubernetes workloads
- **I-2.1** `securityContext.runAsNonRoot: true` and `runAsUser` set.
- **I-2.2** `securityContext.readOnlyRootFilesystem: true` (use `emptyDir` for writable paths).
- **I-2.3** `securityContext.allowPrivilegeEscalation: false`.
- **I-2.4** `securityContext.capabilities.drop: [ALL]`, with `add` only if explicitly justified.
- **I-2.5** `securityContext.privileged: false` (default but always confirm).
- **I-2.6** `seccompProfile: RuntimeDefault` set.
- **I-2.7** Resource limits set (`cpu`, `memory`, optionally `ephemeral-storage`) — prevents noisy neighbor + DoS.
- **I-2.8** No `hostNetwork`, `hostPID`, `hostIPC`, `hostPath` volumes unless explicitly justified.
- **I-2.9** ImagePullPolicy: `IfNotPresent` for tagged images; `Always` for `:latest` (and ideally don't use `:latest`).
- **I-2.10** No mounting of the docker socket (`/var/run/docker.sock`) — escape risk.

### I-3: Kubernetes RBAC & service accounts
- **I-3.1** Workloads use dedicated ServiceAccount (not `default`).
- **I-3.2** `automountServiceAccountToken: false` unless the pod actually needs the API.
- **I-3.3** No `ClusterRole` with `verbs: ["*"]` and `resources: ["*"]` — that's cluster admin.
- **I-3.4** Subject bindings explicit; no `system:authenticated` or `system:unauthenticated` group bound to write roles.
- **I-3.5** Operator / controller permissions least-privileged.

### I-4: Kubernetes network policy
- **I-4.1** NetworkPolicy resources exist; default deny + allowlist preferred.
- **I-4.2** Ingress only from expected namespaces / labels.
- **I-4.3** Egress restricted for sensitive workloads (e.g., db pods can only egress to monitoring + DNS).
- **I-4.4** No `Service.type=NodePort` for app traffic unless intentional.
- **I-4.5** Ingress controllers terminate TLS; backend services bind to ClusterIP only.

### I-5: Kubernetes secrets
- **I-5.1** Secrets stored via `Secret` resources (or external secret operator), not `ConfigMap` and not env-baked.
- **I-5.2** etcd encryption-at-rest enabled (cluster-level).
- **I-5.3** `Secret` mounted as files (not env) when consumer supports it — env vars leak via `ps`, crash dumps, child processes.
- **I-5.4** External Secrets Operator / Sealed Secrets / CSI driver used for production-grade secret sourcing.

### I-6: Terraform / IaC misconfigurations
- **I-6.1** State file remote-backed, encrypted, locked (S3 + DynamoDB, or equivalent). Never committed.
- **I-6.2** No hardcoded credentials in `*.tf` or `*.tfvars` — use variables sourced from env or Vault/SOPS.
- **I-6.3** Run `trivy config`, `checkov`, or `tfsec` — map severities.
- **I-6.4** Resources with sensitive=true outputs flagged in state but not printed.

### I-7: Cloud IAM
- **I-7.1** No IAM policies with `Action: "*"` + `Resource: "*"` outside of break-glass admin roles.
- **I-7.2** Service-to-service auth uses workload identity (IAM Roles for Service Accounts, GCP Workload Identity, Azure Pod Identity), not long-lived keys.
- **I-7.3** No long-lived access keys for human users (use SSO + assumed roles).
- **I-7.4** MFA enforced for console / `assumeRole` for privileged roles.
- **I-7.5** Cross-account trust policies have `ExternalId` condition.
- **I-7.6** Resource-based policies (S3 bucket policy, etc.) don't grant `Principal: "*"` without `Condition` that limits scope.

### I-8: Network exposure
- **I-8.1** No security groups / firewall rules with `0.0.0.0/0` on management ports (22 SSH, 3389 RDP, 5432 Postgres, 3306 MySQL, 6379 Redis, 27017 Mongo). Each = `critical` if hit.
- **I-8.2** Public-by-default services (S3 buckets, GCS buckets, Azure blob) confirmed private unless explicitly content-CDN.
- **I-8.3** VPC flow logs enabled.
- **I-8.4** Database / cache layers in private subnets only; no public RDS / public ElastiCache.

### I-9: CI/CD security
- **I-9.1** Pipeline secrets stored in CI's secret store, not in workflow files.
- **I-9.2** OIDC-based cloud auth for CI → cloud (no long-lived keys in GitHub Actions secrets, etc.).
- **I-9.3** Third-party actions pinned to commit SHA, not `@v1` / `@main`.
- **I-9.4** No `pull_request_target` with code-checkout-of-PR (classic GitHub Actions footgun).
- **I-9.5** Branch protection: required reviews, signed commits, dismiss stale approvals.
- **I-9.6** Build provenance / SLSA attestation generated for release artifacts (cosign, sigstore).
- **I-9.7** `actionlint` passes.

### I-10: Logging & observability
- **I-10.1** Audit logs enabled cluster-wide (Kubernetes audit policy, CloudTrail, etc.).
- **I-10.2** Logs shipped off-host; retention meets compliance requirement.
- **I-10.3** Alerting on suspicious patterns (root login, IAM policy change, security group open-world).
- **I-10.4** No PII in metric labels (high cardinality + leak risk).

### I-11: Backup / disaster recovery
- **I-11.1** Database backups exist, automated, tested (someone restored in last 90 days).
- **I-11.2** Backup destinations have least-privilege write-only role from prod, full read by ops only.
- **I-11.3** Backup encryption at rest enabled.
- **I-11.4** RTO/RPO documented; matches business need.

## Tools mapping

| Item | Tool that catches it |
|------|---------------------|
| I-1.x | trivy image, hadolint, dockerfile-lint |
| I-2.x | trivy config, kube-score, kubescape, polaris |
| I-3.x | rbac-tool, kubescape, manual |
| I-4.x | netassert, manual |
| I-5.x | Manual + secret-scanner |
| I-6.x | trivy config, checkov, tfsec |
| I-7.x | prowler (AWS), scout suite, manual review |
| I-8.x | prowler, scout suite, manual |
| I-9.x | actionlint, manual |
| I-10.x | Manual |
| I-11.x | Manual |

## Severity calibration cheat sheet

- Critical: SSH/RDP/DB port open 0.0.0.0/0, IAM admin granted to broad principal, etcd unencrypted, prod secret in IaC source, public bucket with PII.
- High: container running as root, no NetworkPolicy in multi-tenant cluster, long-lived cloud access key, unpinned `FROM` base image in prod, missing branch protection on main.
- Medium: missing seccompProfile, missing resource limits, third-party action pinned to tag not SHA, missing audit log alerting.
- Low: missing HEALTHCHECK, missing .dockerignore, ephemeral-storage limit not set.
- Info: opportunity for SLSA L3 provenance, opportunity for service mesh mTLS.

## Remediation prompt template

```
Open `<manifest path>` (resource `<kind>/<name>`, line `<line>`). Currently:

    <yaml/hcl snippet>

Risk: `<one-sentence threat>` per `<standard>` (CIS K8s 5.x.x / CIS Docker x.x).

Change to:

    <replacement snippet>

For Kubernetes, this should land in the workload's `securityContext` / `podSecurityContext`. For Terraform, this is the `<resource_type>.<name>` block.

Verify by:
1. `kubectl apply --dry-run=server -f <file>` (or `terraform plan`)
2. Re-run `trivy config <path>` and confirm the finding is gone.
3. `kubectl get pod <name> -o jsonpath='{.spec.securityContext}'` (or equivalent provider check)
```

## References

- CIS Benchmarks — https://www.cisecurity.org/cis-benchmarks
- NIST SP 800-190 (Container Security) — https://csrc.nist.gov/publications/detail/sp/800-190/final
- OWASP IaC Top 10 — https://owasp.org/www-project-infrastructure-as-code-security/
- Kubernetes Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- SLSA — https://slsa.dev/
- CNCF Cloud Native Security Whitepaper — https://github.com/cncf/tag-security
